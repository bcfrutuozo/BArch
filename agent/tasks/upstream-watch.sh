#!/usr/bin/env bash
# upstream-watch: installed versions and the last seen ones → $2/context.md
# Usage: upstream-watch.sh prepare <rundir> | finish <rundir>
seen=$BARCH_STATE/versions.json
pkgs=(hyprland quickshell gamescope nvidia-open-dkms nvidia-utils)
now=$(pacman -Q "${pkgs[@]}" 2>/dev/null | jq -Rn '[inputs | split(" ") | {(.[0]): .[1]}] | add // {}')

case $1 in
  prepare) ;;
  finish) jq --arg t "$(date -Is)" '{checked: $t, versions: .}' <<<"$now" >"$seen"; exit 0 ;;
  *) exit 0 ;;
esac

{
  echo "# Upstream facts — $(date '+%Y-%m-%d')"
  echo
  echo "## Installed versions"
  echo
  pacman -Q "${pkgs[@]}" 2>&1 | sed 's/^/- /'
  echo
  echo "## Last run"
  echo
  if [[ -r $seen ]]; then jq -r '"Checked \(.checked). Versions then: " + (.versions | to_entries | map("\(.key) \(.value)") | join(", "))' "$seen"
  else echo "First run: look at the last two releases of each project."; fi
  cat <<'PAGES'

## Where to look

- Hyprland: https://github.com/hyprwm/Hyprland/releases (and https://wiki.hypr.land)
- Quickshell: https://git.outfoxxed.me/quickshell/quickshell (changelog) and https://quickshell.org
- gamescope: https://github.com/ValveSoftware/gamescope/releases
- NVIDIA open driver: https://github.com/NVIDIA/open-gpu-kernel-modules/releases and the
  Linux driver release notes on nvidia.com
- Arch packaging changes: https://gitlab.archlinux.org/archlinux/packaging/packages/<name>
PAGES
  echo
  echo "## Watch list (agent/watchlist.md)"
  echo
  cat "$BARCH_REPO/agent/watchlist.md"
} >"$2/context.md"
