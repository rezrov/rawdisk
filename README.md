# rawdisk

Move files between two machines using a raw storage device (e.g. a USB stick)
**without a filesystem** — no formatting, no mounting. It bundles your files
with `tar` and writes the archive straight to the block device with `dd`, then
reads them back the same way.

Handy when you need to shuttle files between devices where mounting a proper
removable filesystem is awkward or impossible.

> ## ⚠️ Warning: this destroys data on the target device
>
> `rawdisk.sh send` writes **raw bytes directly to the device**, overwriting
> whatever is there — including the **partition table and any filesystem**. The
> device will no longer be readable as a normal disk until you repartition and
> reformat it. **Any existing files on it will be lost.**
>
> There is no undo. Double-check the device path (`/dev/sdb`, `/dev/rdisk3`,
> …) before every `send` — writing to the wrong device can wipe the wrong disk.

## Requirements

Just **bash**, **dd**, and **tar** — plus **gzip** only if you use `-z`, a
sha256 tool only if you use `-c` (**`sha256sum`**, **`shasum`**, or
**`openssl`** — whichever is present; stock macOS has `shasum`/`openssl`, Linux
has `sha256sum`), and **`openssl`** only if you use `-e` (stock on macOS and on
most Linux distributions; typically absent on busybox-only systems). It
deliberately uses only widely-portable options of each, so it should run on slim
systems (busybox, macOS/BSD, older GNU userlands).

### Cross-platform (macOS ↔ Linux)

The on-device format is just bytes — a header and a tar payload — so a stick
written on one OS reads on the other. The script smooths over the tool
differences for you:

- **macOS metadata is stripped on write** so a Mac-created archive doesn't
  litter a Linux extraction with `._*` files or extended-attribute warnings
  (`COPYFILE_DISABLE=1`, plus `--no-xattrs` when the tar is bsdtar).
- **Checksums are tool-agnostic.** `-c` uses `sha256sum`, `shasum -a 256`, or
  `openssl` — all produce the same digest, so a blob hashed on Linux verifies on
  macOS and vice-versa.
- **Encryption interoperates.** `-e` uses only `openssl enc` options that
  macOS's LibreSSL and Linux's OpenSSL 3 handle identically, so a stick
  encrypted on one decrypts on the other.
- **Buffers are flushed** with `sync` after a write, so the data is really on the
  medium before you pull the stick (particularly relevant on Linux).

For a mixed transfer, still `send` on one machine and `recv` on the other as
normal — no flags needed for the cross-platform handling; it's automatic.

### Which `dd`/`tar` it uses

The script pins `dd` and `tar` to the base-system copies in `/usr/bin` or
`/bin`, rather than whatever is first on `PATH`. This avoids a real gotcha on
macOS: a Homebrew GNU/uutils `coreutils` install puts its own `dd` ahead of the
system one, and some of those can't seek on macOS device nodes (you'll see
`dd: cannot seek: Invalid argument` and the transfer aborts). Pinning to the
system tools sidesteps that on any machine.

`openssl` (used by `-e`) is resolved the same way.

To force a specific binary, set `RAWDISK_DD`, `RAWDISK_TAR`, and/or
`RAWDISK_OPENSSL`:

```sh
RAWDISK_DD=/opt/homebrew/bin/gdd rawdisk.sh send /dev/sdb file
```

## Permissions

Reading and writing a real block device is privileged, so **you'll usually need
`sudo` on both ends** (`send` and `recv`):

- **Linux:** nodes like `/dev/sdb` are typically owned `root:disk` (mode `660`),
  so a normal user can't `dd` to/from them without `sudo`.
- **macOS:** `/dev/diskN` / `/dev/rdiskN` are root-owned too. If the stick
  previously held a filesystem, macOS auto-mounts it — run
  `diskutil unmountDisk /dev/diskN` first, then write to the raw node
  `/dev/rdiskN` (faster). You do **not** need to erase or format it.

No root is needed when the "device" is a **plain file you own** (handy for
testing or building a transportable blob), or if your account has been granted
access to the device node (e.g. added to the `disk`/`operator` group).

## Usage

```
rawdisk.sh send [-z] [-c] [-e] [-y] <device> <file>...   Bundle files and write to <device>
rawdisk.sh recv [-c] [-e] [-y] <device> [dest-dir]       Read from <device> and extract
rawdisk.sh list <device>                                  List archived files without extracting
rawdisk.sh info <device>                                  Show what's stored on <device>
```

Options:
- `-z` — gzip the archive on send. `recv` auto-detects it; needs gzip on both sides.
- `-c` — on **send**, store a sha256 checksum of the payload. Requires
  `sha256sum`; if it's not installed, `-c` errors out rather than silently
  sending unchecked data. The write is also verified by reading it back (see
  [Write verification](#how-it-works)). Without `-c` nothing about checksums is
  written or printed.
  On **recv**, a checksum present in the blob is *always* verified before
  extraction, refusing to extract on a mismatch. Passing `-c` to `recv` makes a
  checksum **mandatory**: if the blob was sent without one, `recv -c` fails
  instead of extracting unverified data — use it when you want an end-to-end
  guarantee that nothing unchecked slips through.
- `-e` — on **send**, encrypt the archive with a passphrase (see
  [Encryption](#encryption)). `recv` and `list` detect an encrypted archive
  automatically, ask for the passphrase, and verify it before reading anything.
  Passing `-e` to `recv` makes encryption **mandatory**: a plaintext archive is
  refused, so an unencrypted stick swapped in by someone else can't be extracted
  by mistake. An encrypted archive always carries a MAC, which also satisfies
  `-c`.
- `-y` — skip the confirmation prompt (for scripts).
- `-h` — help.

### Example

On the sending machine:

```sh
rawdisk.sh send /dev/sdb notes.txt photos/
```

On the receiving machine:

```sh
rawdisk.sh info /dev/sdb          # optional: see size, compression, checksum
rawdisk.sh list /dev/sdb          # optional: peek at the file names
rawdisk.sh recv /dev/sdb ./incoming
```

You never have to track the byte count yourself — that's the point. A small
header block written to the front of the device records the payload size and
whether it was compressed, so `recv` knows exactly what to read.

## Encryption

`send -e` encrypts the archive with a passphrase, so the device is unreadable to
anyone who doesn't have it:

```sh
rawdisk.sh send -e -z /dev/sdb notes.txt photos/   # prompts for the passphrase twice
rawdisk.sh recv -e /dev/sdb ./incoming             # prompts once; -e = require encryption
```

The scheme is built entirely from `openssl enc` and the sha256 tool, so no extra
software is needed on macOS or on typical Linux systems:

- The key is derived from the passphrase with **PBKDF2-HMAC-SHA256**
  (600,000 iterations, random salt).
- The archive (after gzip, if `-z`) is encrypted with **AES-256-CTR**.
- An **HMAC-SHA256** over the header fields, the salt and the ciphertext is
  stored in the header. `recv` and `list` check it **before decrypting
  anything**, so a wrong passphrase or any modification to the device — even a
  single flipped bit — is reported as an authentication failure and nothing is
  extracted.
- Before signing, `send` checks that the device stored the ciphertext intact
  (see [Write verification](#how-it-works)), so damage from faulty media is
  caught at send time rather than signed as if it were genuine.

**Supplying the passphrase.** By default it is read from the terminal with echo
off. For scripts, set `RAWDISK_PASSPHRASE` instead; the script removes it from
its environment at startup, before running anything, so only the `openssl`
processes that need it ever see it. The passphrase and derived keys are never
put on a command line where `ps` could show them. If `RAWDISK_PASSPHRASE` is set
but `send` is run without `-e`, a warning says the transfer is unencrypted. `sudo` drops environment
variables by default, so preserve it explicitly:

```sh
sudo --preserve-env=RAWDISK_PASSPHRASE rawdisk.sh send -e -y /dev/sdb notes.txt
```

Avoid `sudo RAWDISK_PASSPHRASE=… rawdisk.sh …`, which puts the passphrase on
`sudo`'s command line.

**What is and isn't protected.** File names, file contents and the archive
structure are encrypted. The payload size, whether it was gzipped, and the
iteration count are stored in the clear (but are covered by the MAC, so they
can't be altered undetected).

**Limitations.**
- Security rests on the passphrase. PBKDF2 slows guessing but isn't
  memory-hard, so use a long, unique passphrase — several random words, not a
  short password.
- `openssl enc` uses an 8-byte salt; that's fixed by the tool.
- `send` only overwrites the start of the device. If the stick previously held
  a **larger unencrypted** transfer, the tail of that old data is still there in
  the clear. Wipe the device first (e.g. `dd if=/dev/zero of=/dev/sdX bs=1048576`) if
  that matters.
- Encrypted archives use a new header (`RAWDISK2`). Older copies of
  `rawdisk.sh` report "bad magic" for them, so update the script on both
  machines.

## How it works

```
offset 0      4 KiB header block:  "RAWDISK1 <payload_bytes> <none|gzip> [sha256hex]\n"
offset 1 MiB  the tar (or tar.gz) payload
```

With `-e` the layout becomes:

```
offset 0      4 KiB header block:  "RAWDISK2 <payload_bytes> <none|gzip> aes-256-ctr <iterations> <hmac-sha256hex>\n"
offset 4 KiB  4 KiB block holding openssl's 16-byte "Salted__" + salt header
offset 1 MiB  the AES-256-CTR ciphertext of the tar (or tar.gz) payload
```

CTR mode adds no padding, so the ciphertext is exactly as long as the tar
stream and keeps its 4 KiB alignment; openssl's salt header is split off into
its own block for the same reason. Blobs written without `-e` still use
`RAWDISK1` and are unchanged.

The checksum is an optional 4th header field, so blobs written without `-c` are
byte-for-byte what they were before the feature existed.

`send` first blanks the old header, then writes the payload (capturing the exact
byte count from `dd`), then stamps the new header. `recv` reads the header, reads
back the payload region, and pipes it into `tar`, which stops itself at the
archive's end-of-archive marker.

**Write verification (`-c` or `-e`).** While writing, `send` hashes the exact
bytes going to the device. It then reads the payload back — computing the
checksum or MAC in that same pass — and compares. If faulty or fake-capacity
media didn't store the data intact, `send` fails with `write verification
FAILED` and writes no header, so the stick can't later be mistaken for a good
archive (the old header was already blanked). Without this, the damaged bytes
would simply have been checksummed or signed, and `recv` would report them as
fine. The header is read back and checked too. One limit: buffered block
devices (Linux `/dev/sdX`, macOS `/dev/diskN`) are cached, so the OS may answer
the read-back from memory rather than from the stick, and media that silently
drops writes can go unnoticed there. The check is strongest on uncached raw
devices such as macOS `/dev/rdiskN`.

All device I/O is aligned to 4 KiB, and the header is written as one full padded
block. Raw character devices — macOS `/dev/rdiskN` — reject reads and writes that
aren't a whole number of device blocks, so unaligned access fails outright with
`Invalid argument` rather than degrading. 4 KiB is a multiple of 512, so the same
alignment works on both 512-byte and 4Kn media. Linux block devices (`/dev/sdX`)
are buffered and don't care either way.

## Notes & gotchas

- **File names follow tar's rules.** If you pass absolute paths
  (`rawdisk.sh send /dev/sdb /home/me/notes.txt`), tar stores the full path and
  extraction recreates that tree. To get clean names, `cd` to the parent and
  pass relative paths:
  ```sh
  cd ~ && rawdisk.sh send /dev/sdb notes.txt photos/
  ```
- **`send` overwrites the start of the device.** It requires the target to
  already exist (a real block device always does) and asks for a typed `yes`
  first — use `-y` to skip. Writing to the wrong `/dev/...` destroys its
  contents, so double-check the path.
- **The device must be at least ~1 MiB + your archive size.** The 1 MiB gap
  keeps the payload aligned for fast `dd`.
- **Integrity checking is opt-in** via `-c` (see above). Without it, `tar` and
  `gzip` still detect gross corruption on extraction, but there's no separate
  hash to catch subtler damage. A `-c` checksum catches accidental damage after the send only —
  anyone who can modify the device can also rewrite the checksum. For protection
  against deliberate tampering, use `-e`, whose MAC can't be forged without the
  passphrase.
- **Encryption is opt-in** via `-e` (see [Encryption](#encryption)). Without it,
  anyone holding the device can read everything on it.
- **A regular file works as the "device"** — useful for testing or for making a
  transportable blob without a physical disk.
```
