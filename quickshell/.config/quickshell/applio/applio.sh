#!/usr/bin/env bash
# applio.sh — Applio (RVC voice conversion, ~/Applications/Applio, not part of the repo) as a
# background web server: the launcher's "Applio" entry, `barch applio` and the bar's tray icon.
#   applio.sh open     start the server if needed, wait for it, open it in the browser
#   applio.sh start    start the server only
#   applio.sh stop     stop it (the tray's right click)
#   applio.sh status   "running <url>", "starting" or "stopped"
# The server runs as a transient user unit (applio), so it outlives the bar and the terminal;
# the tray icon shows while the unit is up. One started by hand (./run-applio.sh) is noticed by
# its port and stopped too.

dir="${APPLIO_DIR:-$HOME/Applications/Applio}"
port="${APPLIO_PORT:-6969}"
url="http://127.0.0.1:$port"
unit=applio

poke_bar() { qs ipc call applio refresh >/dev/null 2>&1 || true; }
notify() { barch notify "$1" "$2" --app Applio >/dev/null 2>&1 || notify-send -a Applio "$1" "$2" 2>/dev/null || true; }
active() { systemctl --user is-active --quiet "$unit"; }
answers() { curl -s -o /dev/null -m 2 "$url/"; }
# pids of an Applio started by hand that holds the port
strays() {
  local pid
  for pid in $(pgrep -f "python.* app\.py" 2>/dev/null); do
    [[ $(readlink -f "/proc/$pid/cwd" 2>/dev/null) == "$(readlink -f "$dir")" ]] && echo "$pid"
  done
}

start() {
  answers && return 0
  active && return 0
  [[ -x "$dir/.venv/bin/python" && -f "$dir/app.py" ]] || {
    notify "Applio" "not installed in $dir"; exit 1; }
  systemctl --user reset-failed "$unit" 2>/dev/null
  systemd-run --user --unit="$unit" --collect -p WorkingDirectory="$dir" -p TimeoutStopSec=15 \
    -E GRADIO_ANALYTICS_ENABLED=False -E PYTHONUNBUFFERED=1 \
    "$dir/.venv/bin/python" app.py --port "$port" >/dev/null 2>&1 || {
    notify "Applio" "could not start the server"; exit 1; }
  poke_bar
}

wait_up() {   # the first start loads torch and the models: ~10-20 s
  local i
  for ((i = 0; i < 180; i++)); do
    answers && return 0
    active || strays | grep -q . || return 1
    sleep 0.5
  done
  return 1
}

case "$1" in
  open)
    start
    if wait_up; then
      poke_bar
      xdg-open "$url" >/dev/null 2>&1 &
    else
      notify "Applio" "the server did not come up: journalctl --user -u $unit"
      poke_bar; exit 1
    fi
    ;;
  start) start ;;
  stop)
    active && systemctl --user stop "$unit"
    mapfile -t pids < <(strays)
    ((${#pids[@]})) && kill "${pids[@]}" 2>/dev/null
    poke_bar
    ;;
  status)
    if answers; then echo "running $url"
    elif active || strays | grep -q .; then echo starting
    else echo stopped
    fi
    ;;
  *) echo "usage: applio.sh open | start | stop | status" >&2; exit 2 ;;
esac
