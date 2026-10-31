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

step "PATH"
# os scripts do BArch ficam em ~/.local/bin: no terminal (bash) e na sessão (uwsm → Hyprland, barra)
line='export PATH="$HOME/.local/bin:$PATH"'
for f in "$HOME/.bashrc" "$HOME/.config/uwsm/env"; do
  mkdir -p "$(dirname "$f")"; touch "$f"
  # shellcheck disable=SC2088  # the message shows ~ on purpose
  grep -qF '.local/bin' "$f" || { echo "$line" >> "$f"; ok "~/.local/bin added to PATH in ${f/#$HOME/\~}"; }
done

step "Theme links"
# arquivos que o tema gera/troca em uso e por isso ficam fora do git: cria um ponto de partida
themes="$HOME/.config/hypr/themes"
if [[ -d "$themes" && ! -e "$themes/current.lua" ]]; then
  ln -sfn dark.lua "$themes/current.lua" && ok "Hyprland theme: dark (theme-auto switches it later)"
fi
step "Wallpapers"
if compgen -G "$HOME/Pictures/Wallpapers/dracula/mountains/primary.png" >/dev/null; then
  ok "already there"
else
  mkdir -p "$HOME/Pictures/Wallpapers"
  sudo pacman -S --needed --noconfirm python-numpy python-pillow >/dev/null   # o gerador precisa
  if python3 "$REPO/tools/make_wallpapers.py" "$HOME/Pictures/Wallpapers"; then     # dracula + latte; the bar renders the others when pinned
    ok "generated in ~/Pictures/Wallpapers (Dracula and Latte; other palettes render when pinned)"
  else
    warn "couldn't generate the wallpapers (run tools/make_wallpapers.py by hand to see why)"
  fi
fi
# versões pequenas já desfocadas para a tela de bloqueio e miniaturas (instalações antigas não as têm)
if ! compgen -G "$HOME/Pictures/Wallpapers/dracula/mountains/thumb.png" >/dev/null && [[ -f "$HOME/Pictures/Wallpapers/dracula/mountains/primary.png" ]]; then
  python3 "$REPO/tools/make_wallpapers.py" "$HOME/Pictures/Wallpapers" lock || warn "couldn't generate the lock screen wallpapers"
fi

step "User services"
systemctl --user daemon-reload || true
# os listados em lib.sh + os que estavam ligados na máquina original (packages/user-services.txt)
services=("${USER_SERVICES[@]}")
[[ -f "$REPO/packages/user-services.txt" ]] && mapfile -t -O "${#services[@]}" services < "$REPO/packages/user-services.txt"
for s in $(printf '%s\n' "${services[@]}" | sort -u); do
  [[ -z "$s" ]] && continue
  if [[ -n "$VIRT" && "$VIRT" != none ]] && grep -qE "$HW_ONLY|gsr-" <<<"$s"; then continue; fi
  systemctl --user enable "$s" >/dev/null 2>&1 && ok "$s" || warn "could not enable $s"
done

step "Done"
echo "  Next: ./scripts/apply-system.sh   (kernel cmdline, mkinitcpio, limine, fstab…)"
