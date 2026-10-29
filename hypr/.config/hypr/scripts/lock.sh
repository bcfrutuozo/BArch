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
#
# Before `qs -n`, an instance that is still around is asked (`ipc call lock state`) whether it is
# securing the session. One that answers secure=false already unlocked (or never locked) and is
# only in the way: it is killed so the new lock can start. An instance that does not answer is
# left alone, it may be the lock holding the session.
set -u
lock="$HOME/.config/quickshell/lock"
cmd="qs -p $lock -n"      # exact command line of the real lock (pgrep -x: never the preview)

if [[ ${1:-} == --fallback ]]; then
  pkill -fx "$cmd" 2>/dev/null
  sleep 0.5
  pidof hyprlock >/dev/null && exit 0
  exec hyprlock --immediate-render
fi

if pid=$(pgrep -fx -o "$cmd"); then
  state=$(timeout 3 qs -p "$lock" ipc call lock state 2>/dev/null)
  if [[ $state == *'"secure":false'* ]]; then
    logger -t barch-lock "quickshell lock $pid is not securing the session ($state); replacing it"
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
fi

$cmd
rc=$?
(( rc == 0 )) && exit 0
logger -t barch-lock "quickshell lock exited with status $rc; falling back to hyprlock"
pidof hyprlock >/dev/null && exit 0
exec hyprlock --immediate-render
