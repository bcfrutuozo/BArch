#!/usr/bin/env bash
# Compiles the visualizer's fragment shader for Qt's RHI (OpenGL, Vulkan; qsb from qt6-shadertools).
# The .qsb is kept in the repo so the player needs no shader tools at run time; rerun after editing viz.frag.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
qsb=$(command -v qsb || echo /usr/lib/qt6/bin/qsb)
"$qsb" --glsl "100 es,120,150" --hlsl 50 --msl 12 -o viz.frag.qsb viz.frag
echo "viz.frag.qsb: $(stat -c %s viz.frag.qsb) bytes"
