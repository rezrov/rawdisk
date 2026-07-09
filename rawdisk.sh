#!/usr/bin/env bash
#
# rawdisk — move files between machines via a raw storage device, no filesystem.
#
# Bundles files with tar and writes the archive straight to a block device with
# dd, then reads them back the same way. A tiny 512-byte header at the very
# start of the device records the payload size and whether it was gzipped, so
# the receiving side needs no manual byte-counting.
#
# Requirements: bash, dd, tar (plus gzip only if you use -z).
# Deliberately sticks to widely-portable options of each so it runs on slim
# systems (busybox, macOS/BSD, old GNU, etc.).
#
# Layout on the device:
#   offset 0        : 512-byte header  "RAWDISK1 <payload_bytes> <none|gzip>\n"
#   offset 1 MiB    : the tar (or tar.gz) payload
# The 1 MiB gap keeps the payload aligned to a big block size for fast dd, and
# leaves the header comfortably in its own region.

set -u
export LC_ALL=C            # stabilise dd's summary output for parsing

PROG=${0##*/}

MAGIC=RAWDISK1
HDR_BS=512                 # header block size (bytes)
BS=1048576                 # transfer block size (bytes); also payload offset
PAYLOAD_SEEK=1             # payload starts at PAYLOAD_SEEK * BS

COMPRESS=0
CHECKSUM=0
ASSUME_YES=0

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Is any sha256 tool available? Stock macOS has no sha256sum (only shasum /
# openssl), while Linux has sha256sum — all produce the same digest.
have_sha256() { have sha256sum || have shasum || have openssl; }

# Read stdin, print just the 64-hex-char sha256 digest, using whatever tool is
# present. sha256sum, 'shasum -a 256' and 'openssl dgst -sha256' all agree, so a
# blob hashed on one platform verifies on the other.
sha256_stdin() {
    if   have sha256sum; then sha256sum       | awk '{ print $1;  exit }'
    elif have shasum;    then shasum -a 256   | awk '{ print $1;  exit }'
    elif have openssl;   then openssl dgst -sha256 | awk '{ print $NF; exit }'
    else return 1
    fi
}

# Resolve a core tool, preferring the base-system copy in /usr/bin or /bin over
# anything that shadows it on PATH. This matters because a Homebrew/GNU/uutils
# coreutils install can put a different 'dd' first on PATH, and some of those
# (e.g. uutils dd) can't seek on macOS device nodes. An explicit RAWDISK_DD /
# RAWDISK_TAR override always wins; otherwise fall back to PATH if the tool
# lives somewhere unusual.
resolve_tool() {
    local override=$1 name=$2 p
    if [ -n "$override" ]; then printf '%s\n' "$override"; return 0; fi
    for p in "/usr/bin/$name" "/bin/$name"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    command -v "$name" 2>/dev/null || printf '%s\n' "$name"
}

DD=$(resolve_tool "${RAWDISK_DD:-}" dd)
TAR=$(resolve_tool "${RAWDISK_TAR:-}" tar)

# Keep archives clean across platforms. macOS bsdtar otherwise embeds Apple
# metadata that litters a Linux extraction with junk '._*' files and xattr
# warnings. COPYFILE_DISABLE stops the '._*' AppleDouble members (portable env
# var, ignored elsewhere); --no-xattrs drops the xattr headers but is only
# understood by bsdtar/GNU tar, so add it only when the tar is bsdtar.
export COPYFILE_DISABLE=1
TAR_COPTS=
case $("$TAR" --version 2>/dev/null) in
    *bsdtar*|*libarchive*) TAR_COPTS='--no-xattrs' ;;
esac

usage() {
    cat <<EOF
rawdisk — sneakernet files via a raw device, no filesystem needed.

Usage:
  $PROG send [-z] [-c] [-y] <device> <file>...   Bundle files and write to <device>
  $PROG recv [-c] [-y] <device> [dest-dir]       Read from <device> and extract here
  $PROG list <device>                             List archived files without extracting
  $PROG info <device>                             Show what's stored on <device>

Options:
  -z   gzip the archive on send (recv auto-detects; needs gzip on both sides)
  -c   on send: store a sha256 checksum (needs sha256sum; errors if absent).
       on recv: require the blob to carry a checksum and verify it, failing if
       it has none. A checksum present in the blob is always verified even
       without -c; -c on recv just makes that verification mandatory.
  -y   skip the confirmation prompt (for scripts)
  -h   show this help

<device> is a raw block/char device such as /dev/sdb or /dev/rdisk3, or a plain
file (handy for testing).

WARNING: 'send' overwrites the start of <device>. Writing to the wrong device
destroys whatever is on it. Double-check the path.
EOF
}

# Ask for confirmation on stdin unless -y was given.
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    printf '%s\n' "$1" >&2
    printf 'Type "yes" to continue: ' >&2
    local reply=
    read -r reply </dev/tty || true
    [ "$reply" = yes ] || die "aborted"
}

# Read and parse the 512-byte header. Sets: magic, psize, comp, sum (via the
# caller's locals, thanks to bash dynamic scope). sum is empty if none stored.
read_header() {
    local dev=$1 hdr
    hdr=$("$DD" if="$dev" bs=$HDR_BS count=1 2>/dev/null | tr -d '\0')
    # Only the first line is our header; anything after the newline is ignored.
    read -r magic psize comp sum <<<"$hdr"
}

cmd_send() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local dev=$1; shift
    [ $# -ge 1 ] || die "no files to send"
    [ -e "$dev" ] || die "device not found: $dev"
    if ! { [ -b "$dev" ] || [ -c "$dev" ] || [ -f "$dev" ]; }; then
        die "not a device or regular file: $dev"
    fi

    local comp=none zflag=
    if [ "$COMPRESS" = 1 ]; then comp=gzip; zflag=z; fi

    # Fail fast before touching the device if -c was asked for but no sha256 tool
    # (sha256sum / shasum / openssl) is available.
    if [ "$CHECKSUM" = 1 ] && ! have_sha256; then
        die "no sha256 tool found (need sha256sum, shasum, or openssl); -c requires one (omit -c to send without a checksum)"
    fi

    printf 'Target : %s\n' "$dev" >&2
    ls -ld "$dev" >&2 2>/dev/null || true
    confirm "This will OVERWRITE the start of $dev."

    # Write the payload first (offset 1 MiB) and capture how many bytes dd wrote.
    # conv=notrunc protects existing data when <device> is a regular file.
    local summary bytes
    set -o pipefail
    summary=$( { "$TAR" $TAR_COPTS -c ${zflag:+-z} -f - "$@" | "$DD" of="$dev" bs=$BS seek=$PAYLOAD_SEEK conv=notrunc; } 2>&1 ) \
        || die "write failed:
$summary"
    set +o pipefail

    bytes=$(printf '%s\n' "$summary" | awk '/bytes/ { print $1; exit }')
    case ${bytes:-} in
        ''|*[!0-9]*) die "could not determine archive size (dd said: $summary)";;
    esac

    # Optionally checksum by reading the payload back off the device. This
    # doubles as a write check: a short or misplaced write shows up as a bad hash.
    local sum=
    if [ "$CHECKSUM" = 1 ]; then
        local blocks=$(( (bytes + BS - 1) / BS ))
        sum=$("$DD" if="$dev" bs=$BS skip=$PAYLOAD_SEEK count="$blocks" 2>/dev/null \
                | head -c "$bytes" | sha256_stdin)
        case ${sum:-} in
            ''|*[!0-9a-f]*) die "failed to compute checksum";;
        esac
    fi

    # Now stamp the header at offset 0. notrunc is essential here: without it dd
    # would truncate a regular-file target down to the header and lose the payload.
    # The checksum is an optional 4th field, so plain archives stay unchanged.
    local hdr_line
    if [ -n "$sum" ]; then
        hdr_line="$MAGIC $bytes $comp $sum"
    else
        hdr_line="$MAGIC $bytes $comp"
    fi
    printf '%s\n' "$hdr_line" \
        | "$DD" of="$dev" bs=$HDR_BS count=1 conv=notrunc 2>/dev/null \
        || die "failed to write header"

    # Flush OS buffers so the data is really on the medium before the stick is
    # pulled (matters especially on Linux, where block writes are cached).
    sync 2>/dev/null || true

    printf '%s: wrote %s bytes (%s) to %s\n' "$PROG" "$bytes" "$comp" "$dev" >&2
    [ -n "$sum" ] && printf '%s: checksum sha256:%s\n' "$PROG" "$sum" >&2
    :
}

cmd_recv() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local dev=$1; shift
    local dest=${1:-.}
    [ -e "$dev" ] || die "device not found: $dev"
    [ -d "$dest" ] || die "destination is not a directory: $dest"

    local magic psize comp sum
    read_header "$dev"
    [ "$magic" = "$MAGIC" ] || die "no rawdisk archive found on $dev (bad magic)"
    case ${psize:-} in
        ''|*[!0-9]*) die "corrupt header (bad size: '${psize:-}')";;
    esac

    local zflag=
    [ "$comp" = gzip ] && zflag=z

    # Read ceil(psize / BS) blocks; tar stops itself at the archive's end marker,
    # so any trailing bytes in the final block are harmlessly ignored.
    local blocks=$(( (psize + BS - 1) / BS ))

    # With -c the caller demands integrity: refuse if the blob has no checksum.
    if [ "$CHECKSUM" = 1 ] && [ -z "${sum:-}" ]; then
        die "-c given but $dev has no stored checksum (it was sent without -c); refusing to extract"
    fi

    # If a checksum was stored, verify the payload before extracting anything.
    if [ -n "${sum:-}" ]; then
        if have_sha256; then
            local actual
            actual=$("$DD" if="$dev" bs=$BS skip=$PAYLOAD_SEEK count="$blocks" 2>/dev/null \
                        | head -c "$psize" | sha256_stdin)
            if [ "$actual" != "$sum" ]; then
                die "checksum MISMATCH — device data is corrupt, not extracting
  expected sha256:$sum
  actual   sha256:$actual"
            fi
            printf '%s: checksum OK (sha256)\n' "$PROG" >&2
        else
            printf '%s: warning: archive has a checksum but no sha256 tool (sha256sum/shasum/openssl) is installed; skipping verification\n' "$PROG" >&2
        fi
    fi

    printf '%s: extracting %s bytes (%s) from %s into %s\n' \
        "$PROG" "$psize" "${comp:-none}" "$dev" "$dest" >&2
    confirm "This will extract files into $dest (existing files may be overwritten)."

    "$DD" if="$dev" bs=$BS skip=$PAYLOAD_SEEK count="$blocks" 2>/dev/null \
        | ( cd "$dest" && "$TAR" x${zflag}f - )
    # dd may exit 141 (SIGPIPE) when tar finishes early — that's expected. Only
    # tar's status tells us whether extraction actually succeeded.
    local tar_status=${PIPESTATUS[1]}
    [ "$tar_status" = 0 ] || die "extraction failed (tar exit $tar_status)"

    printf '%s: done.\n' "$PROG" >&2
}

cmd_info() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local dev=$1
    [ -e "$dev" ] || die "device not found: $dev"

    local magic psize comp sum
    read_header "$dev"
    if [ "$magic" != "$MAGIC" ]; then
        printf 'No rawdisk archive found on %s.\n' "$dev"
        return 1
    fi
    printf 'Device      : %s\n' "$dev"
    printf 'Payload     : %s bytes\n' "$psize"
    printf 'Compression : %s\n' "${comp:-none}"
    if [ -n "${sum:-}" ]; then
        printf 'Checksum    : sha256:%s\n' "$sum"
    else
        printf 'Checksum    : none\n'
    fi
}

cmd_list() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local dev=$1
    [ -e "$dev" ] || die "device not found: $dev"

    local magic psize comp sum
    read_header "$dev"
    [ "$magic" = "$MAGIC" ] || die "no rawdisk archive found on $dev (bad magic)"
    case ${psize:-} in
        ''|*[!0-9]*) die "corrupt header (bad size: '${psize:-}')";;
    esac

    local zflag=
    [ "$comp" = gzip ] && zflag=z
    local blocks=$(( (psize + BS - 1) / BS ))

    # List the archive contents without extracting. tar stops at its own end
    # marker, so trailing bytes in the final block are ignored.
    "$DD" if="$dev" bs=$BS skip=$PAYLOAD_SEEK count="$blocks" 2>/dev/null \
        | "$TAR" t${zflag}f -
    local tar_status=${PIPESTATUS[1]}
    [ "$tar_status" = 0 ] || die "listing failed (tar exit $tar_status)"
}

main() {
    local sub=${1:-}
    case $sub in
        -h|--help|help|'') usage; exit 0;;
    esac
    shift

    # Parse options that appear after the subcommand.
    local opt OPTIND=1
    while getopts ':zcyh' opt; do
        case $opt in
            z) COMPRESS=1;;
            c) CHECKSUM=1;;
            y) ASSUME_YES=1;;
            h) usage; exit 0;;
            \?) die "unknown option: -$OPTARG (see '$PROG -h')";;
        esac
    done
    shift $((OPTIND - 1))

    case $sub in
        send) cmd_send "$@";;
        recv) cmd_recv "$@";;
        list) cmd_list "$@";;
        info) cmd_info "$@";;
        *) die "unknown command: $sub (see '$PROG -h')";;
    esac
}

main "$@"
