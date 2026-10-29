#!/usr/bin/env bash
# lock.sh — lock the session with the Quickshell lock (quickshell/lock) and keep it locked.
#
#   lock.sh             what hypridle (lock_cmd) and the Hyprland autostart run
#   lock.sh --relaunch  Super+Ctrl+Alt+L, works while locked: kill the running lock and start a
#                       fresh one in its place (for when the screen stays red/black or frozen)
#
# There is no second locker (hyprlock was retired on 2026-10-29): this script is the supervisor.
# `qs -n` exits 0 at once if the lock is already running, and otherwise stays in the foreground
# until the session is unlocked (exit 0). Any other exit (QML error, crash, killed) leaves the
# session locked by Hyprland with nothing drawing on it (red screen), so the lock is started
# again, which Hyprland accepts because of misc:allow_session_lock_restore. After 3 quick
# failures it slows down to one try every 10 s while the session is still locked (the only way
# back in), and gives up with a critical notification when it is not.
#
# Before `qs -n`, an instance that is still around is asked (`ipc call lock state`) whether it is
# securing the session. One that answers secure=false already unlocked (or never locked) and is
# only in the way: it is killed so the new lock can start. An instance that does not answer is
# left alone, it may be the lock holding the session.
set -u
lock="$HOME/.config/quickshell/lock"
cmd="qs -p $lock -n"      # exact command line of the real lock (pgrep -x: never the preview)
tag=barch-lock

# Hyprland does not report the session lock directly; an active ext-session-lock is one of the
# reasons a monitor is not "solitary" (LOCK in solitaryBlockedBy), also after its client died.
session_locked() {
  hyprctl -j monitors 2>/dev/null | jq -e 'any(.[]; (.solitaryBlockedBy // []) | index("LOCK"))' >/dev/null 2>&1
}

lock_pid() { pgrep -fx -o "$cmd"; }

kill_lock() {   # kill_lock <pid>: TERM, then KILL after 2 s
  kill "$1" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  kill -KILL "$1" 2>/dev/null
}

if [[ ${1:-} == --relaunch ]]; then
  if pid=$(lock_pid); then
    logger -t $tag "relaunch requested: killing lock $pid"
    kill_lock "$pid"
    # the lock.sh supervising it sees the exit and starts a new one; step in only if none does
    sleep 2
    lock_pid >/dev/null && exit 0
  fi
elif pid=$(lock_pid); then
  state=$(timeout 3 qs -p "$lock" ipc call lock state 2>/dev/null)
  if [[ $state == *'"secure":false'* ]]; then
    logger -t $tag "quickshell lock $pid is not securing the session ($state); replacing it"
    kill_lock "$pid"
  fi
fi

failures=0
while :; do
  $cmd
  rc=$?
  (( rc == 0 )) && exit 0
  failures=$((failures + 1))
  if (( failures < 3 )); then
    logger -t $tag "quickshell lock exited with status $rc; starting it again ($failures)"
    sleep 1
  elif session_locked; then
    logger -t $tag "quickshell lock exited with status $rc ($failures times); session still locked, trying again in 10 s"
    sleep 10
  else
    logger -t $tag "quickshell lock exited with status $rc ($failures times) and the session is not locked; giving up"
    "$HOME/.local/bin/barch" notify "Lock screen" "The Quickshell lock failed $failures times and the session is NOT locked (journal: barch-lock)." --critical --app BArch
    exit 1
  fi
done
