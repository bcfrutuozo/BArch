# shellcheck shell=bash
# barch: torrents: the statistics service on the NAS (server/torrents).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# torrents: the statistics service runs in its own container on the NAS (server/torrents); this only
# talks to its API with the URL and token install.sh left in ~/.config/barch/torrents.json
torrents_api() {   # torrents_api GET|POST <path>
  local conf="$HOME/.config/barch/torrents.json" url token
  [[ -r $conf && $(jq -r '.url // ""' "$conf") != "" ]] || die 3 "no service in $conf: run barch torrents install first"
  url=$(jq -r .url "$conf"); token=$(jq -r .token "$conf")
  OUT=$(curl -sS --max-time 30 -X "$1" -H "X-Barch-Token: $token" "$url$2" 2>&1) \
    || die 3 "torrent statistics not reachable at $url ($OUT)"
  jq -e . >/dev/null 2>&1 <<<"$OUT" || die 3 "torrent statistics answered: ${OUT:0:200}"
  [[ $(jq -r '.ok' <<<"$OUT") == true ]] || { [[ $JSON == 1 ]] && jq . <<<"$OUT"; die 1 "$(jq -r '.error // "failed"' <<<"$OUT")"; }
}

cmd_torrents() {
  local sub=${1:-status}
  (($#)) && shift
  need curl
  # bytes and ratios as the app writes them
  local fn='def b: if . == null then "—" elif . >= 1e12 then "\(. / 1e10 | round / 100) TB" elif . >= 1e9 then "\(. / 1e7 | round / 100) GB"
                   elif . >= 1e6 then "\(. / 1e5 | round / 10) MB" else "\(. / 1e3 | round) KB" end;
            def r: if . == null then "—" else (. * 1000 | round / 1000 | tostring) end;'
  case $sub in
    browse) app_open torrents BARCH_TORRENTS_PAGE "${1:-}" ;;
    status)
      torrents_api GET /api/status
      show "$OUT" '"torrents: " + (if .samples == 0 then "no sample yet" else "\(.samples) samples since \(.start | strflocaltime("%d/%m/%Y")), every \(.poll_s / 60 | floor) min, last \(.now - .last) s ago" end)
        + " · \(.live) torrents in the client, \(.torrents - .live) removed · qBittorrent \(.qbittorrent)"
        + (if (.indexers_missing | length) > 0 then "\nno API key for " + (.indexers_missing | join(", ")) + ": their torrents have no indexer" else "" end)
        + (if .error != "" then "\nERROR: qBittorrent: \(.error)" else "" end)' ;;
    summary)
      torrents_api GET "/api/overview?range=${1:-30d}"
      show "$OUT" "$fn"'"all time   ratio \(.now.ratio | r)   ↑ \(.now.alltime_ul | b)   ↓ \(.now.alltime_dl | b)"
        + "\nin range   ratio \(.range.ratio | r)   ↑ \(.range.up | b)   ↓ \(.range.down | b)" + (if .then then "   (all-time ratio was \(.then.ratio | r))" else "" end)
        + "\n24 h       ratio \(.day.ratio | r)   ↑ \(.day.up | b)   ↓ \(.day.down | b)"
        + "\n7 days     ratio \(.week.ratio | r)   ↑ \(.week.up | b)   ↓ \(.week.down | b)"
        + "\nnow        \(.now.torrents) torrents (\(.now.size | b)), \(.now.seeding) seeding · ↑ \(.now.up_speed | b)/s  ↓ \(.now.dl_speed | b)/s"
        + "\ngoal \(.goal)     \(.live.at_goal) of \(.live.done) finished torrents there, \(.live.below_1) below 1"' ;;
    sources)
      local by=indexer
      case ${1:-} in indexer | category | tracker) by=$1; shift ;; esac
      torrents_api GET "/api/groups?by=$by&range=${1:-30d}"
      show "$OUT" "$fn"'.groups[] | "\(if .key == "" then "(unknown)" else .key end)\t\(.live) torrents\(if .torrents > .live then " +\(.torrents - .live)" else "" end)\t↑ \(.up | b)\t↓ \(.down | b)\ttotal ↑ \(.total_up | b)\t↓ \(.total_down | b)\tratio \(.ratio | r)"' | column -t -s $'\t' ;;
    top)
      torrents_api GET "/api/torrents?sort=up&range=${1:-30d}&limit=${2:-20}"
      show "$OUT" "$fn"'.torrents[] | "↑ \(.up | b)\ttotal \(.total_up | b)\tratio \(.ratio | r)\t\(.category)\t\(.name[0:70])\(if .removed_at then "  (removed)" else "" end)"' | column -t -s $'\t' ;;
    sample)
      torrents_api POST /api/sample
      show "$OUT" '"torrents: sampling now"' ;;
    restart)
      torrents_api POST /api/restart
      show "$OUT" '"torrents: restarting"' ;;
    install) exec "$REPO/server/torrents/install.sh" ;;
    *) usage_error "torrents browse [page]|status|summary [range]|sources [by] [range]|top [range] [n]|sample|restart|install" ;;
  esac
}
