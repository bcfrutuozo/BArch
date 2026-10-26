#!/usr/bin/env bash
# Saves the lists of explicitly installed packages.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

step "Updating package lists"
pacman -Qqen > "$REPO/packages/pacman.txt"
pacman -Qqem > "$REPO/packages/aur.txt"
ok "pacman.txt: $(wc -l < "$REPO/packages/pacman.txt") packages"
ok "aur.txt:    $(wc -l < "$REPO/packages/aur.txt") packages"
