# system/

Snapshot of system files (`/etc`, `/boot`), kept with their original paths under `files/`.
They are **copied**, never linked: the system owns them.

- Refresh: `./scripts/collect-system.sh` (also run by `./scripts/sync.sh`)
- Restore on a new install: `./scripts/apply-system.sh` (shows a diff and asks for each file)
- `modes.txt` keeps each file's original permissions.
- Inline passwords (e.g. `password=` in cifs mounts) are replaced with `REDACTED`.
- The list of files lives in `scripts/lib.sh` (`SYSTEM_FILES`).
