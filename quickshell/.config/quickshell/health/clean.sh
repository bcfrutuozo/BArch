#!/usr/bin/env bash
# clean.sh — limpeza do sistema, passo a passo (cada passo pergunta antes).
# Roda dentro do terminal aberto pelo HealthWidget; no fim marca a data da limpeza.
bold=$'\e[1m'; blue=$'\e[34m'; green=$'\e[32m'; reset=$'\e[0m'
step() { printf '\n%s%s==> %s%s\n' "$bold" "$blue" "$*" "$reset"; }
ask()  { local a; read -r -p "  $1 [Y/n] " a; [[ -z "$a" || "$a" =~ ^[YySs]$ ]]; }

step "Orphan packages (installed as dependencies, no longer needed)"
orph=$(pacman -Qdtq)
if [[ -n "$orph" ]]; then
  echo "$orph" | sed 's/^/  /'
  ask "Remove them?" && sudo pacman -Rns $orph
else
  echo "  none"
fi

step "Package cache (keeps the last 2 versions of installed packages, none of removed ones)"
du -sh /var/cache/pacman/pkg 2>/dev/null | sed 's/^/  current size: /'
ask "Clean it?" && sudo paccache -rk2 && sudo paccache -ruk0

step "AUR build cache (paru) — keeps linux-cachyos, which kernel-update builds from"
du -sh ~/.cache/paru/clone 2>/dev/null | sed 's/^/  current size: /'
if ask "Remove old AUR build files?"; then
  for d in ~/.cache/paru/clone/*/; do
    n=$(basename "$d")
    if [[ "$n" == linux-cachyos ]]; then
      # só os restos da compilação (o fonte do kernel e os pacotes gerados), não a cópia do git
      git -C "$d" clean -fdxq -e '*.pkg.tar.zst' >/dev/null 2>&1 || true
    else
      rm -rf "$d"
    fi
  done
  echo "  done"
fi

step "System journal (keeps the last 4 weeks)"
journalctl --disk-usage
ask "Vacuum it?" && sudo journalctl --vacuum-time=4weeks

step "Snapshots (snapper keeps them by its own rules; listing only)"
sudo snapper -c root list 2>/dev/null | tail -n 8

state="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/last-cleanup"
mkdir -p "$(dirname "$state")"; date +%s > "$state"
printf '\n%s%sDone.%s\n' "$bold" "$green" "$reset"
read -rsn1 -p "Press any key to close…"
