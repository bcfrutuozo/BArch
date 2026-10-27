#!/usr/bin/env bash
# Fresh install: packages, configs and user services. System files are applied
# separately (./scripts/apply-system.sh) because they deserve a careful look.
set -euo pipefail
source "$(dirname "$0")/scripts/lib.sh"

# Virtual machine (testing the repo): skip hardware-specific packages
VIRT=$(systemd-detect-virt 2>/dev/null || true)
HW_ONLY='^(nvidia|lib32-nvidia|opencl-nvidia|cuda|linux-cachyos|libva-nvidia|egl-gbm|egl-x11|nvtop|gpu-screen-recorder)'
if [[ -n "$VIRT" && "$VIRT" != none ]]; then
  warn "running in a VM ($VIRT): NVIDIA, the CachyOS kernel and the GPU recorder are skipped"
fi
filter_hw() { if [[ -n "$VIRT" && "$VIRT" != none ]]; then grep -vE "$HW_ONLY" || true; else cat; fi; }

step "Repositories"
# multilib: bibliotecas de 32 bits (Steam, Proton, lib32-*); vem desligado numa instalação nova
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  sudo sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
  ok "multilib enabled"
fi
sudo pacman -Sy

step "Base tools"
sudo pacman -S --needed --noconfirm git stow base-devel openssh

step "Official packages"
missing=$(comm -23 <(sort -u "$REPO/packages/pacman.txt") <(pacman -Qq | sort -u) | filter_hw)
if [[ -n "$missing" ]]; then
  # only what still exists in the repositories (renamed/removed packages would abort the whole install)
  available=$(comm -12 <(sort -u <<<"$missing") <(pacman -Slq | sort -u))
  gone=$(comm -23 <(sort -u <<<"$missing") <(sort -u <<<"$available"))
  [[ -n "$gone" ]] && warn "not in the repositories anymore (skipped): $(tr '\n' ' ' <<<"$gone")"
  [[ -n "$available" ]] && sudo pacman -S --needed $available
else
  ok "all installed"
fi

step "AUR helper (paru)"
if ! command -v paru >/dev/null; then
  tmp=$(mktemp -d)
  git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
  (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
  rm -rf "$tmp"
fi
command -v paru >/dev/null && ok "paru" || warn "paru could not be installed"

step "AUR packages"
if command -v paru >/dev/null; then
  # packages built by hand (e.g. the custom kernel) are listed in aur-ignore.txt
  todo=$(grep -vxFf "$REPO/packages/aur-ignore.txt" "$REPO/packages/aur.txt" | filter_hw || true)
  todo=$(comm -23 <(sort -u <<<"$todo") <(pacman -Qq | sort -u))
  if [[ -n "$todo" ]]; then paru -S --needed $todo || warn "some AUR packages failed; rerun this script to retry"
  else ok "all installed"; fi
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

step "Theme links"
# arquivos que o tema gera/troca em uso e por isso ficam fora do git: cria um ponto de partida
themes="$HOME/.config/hypr/themes"
if [[ -d "$themes" && ! -e "$themes/current.lua" ]]; then
  ln -sfn dark.lua "$themes/current.lua" && ok "Hyprland theme: dark (theme-auto switches it later)"
fi
hl="$HOME/.config/hypr/hyprlock-colors.conf"
[[ -e "$hl" ]] || { touch "$hl"; ok "empty hyprlock-colors.conf (the bar fills it on first start)"; }

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
