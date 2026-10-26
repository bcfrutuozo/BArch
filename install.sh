#!/usr/bin/env bash
# Fresh install: packages, configs and user services. System files are applied
# separately (./scripts/apply-system.sh) because they deserve a careful look.
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"

step "Base tools"
sudo pacman -S --needed --noconfirm git stow

step "Official packages"
missing=$(comm -23 <(sort -u "$REPO/packages/pacman.txt") <(pacman -Qq | sort -u))
if [[ -n "$missing" ]]; then
  sudo pacman -S --needed $missing
else
  ok "all installed"
fi

step "AUR packages"
if command -v paru >/dev/null; then
  # packages built by hand (e.g. the custom kernel) are listed in aur-ignore.txt
  todo=$(grep -vxFf "$REPO/packages/aur-ignore.txt" "$REPO/packages/aur.txt" || true)
  todo=$(comm -23 <(sort -u <<<"$todo") <(pacman -Qq | sort -u))
  if [[ -n "$todo" ]]; then paru -S --needed $todo; else ok "all installed"; fi
else
  warn "paru not found: install it, then rerun this script for the AUR packages"
fi

step "Linking configs"
mapfile -t pkgs < <(printf '%s\n' "${!PACKAGES[@]}" | sort)
for pkg in "${pkgs[@]}"; do
  [[ -d "$REPO/$pkg" ]] || continue
  for rel in ${PACKAGES[$pkg]}; do
    [[ -e "$REPO/$pkg/$rel" ]] || continue
    if [[ -e "$HOME/$rel" && ! -L "$HOME/$rel" ]]; then
      mv "$HOME/$rel" "$HOME/$rel.pre-barch"
      warn "existing ~/$rel moved to ~/$rel.pre-barch"
    fi
    mkdir -p "$(dirname "$HOME/$rel")"
  done
  stow -d "$REPO" -t "$HOME" "$pkg"
  ok "$pkg"
done

step "Wallpapers"
if compgen -G "$HOME/Pictures/Wallpapers/primary-dark.png" >/dev/null; then
  ok "already there"
else
  mkdir -p "$HOME/Pictures/Wallpapers"
  python3 "$REPO/tools/make_wallpapers.py" "$HOME/Pictures/Wallpapers" && ok "generated in ~/Pictures/Wallpapers"
fi

step "User services"
systemctl --user daemon-reload || true
for s in "${USER_SERVICES[@]}"; do
  systemctl --user enable "$s" && ok "$s" || warn "could not enable $s"
done

step "Done"
echo "  Next: ./scripts/apply-system.sh   (kernel cmdline, mkinitcpio, limine, fstab…)"
