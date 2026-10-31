#!/usr/bin/env bash
# Takes a snapshot of the system files listed in lib.sh (SYSTEM_FILES) into
# system/files/, keeping their paths. Passwords are redacted and secret-looking
# files are skipped. Needs sudo, because some files (e.g. under /boot) are root-only.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

dest="$REPO/system/files"
modes="$REPO/system/modes.txt"

step "Collecting system files (sudo is needed to read /boot and some of /etc)"
sudo -v

# expand the globs as root, so root-only folders are visible too
mapfile -t files < <(sudo bash -c '
  shopt -s nullglob globstar
  for p in "$@"; do for f in $p; do [[ -f "$f" && ! -L "$f" ]] && echo "$f"; done; done
' _ "${SYSTEM_FILES[@]}" | sort -u)

rm -rf "$dest"
mkdir -p "$dest"
: > "$modes"

for f in "${files[@]}"; do
  if [[ "$f" =~ $SYSTEM_EXCLUDE_RE ]]; then warn "skipped (looks secret): $f"; continue; fi
  mkdir -p "$dest$(dirname "$f")"
  if sudo grep -Iq . "$f"; then
    # text: copy as the current user, redacting inline passwords (e.g. cifs mounts in fstab)
    sudo cat "$f" | sed -E 's/((password|pass|passwd)=)[^,[:space:]]+/\1REDACTED/Ig' > "$dest$f"
  else
    # shellcheck disable=SC2024  # the copy lands in the repo, owned by the user: no sudo on the redirect
    sudo cat "$f" > "$dest$f"     # binary (images of the boot theme): copied as is
  fi
  echo "$(sudo stat -c '%a' "$f") $f" >> "$modes"
  ok "$f"
done

# last line of defense: flag anything that still looks sensitive
step "Checking for secrets"
if grep -rIinE 'BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key|secret=|token=' "$dest" ; then
  warn "Review the lines above before committing."
else
  ok "Nothing suspicious found."
fi
