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

Just **bash**, **dd**, and **tar** — plus **gzip** only if you use `-z`, and
**sha256sum** only if you use `-c` (on either side). It deliberately uses only
widely-portable options of each, so it should run on slim systems (busybox,
macOS/BSD, older GNU userlands).

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
rawdisk.sh send [-z] [-c] [-y] <device> <file>...   Bundle files and write to <device>
rawdisk.sh recv [-c] [-y] <device> [dest-dir]       Read from <device> and extract
rawdisk.sh info <device>                             Show what's stored on <device>
```

Options:
- `-z` — gzip the archive on send. `recv` auto-detects it; needs gzip on both sides.
- `-c` — on **send**, store a sha256 checksum of the payload. Requires
  `sha256sum`; if it's not installed, `-c` errors out rather than silently
  sending unchecked data. Without `-c` nothing about checksums is written or
  printed.
  On **recv**, a checksum present in the blob is *always* verified before
  extraction, refusing to extract on a mismatch. Passing `-c` to `recv` makes a
  checksum **mandatory**: if the blob was sent without one, `recv -c` fails
  instead of extracting unverified data — use it when you want an end-to-end
  guarantee that nothing unchecked slips through.
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
rawdisk.sh recv /dev/sdb ./incoming
```

You never have to track the byte count yourself — that's the point. A small
512-byte header written to the front of the device records the payload size and
whether it was compressed, so `recv` knows exactly what to read.

## How it works

```
offset 0      512-byte header:  "RAWDISK1 <payload_bytes> <none|gzip> [sha256hex]\n"
offset 1 MiB  the tar (or tar.gz) payload
```

The checksum is an optional 4th header field, so blobs written without `-c` are
byte-for-byte what they were before the feature existed. On send with `-c` the
hash is computed by reading the payload back off the device, so it also confirms
the write actually landed where expected.

`send` writes the payload first (capturing the exact byte count from `dd`), then
stamps the header. `recv` reads the header, reads back the payload region, and
pipes it into `tar`, which stops itself at the archive's end-of-archive marker.

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
  hash to catch subtler damage.
- **A regular file works as the "device"** — useful for testing or for making a
  transportable blob without a physical disk.
```
