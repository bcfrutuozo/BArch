#!/usr/bin/env bash
# passthrough.sh MODS KEY -- COMMAND...
#
# Runs COMMAND (the normal action of a keybind), unless the focused window is an X11
# app that is holding the keyboard (XGrabKeyboard): then the shortcut is sent to that
# window instead. This is what makes Super+Tab reach Windows through Parsec when its
# immersive mode is on.
#
# Why a script: Hyprland honors Wayland shortcut inhibitors, but Xwayland does not
# translate an X11 keyboard grab into one. It uses zwp_xwayland_keyboard_grab_v1,
# which Hyprland does not implement, so the compositor never learns about the grab and
# keeps acting on its own binds. The grab is still visible from the X side: a second
# client asking for the keyboard gets AlreadyGrabbed. That is the probe below.
#
# Usage in binds.lua:
#   hl.dsp.exec_cmd("~/.config/hypr/scripts/passthrough.sh SUPER Tab -- qs ipc call overview toggle")
set -u

mods=$1 key=$2
shift 2
[[ ${1:-} == -- ]] && shift
(( $# )) || { echo "usage: passthrough.sh MODS KEY -- COMMAND..." >&2; exit 2; }

# Only X11 windows can hold an X grab; everything else runs the command right away.
read -r xwayland addr < <(hyprctl -j activewindow 2>/dev/null | jq -r '"\(.xwayland) \(.address)"')

grabbed() {
    [[ ${xwayland:-} == true && -n ${DISPLAY:-} ]] || return 1
    python3 -I - <<'PY'
from Xlib import X, display
d = display.Display()
root = d.screen().root
status = root.grab_keyboard(False, X.GrabModeAsync, X.GrabModeAsync, X.CurrentTime)
d.sync()
if status == X.GrabSuccess:          # nobody had it: give it back at once
    root.ungrab_keyboard(X.CurrentTime)
    d.sync()
raise SystemExit(0 if status == X.AlreadyGrabbed else 1)
PY
}

if grabbed; then
    if [[ ${PASSTHROUGH_DRY:-} ]]; then
        echo "would send $mods+$key to $addr"
    else
        hyprctl dispatch "hl.dsp.send_shortcut({mods=\"$mods\", key=\"$key\", window=\"address:$addr\"})" >/dev/null
    fi
else
    if [[ ${PASSTHROUGH_DRY:-} ]]; then
        echo "would run: $*"
    else
        exec "$@"
    fi
fi
