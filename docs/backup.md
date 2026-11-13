# Backup

restic to the NAS for what the repo cannot hold, and the app to browse it.

The repo holds the configuration; `barch backup` holds the rest: secrets, per-app state and
personal files, encrypted with [restic](https://restic.net) on the NAS
(`/mnt/nasfrutuozo/organization/desktops/bcfrutuozo/restic`; another path or a restic URL goes in
`~/.config/barch/backup.conf` as `BACKUP_REPO=`). What goes in is `backup/include.txt` (SSH and
GPG keys, PIA, the vdirsyncer password, the keyring, Firefly data and the finance ledger, browser
profiles, Parsec, Steam user data, Claude's project memory, the VM definitions dumped by
`virsh`, Documents, Pictures, Videos); `exclude.txt` drops caches and sockets. The restic
password lives in `~/.config/barch/backup/password` and nowhere in the repo: `barch backup init`
generates it, prints it once, and it belongs in Bitwarden too, because a reinstalled machine
needs it before anything can be restored.

`barch-backup.timer` runs it daily at 13:00 (`Persistent`, so a machine that was off catches
up), keeping 14 daily, 8 weekly and 12 monthly snapshots (pruned on Sundays). The Sunday run then
verifies the repository (`restic check`): its structure, and a tenth of the data read back and
hashed, a different tenth each week (ISO week mod 10), so every pack is verified within ten weeks
without reading the whole repository over the share every time; `barch backup check [--full]`
does it now. The health widget turns yellow when the last run failed or is more than two days
old and red when the check found something wrong (the card says when it was last verified), and
a failed run or check also goes through `barch failure` like any other service. `barch backup restore latest ~/.ssh` puts the
files under `~/Restore/<snapshot>/` with their full paths, never in place.

What only root can read goes in through `barch-backup-root.timer` (system unit, daily at 12:30,
script `/usr/local/bin/barch-backup-root`, both in `system/`): the NetworkManager profiles (Wi-Fi
passwords), the SMB credentials, the Secure Boot keys (`/var/lib/sbctl`), the SSH host keys,
root's own keys and a `cryptsetup luksHeaderBackup` of the root disk, written as `system.tar`
and `luks-header-<device>.img` into `~/.local/state/barch/backup/root/` (owned by you, mode
600), which the 13:00 run then encrypts with the rest. Restore them with
`barch backup restore latest .local/state/barch/backup/root` and untar as root.

Not covered: the VM disk images.

## Backup Browser

**Backup Browser** (`quickshell/backup/`, "Backup Browser" in the launcher, `barch backup browse`):
the restic repository on the NAS. Status of the last run (files, data added, snapshot, next
timer), every snapshot with its summary (size on demand), and **Browse & restore**: the files
of a snapshot as a tree listed on demand (`restic ls` per folder), a search (`restic find`),
tick files or folders and Restore puts them under `~/Restore/<snapshot>-<time>/` with their full
paths, never in place; Run backup now, check and unlock open a terminal. Same repository,
password file and cache as `barch backup`; it never deletes anything.
