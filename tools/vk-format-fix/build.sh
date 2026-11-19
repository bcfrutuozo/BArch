#!/usr/bin/env bash
# Builds VK_LAYER_BARCH_format_fix (layer.c) into ~/.local/lib/barch and registers it as an
# implicit Vulkan layer in ~/.local/share/vulkan/implicit_layer.d. The layer only loads when
# BARCH_VK_FORMAT_FIX=1, which the game launchers in games/ export. Run again after editing layer.c.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
lib_dir="$HOME/.local/lib/barch"
manifest_dir="${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/implicit_layer.d"
lib="$lib_dir/libVkLayer_barch_format_fix.so"

mkdir -p "$lib_dir" "$manifest_dir"
gcc -O2 -fPIC -shared -fvisibility=hidden -Wall -Wextra -o "$lib.tmp" "$here/layer.c" -lpthread
mv -f "$lib.tmp" "$lib"

cat > "$manifest_dir/barch_format_fix.json" <<EOF
{
  "file_format_version": "1.2.0",
  "layer": {
    "name": "VK_LAYER_BARCH_format_fix",
    "type": "GLOBAL",
    "library_path": "$lib",
    "api_version": "1.4.0",
    "implementation_version": "1",
    "description": "BArch: hides A2R10G10B10 surface formats (red/blue swapped on NVIDIA under Hyprland)",
    "functions": {
      "vkNegotiateLoaderLayerInterfaceVersion": "fix_NegotiateLoaderLayerInterfaceVersion"
    },
    "enable_environment": { "BARCH_VK_FORMAT_FIX": "1" },
    "disable_environment": { "BARCH_VK_FORMAT_FIX_DISABLE": "1" }
  }
}
EOF
echo "VK_LAYER_BARCH_format_fix -> $lib"
