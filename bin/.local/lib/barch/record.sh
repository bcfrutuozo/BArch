# shellcheck shell=bash
# barch: replay, microphone recording, Applio.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

REPLAYS=$HOME/Videos/Replays
SHARE_MAX=60                                           # WhatsApp status limit per video (s)

# secs <S|M:SS|H:MM:SS> → seconds (decimals kept), or fails
secs() {
  [[ $1 =~ ^([0-9]+:){0,2}[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -F: '{s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s}' <<<"$1"
}

# replay share [file] [--from T] [--to T]: the replay (default: the newest one) as an MP4 that
# WhatsApp and the like accept: H.264 + AAC, 1080p at most, 30 fps, HDR (PQ/HLG) tone mapped to
# SDR, at most SHARE_MAX seconds. Written next to the original as <name>-share.mp4.
replay_share() {
  local file="" from="" to="" t
  while (($#)); do
    case $1 in
      --from | --to)
        if [[ $# -lt 2 ]] || ! t=$(secs "$2"); then
          usage_error "$1 needs a time (seconds, M:SS or H:MM:SS)"
        fi
        [[ $1 == --from ]] && from=$t || to=$t
        shift ;;
      -*) usage_error "replay share: unknown option '$1'" ;;
      *) [[ -z $file ]] || usage_error "replay share [file] [--from T] [--to T]"; file=$1 ;;
    esac
    shift
  done
  need ffmpeg
  need ffprobe
  if [[ -z $file ]]; then
    file=$(find "$REPLAYS" -maxdepth 1 -name '*.mkv' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    [[ -n $file ]] || die 1 "no replays in $REPLAYS"
  fi
  [[ -r $file ]] || die 1 "cannot read '$file'"

  local info length transfer start len capped=false
  info=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer:format=duration \
    -of json "$file") || die 1 "not a video: $file"
  length=$(jq -r '.format.duration // 0' <<<"$info")
  transfer=$(jq -r '.streams[0].color_transfer // ""' <<<"$info")
  start=${from:-0}
  len=$(awk -v s="$start" -v e="${to:-$length}" -v l="$length" 'BEGIN {
    if (e > l) e = l; d = e - s; if (d < 0) d = 0; printf "%.3f", d }')
  awk -v d="$len" 'BEGIN { exit !(d > 0) }' || usage_error "replay share: empty range (the video has ${length%.*} s)"
  if awk -v d="$len" -v m="$SHARE_MAX" 'BEGIN { exit !(d > m) }'; then
    len=$SHARE_MAX capped=true
    [[ $JSON == 1 ]] || echo "$PROG: longer than ${SHARE_MAX} s, keeping ${start}s–$(awk -v s="$start" -v m="$SHARE_MAX" 'BEGIN { print s + m }')s" >&2
  fi

  # Downscale first: tone mapping in float at 4K runs at ~0.4x real time, at 1080p several times faster
  local vf="fps=30,scale=-2:'min(1080,ih)':flags=lanczos" hdr=false
  if [[ $transfer == smpte2084 || $transfer == arib-std-b67 ]]; then
    hdr=true
    vf+=",zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv"
  fi
  vf+=",format=yuv420p"

  local out=${file%.*}-share.mp4 tmp stats=()
  tmp=${out%.mp4}.part.mp4
  [[ $JSON == 1 ]] || stats=(-stats)
  [[ $JSON == 1 ]] || echo "Converting $(basename "$file") → $(basename "$out")…" >&2
  if ! ffmpeg -nostdin -hide_banner -loglevel error "${stats[@]}" -y \
    -ss "$start" -i "$file" -t "$len" -map 0:v:0 -map '0:a:0?' -vf "$vf" \
    -c:v libx264 -preset slow -crf 23 -profile:v high -c:a aac -b:a 128k -ac 2 \
    -movflags +faststart "$tmp"; then
    rm -f "$tmp"
    die 1 "ffmpeg failed on $file"
  fi
  mv -f "$tmp" "$out"

  show "$(jq -n --arg f "$out" --arg src "$file" --argjson from "$start" --argjson len "$len" \
    --argjson hdr "$hdr" --argjson capped "$capped" --argjson size "$(stat -c %s "$out")" \
    '{ok: true, file: $f, source: $src, from: $from, duration: $len, hdr: $hdr, capped: $capped, size: $size}')" \
    '"\(.file)\n\(.duration) s, \(.size / 1048576 * 10 | round / 10) MB" + (if .hdr then ", HDR tone mapped to SDR" else "" end)'
}

cmd_applio() {
  local sh=$REPO/quickshell/.config/quickshell/applio/applio.sh sub=${1:-open}
  case $sub in
    open | start | stop) bash "$sh" "$sub" ;;
    status)
      local st url=""
      st=$(bash "$sh" status)
      [[ $st == running\ * ]] && { url=${st#running }; st=running; }
      OUT=$(jq -nc --arg s "$st" --arg u "$url" '{ok: true, state: $s, url: $u}')
      show "$OUT" 'if .url != "" then "\(.state): \(.url)" else .state end'
      ;;
    *) usage_error "applio open|start|stop|status" ;;
  esac
}

cmd_mic() {
  local sh=$REPO/quickshell/.config/quickshell/record/mic.sh sub=${1:-status}
  case $sub in
    toggle | start | stop) bash "$sh" "$sub" ;;
    status)
      local st file since=0 rec=false
      st=$(bash "$sh" status)
      if [[ $st == recording\ * ]]; then
        rec=true; read -r _ since file <<<"$st"; since=$(($(date +%s) - since))
      fi
      OUT=$(jq -nc --argjson r "$rec" --arg f "${file:-}" --argjson s "$since" '{ok: true, recording: $r, file: $f, seconds: $s}')
      show "$OUT" 'if .recording then "recording \(.seconds)s: \(.file)" else "idle" end'
      ;;
    *) usage_error "mic toggle|start|stop|status" ;;
  esac
}

cmd_replay() {
  local sub=${1:-}
  (($#)) && shift
  case $sub in
    share) replay_share "$@" ;;
    *) usage_error "replay share [file] [--from T] [--to T]" ;;
  esac
}
