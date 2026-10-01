#!/usr/bin/env bash
#
# rawdisk — move files between machines via a raw storage device, no filesystem.
#
# Bundles files with tar and writes the archive straight to a block device with
# dd, then reads them back the same way. A tiny header block at the very start
# of the device records the payload size and whether it was gzipped, so the
# receiving side needs no manual byte-counting.
#
# Requirements: bash, dd, tar (plus gzip only if you use -z, and openssl only if
# you use -e).
# Deliberately sticks to widely-portable options of each so it runs on slim
# systems (busybox, macOS/BSD, old GNU, etc.).
#
# Layout on the device:
#   offset 0        : 4 KiB header block "RAWDISK1 <payload_bytes> <none|gzip> [sha256]\n"
#   offset 1 MiB    : the tar (or tar.gz) payload
# The 1 MiB gap keeps the payload aligned to a big block size for fast dd, and
# leaves the header comfortably in its own region.
#
# Encrypted (-e) layout:
#   offset 0        : "RAWDISK2 <payload_bytes> <none|gzip> aes-256-ctr <iter> <hmac>\n"
#   offset 4 KiB    : openssl's 16-byte "Salted__" + salt header, NUL-padded
#   offset 1 MiB    : AES-256-CTR ciphertext of the tar (or tar.gz) payload
# The key comes from the passphrase via PBKDF2-HMAC-SHA256. <hmac> is an
# HMAC-SHA256 over the header fields, the salt header and the ciphertext, and is
# checked before anything is decrypted.

set -u
export LC_ALL=C            # stabilise dd's summary output for parsing

PROG=${0##*/}

MAGIC=RAWDISK1
MAGIC_ENC=RAWDISK2         # encrypted archives; plain ones stay RAWDISK1 so
                           # they're byte-for-byte what they always were
CIPHER=aes-256-ctr         # CTR adds no padding: ciphertext length equals the
                           # tar length, so the payload keeps its BLK alignment
KDF_ITER=600000            # PBKDF2-HMAC-SHA256 rounds for new archives
BLK=4096                   # I/O alignment unit. Raw character devices (macOS
                           # /dev/rdiskN) reject reads and writes that are not a
                           # whole number of device blocks. 4096 is a multiple of
                           # 512, so aligning to it satisfies both 512-byte and
                           # 4Kn media without interrogating the device.
HDR_BS=$BLK                # header block size (bytes)
BS=1048576                 # transfer block size (bytes); also payload offset
PAYLOAD_SEEK=1             # payload starts at PAYLOAD_SEEK * BS
SALT_SEEK=1                # encrypted: salt header lives at SALT_SEEK * HDR_BS
TAR_BLK=$((BLK / 512))     # tar -b factor; keeps the archive a multiple of BLK

COMPRESS=0
CHECKSUM=0
ENCRYPT=0
ASSUME_YES=0
WORKDIR=                   # temp dir for send's write verification

# Secrets pass through the variables below. Unset them first: a same-named
# variable inherited from the caller's environment keeps its export flag, even
# through 'local', and would hand the secret to every child process. For the
# same reason the passphrase leaves the environment before anything is run.
unset PASS again key mac_key ipad opad inner esc h b x
PASS=${RAWDISK_PASSPHRASE-}
unset RAWDISK_PASSPHRASE

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

# Copy stdin to stdout and, once the stream ends, write the sha256 of the bytes
# that passed through to file $1. One pass over the data both feeds the next
# stage and yields its digest. Waits for the hasher, so the file is complete
# when this returns.
tee_sha256() {
    local fifo=$1.fifo hasher rc
    mkfifo "$fifo" || return 1
    sha256_stdin <"$fifo" >"$1" &
    hasher=$!
    tee "$fifo"
    rc=$?
    wait "$hasher" || rc=1
    rm -f "$fifo"
    return $rc
}

is_hex64() {
    [ ${#1} -eq 64 ] || return 1
    case $1 in *[!0-9a-fA-F]*) return 1;; esac
}

# Emit the raw bytes of a hex string. printf is a builtin, so key material
# passed through here never appears in any process's argv.
hex_to_bin() {
    local h=$1 esc= i
    for ((i = 0; i < ${#h}; i += 2)); do esc="$esc\\x${h:i:2}"; done
    # shellcheck disable=SC2059
    printf "$esc"
}

# HMAC-SHA256 of stdin, keyed by a hex key of at most 64 bytes. Hand-built from
# the printf builtin and sha256_stdin because openssl only takes HMAC keys on
# its command line, where other users can read them with ps.
hmac_sha256() {
    local key=$1 ipad= opad= i b x inner
    while [ ${#key} -lt 128 ]; do key=${key}00; done
    for ((i = 0; i < 128; i += 2)); do
        b=$((16#${key:i:2}))
        printf -v x '\\x%02x' $((b ^ 0x36)); ipad=$ipad$x
        printf -v x '\\x%02x' $((b ^ 0x5c)); opad=$opad$x
    done
    # shellcheck disable=SC2059
    inner=$( { printf "$ipad"; cat; } | sha256_stdin ) || return 1
    # shellcheck disable=SC2059
    { printf "$opad"; hex_to_bin "$inner"; } | sha256_stdin
}

# openssl enc with rawdisk's cipher and KDF; extra args pass through. The
# passphrase rides in this one process's environment, never on a command line.
ossl_enc() {
    local iter=$1; shift
    RAWDISK_PASSPHRASE=$PASS "$OPENSSL" enc -$CIPHER -pbkdf2 -iter "$iter" -md sha256 \
        -pass env:RAWDISK_PASSPHRASE "$@"
}

# Die unless openssl can do what -e needs. Old builds (OpenSSL < 1.1.1, LibreSSL
# on older macOS) lack -pbkdf2. The probe passphrase is no secret, so pass: is ok.
require_openssl() {
    printf x | "$OPENSSL" enc -$CIPHER -pbkdf2 -iter 1 -md sha256 -pass pass:probe \
        >/dev/null 2>&1 \
        || die "encryption needs openssl with -pbkdf2 and $CIPHER support (tried: $OPENSSL)"
    have_sha256 || die "encryption needs a sha256 tool (sha256sum, shasum, or openssl)"
}

# Keep the passphrase taken from $RAWDISK_PASSPHRASE at startup, else prompt for
# one on the terminal (twice when $1 is "confirm").
get_passphrase() {
    [ -n "$PASS" ] && return 0
    # read -p turns echo off before showing the prompt; a separate printf would
    # leave a moment where fast typing still echoes.
    local again=
    IFS= read -rs -p 'Passphrase: ' PASS </dev/tty || true
    printf '\n' >&2
    [ -n "$PASS" ] || die "empty passphrase (type one at the prompt or set RAWDISK_PASSPHRASE)"
    if [ "${1:-}" = confirm ]; then
        IFS= read -rs -p 'Passphrase (again): ' again </dev/tty || true
        printf '\n' >&2
        [ "$PASS" = "$again" ] || die "passphrases do not match"
    fi
}

# Resolve a core tool, preferring the base-system copy in /usr/bin or /bin over
# anything that shadows it on PATH. This matters because a Homebrew/GNU/uutils
# coreutils install can put a different 'dd' first on PATH, and some of those
# (e.g. uutils dd) can't seek on macOS device nodes. An explicit RAWDISK_DD /
# RAWDISK_TAR / RAWDISK_OPENSSL override always wins; otherwise fall back to
# PATH if the tool lives somewhere unusual.
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
OPENSSL=$(resolve_tool "${RAWDISK_OPENSSL:-}" openssl)

# Keep archives clean across platforms. macOS bsdtar otherwise embeds Apple
# metadata that litters a Linux extraction with junk '._*' files and xattr
# warnings. COPYFILE_DISABLE stops the '._*' AppleDouble members (portable env
# var, ignored elsewhere); --no-xattrs drops the xattr headers but is only
# understood by bsdtar/GNU tar, so add it only when the tar is bsdtar.
#
# -b sets the archive record size, which is what makes the payload length a
# multiple of BLK -- required for the final write to a raw character device.
# Both bsdtar and GNU tar accept it; an unrecognised tar (busybox) keeps its
# default, which is fine everywhere except a 4Kn raw device.
export COPYFILE_DISABLE=1
TAR_COPTS=
case $("$TAR" --version 2>/dev/null) in
    *bsdtar*|*libarchive*) TAR_COPTS="--no-xattrs -b $TAR_BLK" ;;
    *"GNU tar"*)           TAR_COPTS="-b $TAR_BLK" ;;
esac

usage() {
    cat <<EOF
rawdisk — sneakernet files via a raw device, no filesystem needed.

Usage:
  $PROG send [-z] [-c] [-e] [-y] <device> <file>...   Bundle files and write to <device>
  $PROG recv [-c] [-e] [-y] <device> [dest-dir]       Read from <device> and extract here
  $PROG list <device>                                  List archived files without extracting
  $PROG info <device>                                  Show what's stored on <device>

Options:
  -z   gzip the archive on send (recv auto-detects; needs gzip on both sides)
  -c   on send: store a sha256 checksum (needs sha256sum, shasum, or openssl;
       errors if none) and verify the write by reading it back. -e does the same.
       on recv: require the blob to carry a checksum and verify it, failing if
       it has none. A checksum present in the blob is always verified even
       without -c; -c on recv just makes that verification mandatory.
  -e   on send: encrypt with a passphrase (AES-256-CTR + HMAC-SHA256; needs
       openssl on both sides). recv and list detect encryption, ask for the
       passphrase and verify the MAC before reading anything. On recv, -e
       refuses an archive that isn't encrypted. The MAC also satisfies -c.
  -y   skip the confirmation prompt (for scripts)
  -h   show this help

The passphrase is read from the terminal, or from \$RAWDISK_PASSPHRASE if set.

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

# Read and parse the header block. Sets: magic, psize, comp, sum, cipher, iter,
# mac (via the caller's locals, thanks to bash dynamic scope). A RAWDISK1 header
# may carry sum; a RAWDISK2 one carries cipher, iter and mac. Fields an archive
# doesn't have are left empty.
read_header() {
    local dev=$1 hdr rest
    hdr=$("$DD" if="$dev" bs=$HDR_BS count=1 2>/dev/null | tr -d '\0')
    # Only the first line is our header; anything after the newline is ignored.
    read -r magic psize comp rest <<<"$hdr"
    sum= cipher= iter= mac=
    case $magic in
        "$MAGIC")     sum=$rest;;
        "$MAGIC_ENC") read -r cipher iter mac <<<"$rest";;
    esac
}

# Load the header of $1 into the caller's locals (as read_header, plus zflag for
# tar) and die unless it describes an archive we can read.
require_archive() {
    read_header "$1"
    case $magic in
        "$MAGIC"|"$MAGIC_ENC") ;;
        *) die "no rawdisk archive found on $1 (bad magic)";;
    esac
    case ${psize:-} in
        ''|*[!0-9]*) die "corrupt header (bad size: '${psize:-}')";;
    esac
    if [ "$magic" = "$MAGIC_ENC" ]; then
        [ "$cipher" = "$CIPHER" ] || die "unsupported cipher on $1: '${cipher:-}'"
        case ${iter:-} in
            ''|*[!0-9]*) die "corrupt header (bad iteration count: '${iter:-}')";;
        esac
        is_hex64 "$mac" || die "corrupt header (bad MAC: '${mac:-}')"
    fi
    zflag=
    if [ "$comp" = gzip ]; then zflag=z; fi
}

# Emit the stored payload of device $1: whole BS blocks, trimmed to exactly $2
# bytes. The tail of the last block is padding; tar stops at its own end marker
# either way, but gzip sees the padding and warns about "trailing garbage".
payload_stream() {
    local blocks=$(( ($2 + BS - 1) / BS ))
    "$DD" if="$1" bs=$BS skip=$PAYLOAD_SEEK count="$blocks" 2>/dev/null | head -c "$2"
}

# Emit the 16-byte "Salted__" + salt header of an encrypted archive on $1.
salt_stream() {
    "$DD" if="$1" bs=$HDR_BS skip=$SALT_SEEK count=1 2>/dev/null | head -c 16
}

# Emit the archive as tar should read it -- decrypted if the header says it's
# encrypted. Uses the caller's dev, psize, cipher and iter.
archive_stream() {
    if [ -n "$cipher" ]; then
        { salt_stream "$dev"; payload_stream "$dev" "$psize"; } | ossl_enc "$iter" -d
    else
        payload_stream "$dev" "$psize"
    fi
}

# Write stdin (at most HDR_BS bytes) to device $1 as block $2, NUL-padded to a
# full HDR_BS. A raw character device only accepts writes that are a whole
# number of device blocks, so it must go out as one full block rather than a
# short printf (which fails with EINVAL). Build the padded block in a temp file
# -- conv=sync NUL-pads the tail -- then write that block in one go. notrunc is
# essential: without it dd would truncate a regular-file target.
write_block() {
    local tmp rc
    tmp=$(mktemp) || return 1
    "$DD" of="$tmp" bs=$HDR_BS count=1 conv=sync 2>/dev/null \
        && "$DD" if="$tmp" of="$1" bs=$HDR_BS seek="$2" count=1 conv=notrunc 2>/dev/null
    rc=$?
    rm -f "$tmp"
    return $rc
}

# Write stdin to the payload area of device $1, encrypting first with -e. If $2
# is given, the sha256 of exactly the bytes sent to the device (with -e: salt
# header + ciphertext) is written to that file. dd's summary goes to stderr so
# the caller can read the byte count from it. conv=notrunc protects existing
# data when <device> is a regular file.
write_payload() {
    local dev=$1 digest=${2:-}
    if [ "$ENCRYPT" = 1 ]; then
        # openssl leads with its 16-byte "Salted__" + salt header. Peel that off
        # into its own block so the ciphertext keeps tar's BLK alignment.
        ossl_enc "$KDF_ITER" | tee_sha256 "$digest" \
            | { "$DD" bs=16 count=1 2>/dev/null | write_block "$dev" $SALT_SEEK \
                && "$DD" of="$dev" bs=$BS seek=$PAYLOAD_SEEK conv=notrunc; }
    elif [ -n "$digest" ]; then
        tee_sha256 "$digest" | "$DD" of="$dev" bs=$BS seek=$PAYLOAD_SEEK conv=notrunc
    else
        "$DD" of="$dev" bs=$BS seek=$PAYLOAD_SEEK conv=notrunc
    fi
}

# Print the HMAC-SHA256 authenticating an encrypted archive on $1 with payload
# size $2, compression $3 and KDF iterations $4. It covers the header fields, so
# none can be altered, plus the salt header and the ciphertext. The MAC key is
# derived from the same PBKDF2 key openssl encrypts with, which openssl -P
# prints on stdout. If $5 is given, the sha256 of the salt header + ciphertext
# as read is written to that file, so send can verify its write in the same pass.
mac_of() {
    local dev=$1 size=$2 comp=$3 iter=$4 digest=${5:-} key mac_key
    key=$(salt_stream "$dev" | ossl_enc "$iter" -d -P 2>/dev/null \
            | awk -F= '$1 == "key" { print $2; exit }')
    is_hex64 "$key" || return 1
    mac_key=$(printf 'rawdisk-mac-v1' | hmac_sha256 "$key")
    is_hex64 "$mac_key" || return 1
    { printf '%s %s %s %s %s\n' "$MAGIC_ENC" "$size" "$comp" "$CIPHER" "$iter"
      if [ -n "$digest" ]; then
          { salt_stream "$dev"; payload_stream "$dev" "$size"; } | tee_sha256 "$digest"
      else
          salt_stream "$dev"
          payload_stream "$dev" "$size"
      fi
    } | hmac_sha256 "$mac_key"
}

# Get the passphrase and check an encrypted archive's MAC before any decrypted
# byte reaches tar. Uses the caller's dev, psize, comp, iter and mac.
authenticate() {
    local actual
    require_openssl
    get_passphrase
    actual=$(mac_of "$dev" "$psize" "$comp" "$iter")
    [ "$actual" = "$mac" ] \
        || die "authentication FAILED on $dev — wrong passphrase, or the data was modified"
    printf '%s: authentication OK (HMAC-SHA256)\n' "$PROG" >&2
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

    # Fail fast before touching the device if -e can't work, or if -c was asked
    # for but no sha256 tool (sha256sum / shasum / openssl) is available. With -e
    # the MAC takes the place of the checksum, so -c adds nothing.
    if [ "$ENCRYPT" = 1 ]; then
        require_openssl
    elif [ "$CHECKSUM" = 1 ] && ! have_sha256; then
        die "no sha256 tool found (need sha256sum, shasum, or openssl); -c requires one (omit -c to send without a checksum)"
    fi
    # Write verification streams through tee into a fifo. Without tee, the
    # hasher would wait on the fifo forever instead of failing.
    if { [ "$ENCRYPT" = 1 ] || [ "$CHECKSUM" = 1 ]; } && ! { have tee && have mkfifo; }; then
        die "-c and -e verify the write, which needs tee and mkfifo"
    fi

    if [ "$ENCRYPT" = 0 ] && [ -n "$PASS" ]; then
        printf '%s: warning: RAWDISK_PASSPHRASE is set but -e was not given; sending UNENCRYPTED\n' "$PROG" >&2
    fi

    printf 'Target : %s\n' "$dev" >&2
    ls -ld "$dev" >&2 2>/dev/null || true
    confirm "This will OVERWRITE the start of $dev."
    if [ "$ENCRYPT" = 1 ]; then get_passphrase confirm; fi

    # With -c or -e, hash the bytes on their way to the device, so the read-back
    # below can prove the device stored them intact.
    local digest=
    if [ "$CHECKSUM" = 1 ] || [ "$ENCRYPT" = 1 ]; then
        WORKDIR=$(mktemp -d) || die "failed to create temp directory"
        trap 'rm -rf "$WORKDIR"' EXIT
        digest=$WORKDIR/written
    fi

    # Blank the old header first, so a write that fails part-way can't leave a
    # stale header describing a half-overwritten payload.
    printf '\n' | write_block "$dev" 0 || die "failed to clear old header"

    # Write the payload (offset 1 MiB) and capture how many bytes dd wrote.
    local summary bytes
    set -o pipefail
    summary=$( { "$TAR" $TAR_COPTS -c ${zflag:+-z} -f - "$@" | write_payload "$dev" "$digest"; } 2>&1 ) \
        || die "write failed:
$summary"
    set +o pipefail

    # dd's summary is the last line mentioning bytes.
    bytes=$(printf '%s\n' "$summary" | awk '/bytes/ { n = $1 } END { print n }')
    case ${bytes:-} in
        ''|*[!0-9]*) die "could not determine archive size (dd said: $summary)";;
    esac

    # Read the payload back off the device, computing the checksum or MAC in
    # the same pass, and check it matches what was sent. Faulty or fake-capacity
    # media that mangled the write fails here, before a header is stamped,
    # rather than having the damage checksummed or signed.
    local sum= mac= readback=
    if [ "$ENCRYPT" = 1 ]; then
        [ "$(salt_stream "$dev" | head -c 8)" = Salted__ ] \
            || die "write verification FAILED — salt header missing on $dev after write"
        mac=$(mac_of "$dev" "$bytes" "$comp" "$KDF_ITER" "$WORKDIR/readback")
        is_hex64 "$mac" || die "failed to compute MAC"
        readback=$(cat "$WORKDIR/readback")
    elif [ "$CHECKSUM" = 1 ]; then
        sum=$(payload_stream "$dev" "$bytes" | sha256_stdin)
        readback=$sum
    fi
    if [ -n "$digest" ]; then
        is_hex64 "$readback" || die "failed to hash the data read back from $dev"
        [ "$readback" = "$(cat "$digest")" ] \
            || die "write verification FAILED — $dev did not store what was written (faulty or fake-capacity media?); no header written"
    fi

    # Now stamp the header at offset 0. The checksum is an optional 4th field,
    # so plain archives stay unchanged.
    local hdr_line="$MAGIC $bytes $comp"
    if [ -n "$mac" ]; then
        hdr_line="$MAGIC_ENC $bytes $comp $CIPHER $KDF_ITER $mac"
    elif [ -n "$sum" ]; then
        hdr_line="$MAGIC $bytes $comp $sum"
    fi
    printf '%s\n' "$hdr_line" | write_block "$dev" 0 || die "failed to write header"
    if [ -n "$digest" ]; then
        [ "$("$DD" if="$dev" bs=$HDR_BS count=1 2>/dev/null | tr -d '\0')" = "$hdr_line" ] \
            || die "write verification FAILED — header on $dev did not read back correctly"
    fi

    # Flush OS buffers so the data is really on the medium before the stick is
    # pulled (matters especially on Linux, where block writes are cached).
    sync 2>/dev/null || true

    printf '%s: wrote %s bytes (%s) to %s\n' "$PROG" "$bytes" "$comp" "$dev" >&2
    [ -n "$digest" ] && printf '%s: write verified (read-back matches)\n' "$PROG" >&2
    [ -n "$sum" ] && printf '%s: checksum sha256:%s\n' "$PROG" "$sum" >&2
    [ -n "$mac" ] && printf '%s: encrypted (%s, HMAC-SHA256)\n' "$PROG" "$CIPHER" >&2
    :
}

cmd_recv() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local dev=$1; shift
    local dest=${1:-.}
    [ -e "$dev" ] || die "device not found: $dev"
    [ -d "$dest" ] || die "destination is not a directory: $dest"

    local magic psize comp sum cipher iter mac zflag
    require_archive "$dev"

    # With -e the caller demands an encrypted (hence authenticated) archive, so
    # a plaintext one swapped onto the device can't slip through.
    if [ "$ENCRYPT" = 1 ] && [ -z "$cipher" ]; then
        die "-e given but $dev is not encrypted; refusing to extract"
    fi

    # With -c the caller demands integrity: refuse if the blob has no checksum.
    # An encrypted archive's MAC counts.
    if [ "$CHECKSUM" = 1 ] && [ -z "${sum:-}" ] && [ -z "$cipher" ]; then
        die "-c given but $dev has no stored checksum (it was sent without -c); refusing to extract"
    fi

    # Check the MAC or stored checksum before extracting anything.
    if [ -n "$cipher" ]; then
        authenticate
    elif [ -n "${sum:-}" ]; then
        if have_sha256; then
            local actual
            actual=$(payload_stream "$dev" "$psize" | sha256_stdin)
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

    printf '%s: extracting %s bytes (%s%s) from %s into %s\n' \
        "$PROG" "$psize" "${comp:-none}" "${cipher:+, $cipher}" "$dev" "$dest" >&2
    confirm "This will extract files into $dest (existing files may be overwritten)."

    archive_stream | ( cd "$dest" && "$TAR" x${zflag}f - )
    # The reader may exit 141 (SIGPIPE) when tar finishes early — that's
    # expected. Only tar's status tells us whether extraction actually succeeded.
    local tar_status=${PIPESTATUS[1]}
    [ "$tar_status" = 0 ] || die "extraction failed (tar exit $tar_status)"

    printf '%s: done.\n' "$PROG" >&2
}

cmd_info() {
    [ $# -ge 1 ] || { usage; exit 1; }
    local dev=$1
    [ -e "$dev" ] || die "device not found: $dev"

    local magic psize comp sum cipher iter mac
    read_header "$dev"
    case $magic in
        "$MAGIC"|"$MAGIC_ENC") ;;
        *) printf 'No rawdisk archive found on %s.\n' "$dev"; return 1;;
    esac
    printf 'Device      : %s\n' "$dev"
    printf 'Payload     : %s bytes\n' "$psize"
    printf 'Compression : %s\n' "${comp:-none}"
    if [ -n "${cipher:-}" ]; then
        printf 'Encryption  : %s + HMAC-SHA256, PBKDF2-SHA256 (%s iterations)\n' "$cipher" "$iter"
        printf 'Checksum    : hmac-sha256:%s\n' "$mac"
        return 0
    fi
    printf 'Encryption  : none\n'
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

    local magic psize comp sum cipher iter mac zflag
    require_archive "$dev"

    # File names are secret too, so an encrypted archive needs the passphrase.
    if [ -n "$cipher" ]; then authenticate; fi

    # List the archive contents without extracting.
    archive_stream | "$TAR" t${zflag}f -
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
    while getopts ':zceyh' opt; do
        case $opt in
            z) COMPRESS=1;;
            c) CHECKSUM=1;;
            e) ENCRYPT=1;;
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
