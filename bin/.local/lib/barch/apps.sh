# shellcheck shell=bash
# barch: apps with their own window: System Center, Packages, Mixer, Clip.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

cmd_center() { app_open center BARCH_CENTER_PAGE "${1:-}"; }
cmd_packages() { app_open packages BARCH_PACKAGES_PAGE "${1:-}"; }
cmd_mixer() { app_open mixer BARCH_MIXER_PAGE "${1:-}"; }

# clip [file] · clip info <file> · clip export <file> [edit...]: the video editor (quickshell/clip) and
# its ffmpeg side (clip.py, shared with the window). A running window gets the file over IPC.
CLIP_PY=$HOME/.config/quickshell/clip/clip.py
cmd_clip() {
  local sub=${1:-} file
  case $sub in
    info)
      [[ -n ${2:-} ]] || usage_error "clip info <file>"
      need python3
      show "$(python3 "$CLIP_PY" probe "$2")" '"\(.width)×\(.height) · \(.fps) fps · \(.codec)" + (if .bits > 8 then " \(.bits)-bit" else "" end) + (if .hdr then " · HDR" else "" end) + " · \(.duration | floor / 60 | floor):\(.duration | floor % 60 | tostring | if length < 2 then "0" + . else . end) · " + (if .audio then "\(.audio.codec) \(.audio.channels)ch" else "no audio" end) + (if .rotation != 0 then " · rotated \(.rotation)°" else "" end)' ;;
    export)
      shift
      need python3
      need ffmpeg
      if [[ $JSON == 1 ]]; then
        local out rc=0
        out=$(python3 "$CLIP_PY" export "$@" --json) || rc=$?
        jq . <<<"$(tail -1 <<<"$out")"
        return $rc
      fi
      python3 "$CLIP_PY" export "$@" ;;
    -*) usage_error "clip [<file>] · clip info <file> · clip export <file> [edit...]" ;;
    *)
      file=${1:-}
      if [[ -n $file ]]; then
        [[ -r $file ]] || die 1 "cannot read '$file'"
        file=$(readlink -f "$file")
      fi
      local cfg=$HOME/.config/quickshell/clip
      if qs -p "$cfg" ipc show >/dev/null 2>&1; then
        qs -p "$cfg" ipc call app open "$file" >/dev/null
      else
        env "BARCH_CLIP_FILE=$file" setsid -f qs -p "$cfg" >/dev/null 2>&1
      fi ;;
  esac
}
