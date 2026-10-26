#!/usr/bin/env bash
# One-time setup on the machine that already has the configs.
# Moves each config into the repo and links it back with GNU Stow, so the
# files keep working from the same paths while living in the repository.
#
#   ./scripts/bootstrap.sh --dry-run   shows what would happen
#   ./scripts/bootstrap.sh             does it (makes a backup first)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
run() { if ((DRY)); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi }

command -v stow >/dev/null || die "GNU Stow is not installed: sudo pacman -S stow"

mapfile -t pkgs < <(printf '%s\n' "${!PACKAGES[@]}" | sort)

# ---- what will be adopted ----
todo=()          # "pkg path" pairs
for pkg in "${pkgs[@]}"; do
  for rel in ${PACKAGES[$pkg]}; do
    if [[ -L "$HOME/$rel" ]]; then ok "$pkg: ~/$rel already linked"; continue; fi
    if [[ ! -e "$HOME/$rel" ]]; then warn "$pkg: ~/$rel not found, skipping"; continue; fi
    if [[ -e "$REPO/$pkg/$rel" ]]; then warn "$pkg: ~/$rel already in the repo, skipping"; continue; fi
    todo+=("$pkg $rel")
  done
done
((${#todo[@]})) || { ok "Nothing to adopt."; exit 0; }

# ---- backup ----
step "Backup"
backup="$HOME/barch-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
paths=()
for t in "${todo[@]}"; do paths+=("${t#* }"); done
run tar -C "$HOME" -czf "$backup" "${paths[@]}"
ok "$backup"

# ---- move into the repo ----
step "Moving configs into $REPO"
for t in "${todo[@]}"; do
  pkg="${t%% *}"; rel="${t#* }"
  run mkdir -p "$(dirname "$REPO/$pkg/$rel")"
  run mv "$HOME/$rel" "$REPO/$pkg/$rel"
  ok "$pkg  ←  ~/$rel"
done

# ---- link back ----
step "Linking back with stow"
for pkg in $(printf '%s\n' "${todo[@]}" | cut -d' ' -f1 | sort -u); do
  run stow -d "$REPO" -t "$HOME" "$pkg"
  ok "$pkg"
done

if ((DRY)); then
  echo; warn "Dry run: nothing was changed."
else
  echo
  ok "Done. Restart the bar so it picks up the linked folder: qs kill; qs -d"
  ok "If anything looks wrong, restore with: tar -C ~ -xzf $backup"
fi
