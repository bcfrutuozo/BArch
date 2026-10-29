#!/usr/bin/env bash
# lock.sh — lock the session: the Quickshell lock, with hyprlock as the fallback.
#
#   lock.sh             what hypridle (lock_cmd) and the Hyprland autostart run
#   lock.sh --fallback  Super+Ctrl+Alt+L, works while locked: kill the Quickshell lock and put
#                       hyprlock in its place (for when the screen stays red/black)
#
# `qs -n` exits 0 at once if the lock is already running, and stays in the foreground until the
# session is unlocked (exit 0). Any other exit (QML error, crash, killed) means nothing is
# protecting the session: hyprlock takes over, which Hyprland accepts because of
# misc:allow_session_lock_restore.
set -u
lock="$HOME/.config/quickshell/lock"

if [[ ${1:-} == --fallback ]]; then
  pkill -f "qs -p $lock" 2>/dev/null
  sleep 0.5
  pidof hyprlock >/dev/null && exit 0
  exec hyprlock --immediate-render
fi

qs -p "$lock" -n
rc=$?
(( rc == 0 )) && exit 0
logger -t barch-lock "quickshell lock exited with status $rc; falling back to hyprlock"
pidof hyprlock >/dev/null && exit 0
exec hyprlock --immediate-render
