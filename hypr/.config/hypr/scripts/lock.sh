#!/usr/bin/env bash
# lock.sh — lock the session with the Quickshell lock (quickshell/lock) and keep it locked.
#
#   lock.sh             lock now: what hypridle (lock_cmd), Super+L (through loginctl) and the
#                       Hyprland autostart run
#   lock.sh --daemon    the supervisor: runs the resident lock process and restarts it if it dies
#                       (started on demand by the other modes; one per session, flock)
#   lock.sh --relaunch  Super+Ctrl+Alt+L, works while locked: kill the running lock and start a
#                       fresh one in its place (for when the screen stays red/black or frozen).
#                       Also how an edit under quickshell/lock/ is applied (safe while unlocked:
#                       nothing is drawn, the new process just goes idle).
#
# The lock is a RESIDENT Quickshell process (`qs -p ~/.config/quickshell/lock -n`): it starts at
# login, sits idle with no surfaces, and `ipc call lock lock` makes it lock. That way a lock
# request only has to draw one frame per monitor; starting Quickshell on every lock took ~250 ms
# during which the desktop stayed on screen. There is no second locker (hyprlock was retired on
# 2026-10-29): this script is the supervisor.
#
# `qs -n` exits 0 at once if the lock is already running, and otherwise stays in the foreground
# for the life of the process. Any other exit (QML error, crash, killed, or the lock itself
# leaving because the compositor ended the session lock) is restarted by the daemon, and if the
# session is still locked at that point (red screen: Hyprland keeps it locked, nothing drawing
# on it) the new process is told to lock again, which Hyprland accepts because of
# misc:allow_session_lock_restore. After 3 quick failures it slows down to one try every 10 s
# while the session is locked (the only way back in), and gives up with a critical notification
# when it is not (the next lock request starts a daemon again).
set -u
self=$(readlink -f "${BASH_SOURCE[0]}")
lock="$HOME/.config/quickshell/lock"
cmd="qs -p $lock -n"      # exact command line of the real lock (pgrep -x: never the preview)
tag=barch-lock
runtime="${XDG_RUNTIME_DIR:-/tmp}/barch-lock"
mkdir -p "$runtime"

# Is the session locked? The resident lock keeps $runtime/locked while it wants the session
# locked (also after it died: that is the point). Hyprland does not report the session lock
# directly; an active ext-session-lock is one of the reasons a monitor is not "solitary" (LOCK in
# solitaryBlockedBy), but that is not reliable right after the lock client died, so it is only the
# second opinion.
session_locked() {
  [[ -e "$runtime/locked" ]] && return 0
  hyprctl -j monitors 2>/dev/null | jq -e 'any(.[]; (.solitaryBlockedBy // []) | index("LOCK"))' >/dev/null 2>&1
}

lock_pid() { pgrep -fx -o "$cmd"; }

ipc() { timeout 3 qs -p "$lock" ipc call lock "$1" 2>/dev/null; }   # ipc lock|state -> JSON

kill_lock() {   # kill_lock <pid>: TERM, then KILL after 2 s
  kill "$1" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  kill -KILL "$1" 2>/dev/null
}

# wait_ready [seconds]: until the resident process answers `state` (startup takes ~150 ms)
wait_ready() {
  local i n=$(( ${1:-5} * 20 ))
  for (( i = 0; i < n; i++ )); do
    ipc state >/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# the daemon holds $runtime/daemon.lock (flock) for as long as it runs
daemon_running() { flock -n -E 75 "$runtime/daemon.lock" true 2>/dev/null; [[ $? -eq 75 ]]; }

ensure_daemon() {   # start the supervisor (which starts the lock) if none is running
  daemon_running && return 0
  setsid -f "$self" --daemon >/dev/null 2>&1 </dev/null
}

not_locked() {
  logger -t $tag "$1; session NOT locked"
  "$HOME/.local/bin/barch" notify "Lock screen" "$1: the session is NOT locked (journal: barch-lock)." --critical --app BArch
  return 1
}

# send the lock request; starts the resident lock if there is none and replaces one that hangs
request_lock() {
  local pid state
  if state=$(ipc lock); then logger -t $tag "lock requested: $state"; return 0; fi   # the usual path
  if pid=$(lock_pid); then
    # there, but not answering yet: give a starting instance a moment, replace a hung one
    if wait_ready 3 && state=$(ipc lock); then logger -t $tag "lock requested: $state"; return 0; fi
    logger -t $tag "quickshell lock $pid does not answer; replacing it"
    kill_lock "$pid"
  fi
  ensure_daemon
  wait_ready 8 || not_locked "The Quickshell lock did not start" || return 1
  state=$(ipc lock) || not_locked "The Quickshell lock did not take the lock request" || return 1
  logger -t $tag "lock requested: $state"
}

case ${1:-} in
  --daemon)
    exec 9>"$runtime/daemon.lock"
    flock -n 9 || exit 0                      # one supervisor per session
    rm -f "$runtime/relaunch"
    failures=0
    while :; do
      relock=0; session_locked && relock=1
      started=$SECONDS
      # BARCH_LOCK_RELOCK: a previous instance died with the session locked (red screen): the new
      # one locks itself as soon as it is up; the ipc call below is only the fallback
      BARCH_LOCK_RELOCK=$relock $cmd 9>&- &     # without the daemon's flock fd
      qspid=$!
      if (( relock )) && wait_ready 8; then
        logger -t $tag "session still locked: locking again with the new instance"
        ipc lock >/dev/null
      fi
      wait "$qspid"; rc=$?
      (( rc == 0 )) && exit 0                   # another instance is running (-n), or it quit on purpose
      if [[ -e "$runtime/relaunch" ]]; then     # --relaunch killed it on purpose: not a failure
        rm -f "$runtime/relaunch"
        logger -t $tag "quickshell lock exited with status $rc after a relaunch request; starting it again"
        continue
      fi
      (( SECONDS - started > 60 )) && failures=0
      failures=$((failures + 1))
      if (( failures < 3 )); then
        logger -t $tag "quickshell lock exited with status $rc; starting it again ($failures)"
        sleep 1
      elif session_locked; then
        logger -t $tag "quickshell lock exited with status $rc ($failures times); session still locked, trying again in 10 s"
        sleep 10
      else
        logger -t $tag "quickshell lock exited with status $rc ($failures times) and the session is not locked; giving up"
        "$HOME/.local/bin/barch" notify "Lock screen" "The Quickshell lock failed $failures times (journal: barch-lock). Super+L starts it again." --critical --app BArch
        exit 1
      fi
    done
    ;;
  --relaunch)
    if pid=$(lock_pid); then
      logger -t $tag "relaunch requested: killing lock $pid"
      daemon_running && touch "$runtime/relaunch"
      kill_lock "$pid"
    fi
    # the daemon restarts it and locks again if the session is still locked; step in if there is none
    sleep 0.5
    daemon_running && exit 0
    rm -f "$runtime/relaunch"
    if session_locked; then request_lock; else ensure_daemon; fi
    ;;
  "")
    request_lock
    ;;
  *)
    echo "usage: lock.sh [--daemon|--relaunch]" >&2; exit 2 ;;
esac
