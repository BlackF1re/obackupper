# obackupper

OpenWRT backup tool.

`obackupper` backs up and restores the writable OpenWrt overlay layer: `/overlay/upper`.

## What it stores

- Full archive of `/overlay/upper`
- Installed package list
- Router and OpenWrt metadata
- SHA-256 checksums for strict verification

## Backup layout

Backups are stored as:

```text
BACKUP_ROOT/hostname/OpenWrt_version_timestamp
```

Example:

```text
/mnt/sda1/obackupper_backups/hEx/OpenWrt_24.10.5_r29087-d9c5716d1d_2026-07-10_15-47-39
```

Default retention is `20` backups per hostname.

## How backup works

1. Read `/overlay/upper`
2. Create `overlay-upper.tar.gz`
3. Write package list and metadata
4. Verify archive and checksums
5. Save backup into the hostname folder

## How restore works

`obackupper restore` without arguments is safe: it opens the same selector as `obackupper list` and does **not** immediately restore the latest backup.

1. Select a hostname folder
2. Select a concrete backup folder
3. Choose restore, delete, or cancel
4. For restore, verify `sha256sums.txt`
5. Show source router info and destructive restore warning
6. Require explicit confirmation
7. Clear the target directory
8. Extract the saved overlay
9. Request reboot if target is `/overlay/upper`

Direct restore is still available:

```sh
obackupper restore /mnt/sda1/obackupper_backups/hEx/OpenWrt_24.10.5_r29087-d9c5716d1d_2026-07-10_15-47-39
```

## Requirements

- Root access
- OpenWrt with `opkg` or `apk`
- `tar`, `sha256sum`, `mount`, `awk`, `sed`, `grep`, `sort`
- `pigz` recommended
- One downloader: `wget`, `uclient-fetch`, or `curl`

## Recommended packages

### `opkg`

```sh
opkg update
opkg install pigz wget-ssl
```

### `apk`

```sh
apk update
apk add pigz wget
```

Use `--gzip` if `pigz` is not available.

## Install

Download the script anywhere, make it executable, and run it.

On first run it:

- checks GitHub for updates
- checks required prerequisites
- installs itself to `/usr/bin/obackupper.sh`
- creates `/usr/bin/obackupper`
- picks the best detected backup storage
- removes the downloaded source copy

### `wget`

```sh
cd /root
wget -O obackupper.sh https://raw.githubusercontent.com/BlackF1re/obackupper/main/obackupper.sh
chmod +x obackupper.sh
./obackupper.sh
```

### `uclient-fetch`

```sh
cd /root
uclient-fetch -O obackupper.sh https://raw.githubusercontent.com/BlackF1re/obackupper/main/obackupper.sh
chmod +x obackupper.sh
./obackupper.sh
```

### `curl`

```sh
cd /root
curl -L -o obackupper.sh https://raw.githubusercontent.com/BlackF1re/obackupper/main/obackupper.sh
chmod +x obackupper.sh
./obackupper.sh
```

## Commands

```sh
obackupper backup
obackupper list
obackupper restore
obackupper restore BACKUP_DIR [TARGET]
obackupper place
obackupper -remove
```

## Notes

- `list` first shows hostname groups from `BACKUP_ROOT/<hostname>`, with the current router hostname pinned to the top and shown in green.
- After selecting a hostname, `list` shows the concrete backup folders stored under that hostname.
- `restore` without arguments opens the selector and never auto-restores the latest backup.
- Restore is destructive and requires explicit confirmation.
- Backups on the same device still protect against bad changes, but not storage failure.
- Installed copies check GitHub for updates on start by default.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
