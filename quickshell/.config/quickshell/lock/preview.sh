#!/usr/bin/env bash
# preview.sh — open the lock screen preview (a normal window, own Shell ID), screenshot it and
# close ONLY that preview, by PID. This is the only way agents may look at the lock screen:
# the real lock (lock/shell.qml) is never started, killed or reloaded from here.
#
#   preview.sh [out.png] [seconds]     default: lock-preview.png in the current dir, 4 s
set -u
out=${1:-lock-preview.png}
secs=${2:-4}
cfg="$HOME/.config/quickshell/lock/preview.qml"
log=$(mktemp -t lock-preview.XXXXXX.log)

qs -p "$cfg" >"$log" 2>&1 &
pid=$!
sleep "$secs"
if ! kill -0 "$pid" 2>/dev/null; then
  echo "preview exited early:" >&2; cat "$log" >&2; rm -f "$log"; exit 1
fi

geo=$(hyprctl -j clients 2>/dev/null | python3 -I -c '
import json, sys
for c in json.load(sys.stdin):
    if c.get("title") == "BArch lock (preview)":
        print("%d,%d %dx%d" % (c["at"][0], c["at"][1], c["size"][0], c["size"][1])); break')
if [[ -n "$geo" ]] && command -v grim >/dev/null; then
  grim -g "$geo" "$out" && echo "screenshot: $out ($geo)"
else
  echo "preview window not found for the screenshot" >&2
fi

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
grep -E "WARN|ERROR" "$log" && echo "(warnings above come from $cfg)" >&2
rm -f "$log"
