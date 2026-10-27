#!/usr/bin/env bash
# Saves the lists of explicitly installed packages.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

step "Updating package lists"
pacman -Qqen > "$REPO/packages/pacman.txt"
pacman -Qqem > "$REPO/packages/aur.txt"
ok "pacman.txt: $(wc -l < "$REPO/packages/pacman.txt") packages"
ok "aur.txt:    $(wc -l < "$REPO/packages/aur.txt") packages"

# serviços do usuário ligados nesta máquina (hyprpaper, hypridle, cliphist…): o install.sh liga os mesmos
systemctl --user list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' \
  | grep -vE '^(xdg-user-dirs|pipewire|wireplumber|p11-kit|gnome-keyring)' | sort > "$REPO/packages/user-services.txt"
ok "user-services.txt: $(wc -l < "$REPO/packages/user-services.txt") services"
