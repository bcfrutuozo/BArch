# shellcheck shell=bash
# barch: player: the Player app (quickshell/player) over its IPC.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# player: the Player app (quickshell/player) over its IPC; `browse` starts it, the rest needs it running
player_ipc() {   # player_ipc <fn> [arg]: a JSON answer from the app (die 3 when the window is not open)
  local cfg=$HOME/.config/quickshell/player
  qs -p "$cfg" ipc show >/dev/null 2>&1 || die 3 "the Player is not open (barch player browse)"
  OUT=$(qs -p "$cfg" ipc call app "$@" 2>&1) || die 1 "player: ${OUT:0:200}"
  [[ -z $OUT ]] && OUT='{"ok": true}'
}
cmd_player() {
  local sub=${1:-browse}
  (($#)) && shift
  case $sub in
    browse | open) app_open player BARCH_PLAYER_PAGE "${1:-}" ;;
    albums | artists | tracks | genres | queue | favorites | recent | lyrics | stats | viz | settings) app_open player BARCH_PLAYER_PAGE "$sub" ;;
    play | pause | toggle | next | prev | stop | like | hide | quit)
      player_ipc "$sub"; show "$OUT" '"player: '"$sub"'"' ;;
    show) player_ipc window; show "$OUT" '"player: window shown"' ;;
    volume | seek)
      [[ -n ${1:-} ]] || usage_error "player $sub <value>"
      player_ipc "$sub" "$1"; show "$OUT" '"player: '"$sub $1"'"' ;;
    shuffle | repeat)
      player_ipc "$sub" "${1:-}"; show "$OUT" '"player: '"$sub ${1:-toggled}"'"' ;;
    status)
      player_ipc status
      show "$OUT" '(if .track then "\(if .playing then "playing" else (if .idle then "stopped" else "paused" end) end): \(.track.title) · \(.track.artist) · \(.track.album)  \(.position / 60 | floor):\(.position % 60 | tostring | if length < 2 then "0" + . else . end) / \(.duration / 60 | floor):\(.duration % 60 | tostring | if length < 2 then "0" + . else . end)" else "nothing playing" end) + "\nqueue \(.queue) (at \(.index + 1)) · volume \(.volume) · shuffle \(if .shuffle then "on" else "off" end) · repeat \(.repeat) · library \(.albums) albums, \(.tracks) tracks"' ;;
    album | play-album | queue-album)
      [[ -n ${1:-} ]] || usage_error "player $sub \"Artist/Album\""
      local fn=album; [[ $sub == play-album ]] && fn=playAlbum; [[ $sub == queue-album ]] && fn=queueAlbum
      player_ipc "$fn" "$1"
      jq -e .ok >/dev/null <<<"$OUT" || die 1 "player: $(jq -r .error <<<"$OUT")"
      show "$OUT" '"player: '"$sub $1"'" + (if .tracks then " (\(.tracks) tracks)" else "" end)' ;;
    playlist)
      [[ -n ${1:-} ]] || usage_error "player playlist <name>"
      player_ipc playlist "$1"
      jq -e .ok >/dev/null <<<"$OUT" || die 1 "player: $(jq -r .error <<<"$OUT")"
      show "$OUT" '"player: playing the playlist (\(.tracks) tracks)"' ;;
    eq)
      player_ipc eq "$*"
      jq -e .ok >/dev/null <<<"$OUT" || die 1 "player: $(jq -r .error <<<"$OUT")"
      show "$OUT" '(if .preset then "player: equalizer preset \(.preset)" elif .on != null then "player: equalizer \(if .on then "on" else "off" end)" elif .presets then "equalizer \(if .eq.on then "on" else "off" end) · preamp \(.eq.preamp) dB · bands \(.eq.gains | map(tostring) | join(" ")) dB\npresets: \(.presets | join(", "))" else "player: equalizer set" end)' ;;
    search)
      [[ -n ${1:-} ]] || usage_error "player search <text>"
      if qs -p "$HOME/.config/quickshell/player" ipc show >/dev/null 2>&1; then qs -p "$HOME/.config/quickshell/player" ipc call app search "$1" >/dev/null
      else BARCH_PLAYER_PAGE=search setsid -f qs -p "$HOME/.config/quickshell/player" >/dev/null 2>&1; fi ;;
    plex)
      case ${1:-status} in
        status)
          music_api GET /api/player/status
          show "$OUT" '(if .enabled then "Plex \(.url): \(.albums_cached) albums mapped" else "Plex: no token in the pipeline\x27s secrets.json" end)
            + (if .last.t then "\nlast: \(.last.state) \(.last.folder)/\(.last.file)" + (if .last.error then " — \(.last.error)" else " → Plex #\(.last.key) at \(.last.time / 1000 | floor) s of \(.last.duration / 1000 | floor)" end) else "\nnothing reported yet" end)
            + (if (.sessions | length) > 0 then "\nsessions: " + ([.sessions[] | "\(.device): \(.file) (\(.state))"] | join(", ")) else "" end)' ;;
        sessions)
          music_api GET /api/player/sessions
          show "$OUT" 'if (.sessions | length) == 0 then "Plex: nothing playing" else .sessions[] | "\(.grandparentTitle // .parentTitle // "") · \(.title) — \(.Player.product // "?") on \(.Player.title // .Player.device // "?") (\(.Player.state // "?")), user \(.User.title // "?")" end' ;;
        *) usage_error "player plex [status|sessions]" ;;
      esac ;;
    catalog)
      case ${1:-} in
        refresh) music_api POST "/api/catalog/refresh$([[ ${2:-} == --full ]] && echo '?full=1')"; show "$OUT" '"player: the NAS is reading the library again"' ;;
        status | "") music_api GET /api/catalog/status; show "$OUT" '"catalog: version \(.version), \(.albums) albums, \(.tracks) tracks, read \(.scanned | strflocaltime("%d/%m %H:%M"))"
          + (if .scanning then " · reading now" + (if .progress.total then ": \(.progress.done) of \(.progress.total) albums looked at, \(.progress.read) read, \(((now - .progress.started) / 60) | floor) min" else "" end) else "" end)
          + (if .last.read != null then " · last pass: \(.last.read) read, \(.last.removed) removed in \(.last.seconds) s" else "" end)' ;;
        *) usage_error "player catalog [status|refresh [--full]]" ;;
      esac ;;
    *) usage_error "player [browse] [page]|play|pause|toggle|next|prev|stop|status|volume|seek|like|shuffle|repeat|album|play-album|queue-album|playlist|search|eq|plex|catalog|show|hide|quit" ;;
  esac
}
