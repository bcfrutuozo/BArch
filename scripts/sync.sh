#!/usr/bin/env bash
# Everyday command: refresh package lists and system files, then commit and push.
#   ./scripts/sync.sh "message"
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[[ $EUID -eq 0 ]] && die "Run without sudo: the script asks for it only where needed."

"$REPO/scripts/update-packages.sh"
"$REPO/scripts/collect-system.sh"

step "Git"
cd "$REPO"
git add -A
if git diff --cached --quiet; then
  ok "No changes."
  exit 0
fi
git status --short
git commit -m "${1:-sync: $(date '+%Y-%m-%d %H:%M')}"
if git remote get-url origin >/dev/null 2>&1; then
  git push
  ok "Pushed."
fi
