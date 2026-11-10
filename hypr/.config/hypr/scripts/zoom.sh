#!/usr/bin/env bash
# Screen zoom around the cursor (cursor:zoom_factor), live: Super+Ctrl+scroll in binds.lua.
#   zoom.sh in|out|reset
# The Lua config has no `hyprctl keyword`, so the value goes in through `hyprctl eval` + hl.config;
# a reload of Hyprland brings it back to 1.
set -euo pipefail

cur=$(hyprctl getoption cursor:zoom_factor -j | jq -r '.float // 1')
case ${1:-} in
  in)    new=$(awk -v z="$cur" 'BEGIN { z *= 1.25; if (z > 8) z = 8; printf "%.3f", z }') ;;
  out)   new=$(awk -v z="$cur" 'BEGIN { z /= 1.25; if (z < 1.05) z = 1; printf "%.3f", z }') ;;
  reset) new=1 ;;
  *)     echo "usage: zoom.sh in|out|reset" >&2; exit 2 ;;
esac
hyprctl eval "hl.config({ cursor = { zoom_factor = $new } })" >/dev/null
