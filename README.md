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
/mnt/sda1/obackupper_backups/OpenWrt/OpenWrt_25.12.3_r12345_2026-07-09_18-10-00
```

Default retention is `20` backups per hostname.

## How backup works

1. Read `/overlay/upper`
2. Create `overlay-upper.tar.gz`
3. Write package list and metadata
4. Verify archive and checksums
5. Save backup into the hostname folder

## How restore works

1. Verify `sha256sums.txt`
2. Show source router info
3. Clear the target directory
4. Extract the saved overlay
5. Request reboot if target is `/overlay/upper`

## Requirements

- Root access
- OpenWrt with `opkg` or `apk`
- `tar`, `sha256sum`, `mount`, `awk`, `sed`, `grep`, `sort`
- `pigz` recommended
- One downloader: `wget`, `uclient-fetch`, or `curl`
- `stty` recommended for arrow-key menus

## Recommended packages

### `opkg`

```sh
opkg update
opkg install pigz wget-ssl coreutils-stty
```

### `apk`

```sh
apk update
apk add pigz wget coreutils-stty
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
obackupper place
obackupper -remove
```

## Notes

- `list` first shows hostname groups, with the current router hostname pinned to the top.
- Backups on the same device still protect against bad changes, but not storage failure.
- Restore is destructive and requires explicit confirmation.
- Installed copies check GitHub for updates on start by default.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
