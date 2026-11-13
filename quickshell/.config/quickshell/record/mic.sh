#!/usr/bin/env bash
# mic.sh — records the microphone to a WAV (Super+R, `barch mic`, the bar's indicator).
#   mic.sh toggle   start, or stop and save
#   mic.sh start | stop
#   mic.sh status   "recording <start, seconds since 1970> <file>" or "idle"
# pw-record from the default source (the fifine), 48 kHz mono 24-bit: what Applio and an
# editor want, with no conversion. It runs as a transient user unit (barch-mic-record), so it
# keeps going if the bar restarts; stopping sends SIGINT, which makes pw-record write the WAV
# header's final sizes before exiting.

unit=barch-mic-record
last="${XDG_RUNTIME_DIR:-/tmp}/barch-mic-record.file"   # file of the recording in progress
dir="${MIC_RECORD_DIR:-$HOME/Recording}"

poke_bar() { qs ipc call micrec refresh >/dev/null 2>&1 || true; }

notify() {   # notify <title> <body> [--action L=cmd]...
  if command -v barch >/dev/null; then barch notify "$@" --app "Recording" >/dev/null 2>&1 && return; fi
  notify-send -a Recording "$1" "$2" 2>/dev/null || true
}

active() { systemctl --user is-active --quiet "$unit"; }

start() {
  active && return 0
  command -v pw-record >/dev/null || { notify "Microphone recording" "pw-record not found (pipewire)"; exit 1; }
  mkdir -p "$dir"
  file="$dir/$(date +%Y-%m-%d_%H-%M-%S).wav"
  printf '%s' "$file" > "$last"
  systemctl --user reset-failed "$unit" 2>/dev/null
  # media.name names the stream in the mixer and the privacy indicator (which then shows the mic in use)
  # pw-record exits 1 on the SIGINT that stops it, with the file complete: not a failure
  systemd-run --user --unit="$unit" --collect -p KillSignal=SIGINT -p SuccessExitStatus=1 -p TimeoutStopSec=10 \
    pw-record --rate 48000 --channels 1 --format s24 \
      -P '{ media.name = "BArch mic recording" node.name = "barch-mic-record" }' "$file" >/dev/null 2>&1 || {
    rm -f "$last"; notify "Microphone recording" "could not start pw-record"; exit 1; }
  poke_bar
}

stop() {
  active || { rm -f "$last"; poke_bar; return 0; }
  systemctl --user stop "$unit"              # waits for pw-record to close the file
  file=$(cat "$last" 2>/dev/null); rm -f "$last"
  poke_bar
  [[ -n "$file" && -s "$file" ]] || { notify "Microphone recording" "nothing was saved"; return 1; }
  len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null)
  len=$(awk -v s="${len:-0}" 'BEGIN { s = int(s + 0.5); printf "%d:%02d", s / 60, s % 60 }')
  notify "Recording saved" "$(basename "$file")  ·  $len" \
    --action "Play=xdg-open $(printf %q "$file")" \
    --action "Folder=xdg-open $(printf %q "$dir")"
}

case "$1" in
  start) start ;;
  stop) stop ;;
  toggle) if active; then stop; else start; fi ;;
  status)
    if active; then
      t=$(systemctl --user show "$unit" -p ActiveEnterTimestamp --value)
      echo "recording $(date -d "$t" +%s 2>/dev/null || date +%s) $(cat "$last" 2>/dev/null)"
    else
      echo idle
    fi
    ;;
  *) echo "usage: mic.sh toggle | start | stop | status" >&2; exit 2 ;;
esac
