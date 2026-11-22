#!/bin/sh
# 3DMark, standalone UL build (not the Steam app: its licence is a UL key, which the
# Steam version ignores and stays "Demo"), on Proton-GE via umu-launcher, own prefix
# in ~/Games/3dmark. Same Proton as Battle.net (~/Games/battle.net/proton/current).
#   run.sh            opens 3DMark
#   run.sh setup      runs the installer from ~/Games/3dmark/setup (the unzipped download)
#   run.sh X.exe ...  runs any .exe in the prefix
# Fixed path: the file lives in BArch and only a link sits here.
DIR="$HOME/Games/3dmark"
export WINEPREFIX="$DIR/prefix"
export PROTONPATH="$HOME/Games/battle.net/proton/current"
export GAMEID=umu-223850 STORE=none
export PROTON_SET_GAME_DRIVE=0
export PROTON_USE_NTSYNC=1
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
# Proton's accessibility helper (xalia) makes 3DMark's Chromium interface crawl
export PROTON_USE_XALIA=0

# red/blue swapped in HDR (A2R10G10B10 on NVIDIA + Hyprland): tools/vk-format-fix
export BARCH_VK_FORMAT_FIX=1

# MangoHud always loaded; the Control Center's Game HUD switch shows or hides it
command -v mangohud >/dev/null && export MANGOHUD=1

mkdir -p "$WINEPREFIX"
case "$1" in
    "")    set -- "$WINEPREFIX/drive_c/Program Files/UL/3DMark/3DMark.exe" ;;
    setup) set -- "$DIR/setup/3dmark-setup.exe" ;;
esac

if command -v gamemoderun >/dev/null; then
    exec gamemoderun umu-run "$@"
fi
exec umu-run "$@"
