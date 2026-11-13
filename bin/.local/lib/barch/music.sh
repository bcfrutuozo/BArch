# shellcheck shell=bash
# barch: music: the NAS pipeline's API (server/music) and the `barch music` command; the Claude runs are in music-agents.sh, the library and artists in music-library.sh.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# music: the pipeline runs in the barch-music container on the NAS (server/music); this only talks
# to its API with the URL and token install.sh left in ~/.config/barch/music.json
music_api() {   # music_api GET|POST <path> [json body]
  local conf="$HOME/.config/barch/music.json" url token
  [[ -r $conf ]] || die 3 "no $conf: run barch music install first"
  url=$(jq -r .url "$conf"); token=$(jq -r .token "$conf")
  OUT=$(curl -sS --max-time "${MUSIC_API_TIMEOUT:-60}" -X "$1" -H "X-Barch-Token: $token" -H "Content-Type: application/json" \
    ${3:+--data "$3"} "$url$2" 2>&1) || die 3 "music pipeline not reachable at $url ($OUT)"
  jq -e . >/dev/null 2>&1 <<<"$OUT" || die 3 "music pipeline answered: ${OUT:0:200}"
  [[ $(jq -r '.ok' <<<"$OUT") == true ]] || { [[ $JSON == 1 ]] && jq . <<<"$OUT"; die 1 "$(jq -r '.error // "failed"' <<<"$OUT")"; }
}

# music_upload <Artist/Album> <image file> <label>: POST the image itself as a new cover proposal
music_upload_job() {   # music_upload_job <id> <file>: the image becomes the job's chosen cover (checked by the pipeline)
  local conf="$HOME/.config/barch/music.json" url token ctype
  url=$(jq -r .url "$conf"); token=$(jq -r .token "$conf")
  case ${2,,} in *.png) ctype=image/png ;; *.webp) ctype=image/webp ;; *) ctype=image/jpeg ;; esac
  OUT=$(curl -sS --max-time 120 -X POST -H "X-Barch-Token: $token" -H "Content-Type: $ctype" \
    --data-binary "@$2" "$url/api/jobs/$1/cover?label=$(jq -rn --arg l "$(basename "$2")" '$l | @uri')" 2>&1) || die 3 "music pipeline not reachable ($OUT)"
  jq -e . >/dev/null 2>&1 <<<"$OUT" || die 3 "music pipeline answered: ${OUT:0:200}"
  [[ $(jq -r .ok <<<"$OUT") == true ]] || die 1 "$(jq -r '.error // "refused"' <<<"$OUT")"
}

music_upload() {
  local conf="$HOME/.config/barch/music.json" url token qs
  url=$(jq -r .url "$conf"); token=$(jq -r .token "$conf")
  qs=$(jq -rn --arg f "$1" --arg l "$3" '"folder=\($f | @uri)&label=\($l | @uri)"')
  OUT=$(curl -sS --max-time 120 -X POST -H "X-Barch-Token: $token" -H "Content-Type: image/jpeg" \
    --data-binary "@$2" "$url/api/covers/propose?$qs" 2>&1) || die 3 "music pipeline not reachable ($OUT)"
  jq -e . >/dev/null 2>&1 <<<"$OUT" || die 3 "music pipeline answered: ${OUT:0:200}"
  [[ $(jq -r .ok <<<"$OUT") == true ]] || die 1 "$(jq -r '.error // "refused"' <<<"$OUT")"
}

cmd_music() {
  local sub=${1:-status}
  (($#)) && shift
  need curl; need jq
  case $sub in
    browse) app_open music BARCH_MUSIC_PAGE "${1:-}" ;;
    status)
      music_api GET /api/status
      show "$OUT" '"music pipeline: " + ((.counts | to_entries | map(select(.value > 0) | "\(.value) \(.key)") | join(", ")) | if . == "" then "idle, nothing queued" else . end) + (if .running != "" then " · working on \(.running)" else "" end) + (if ((.missing // []) | length) > 0 then "\nMISSING in the container: " + (.missing | join(", ")) + " (custom-cont-init.d not run?)" else "" end)' ;;
    list)
      music_api GET "/api/jobs?state=${1:-review}"
      show "$OUT" '.jobs[] | "\(.id)  \(.state)\t\(.name)\(if .folder then "  →  " + .folder else "" end)\(if (.problems|length) > 0 then "\n      " + (.problems | join("\n      ")) else "" end)"' ;;
    show)
      [[ -n ${1:-} ]] || usage_error "music show <id>"
      music_api GET "/api/jobs/$1"
      show "$OUT" '.job | "\(.id)  \(.state)  \(.name)\nsource: \(.source)"
        + (if (.problems|length) > 0 then "\nproblems:\n  " + (.problems | join("\n  ")) else "" end)
        + (if (.notes|length) > 0 then "\nnotes:\n  " + (.notes | join("\n  ")) else "" end)
        + (if (.candidates|length) > 0 then "\ncandidates:\n" + (.candidates | map("  \(if .ok then "✓" else " " end) \(.score)  \(.artist) - \(.title)  \(.date) \(.country)  \(.tracks) tracks  \(.url)\n      \(.why | join("; "))") | join("\n")) else "" end)
        + (if .merge then "\nmerge into the library:\n" + ((.merge.add | map("  + " + .)) + (.merge.fix | map("  ~ " + .file + (if .rename != "" then " → " + .rename else "" end) + (if (.set|length) > 0 then "  " + (.set | to_entries | map("\(.key)=\(.value)") | join(", ")) else "" end) + (if (.drop|length) > 0 then "  −" + (.drop | join(" −")) else "" end) + (if .cover then "  +cover" else "" end))) + (.merge.review | map("  ! " + .)) | join("\n")) else "" end)
        + (if .result.merged then "\nmerged:\n  " + (.result.merged | join("\n  ")) else "" end)
        + (if .proposal then "\nproposal: \(.proposal.folder)  (\(.proposal.date), \(.proposal.genre))\n" + (.proposal.tracks | map("  " + .file) | join("\n")) else "" end)' ;;
    retry | reject | undo)
      [[ -n ${1:-} ]] || usage_error "music $sub <id> [--delete]"
      local del=false
      [[ $sub == reject && ${2:-} == --delete ]] && del=true    # the torrent / inbox folder goes once every album of it is settled
      music_api POST "/api/jobs/$1" "$(jq -cn --arg a "$sub" --argjson d "$del" '{action: $a} + (if $d then {delete: true} else {} end)')"
      show "$OUT" '"\(.job.id): \(.job.state)"' ;;
    cover)                                           # the cover found by hand, then the album runs with it
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "music cover <id> <file|URL> [label]"
      if [[ -f $2 ]]; then music_upload_job "$1" "$2"
      else music_api POST "/api/jobs/$1/cover" "$(jq -cn --arg u "$2" --arg l "${3:-}" '{url: $u, label: $l}')"; fi
      echo "$(jq -r .result <<<"$OUT")"
      music_api POST "/api/jobs/$1" '{"action": "resolve"}'
      show "$OUT" '"\(.job.id): \(.job.state) (queued again)"' ;;
    cover-ask) music_cover_ask_job "$@" ;;
    retitle)                                         # the ALBUM tag and the folder of an album already in /music
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "music retitle <Artist/Album> <new title>"
      music_api POST /api/library/retitle "$(jq -cn --arg f "$1" --arg a "$2" '{folder: $f, album: $a}')"
      show "$OUT" '.result' ;;
    mb-add) music_mb_add "$@" ;;
    rescan)                                          # the download taken in again from scratch (its old jobs superseded)
      [[ -n ${1:-} ]] || usage_error "music rescan <id>"
      music_api POST "/api/jobs/$1/rescan" '{}'
      show "$OUT" '.result + ": " + (.jobs | map(.id + "  " + .name) | join(", "))' ;;
    fix) music_fix_job "$@" ;;
    library) music_library "$@" ;;
    artists) music_artists "$@" ;;
    agent-sweep) music_agent_sweep "$@" ;;
    agent-sweep-run) music_agent_sweep_run "$@" ;;
    agent-sweep-item) music_agent_sweep_item "$@" ;;
    accept-year)                                     # the 29 "only the year exists" albums in one go (2026-11-08)
      local dry=0 days=0 ids
      while (($#)); do
        case $1 in
          --dry-run) dry=1 ;;
          --older-than) [[ ${2:-} =~ ^[0-9]+$ ]] || usage_error "music accept-year --older-than DAYS"; days=$2; shift ;;
          *) usage_error "music accept-year [--dry-run] [--older-than DAYS]" ;;
        esac
        shift
      done
      music_api GET "/api/jobs?state=review"
      ids=$(jq -r --argjson before "$(( $(date +%s) - days * 86400 ))" '.jobs[]
        | select(.state == "review" and (.problems | length) == 1 and (.problems[0] | test("^no full original release date")))
        | select((.updated // .created // 0) <= $before) | "\(.id)\t\(.name)"' <<<"$OUT")
      if [[ -z $ids ]]; then show '{"ok": true, "count": 0, "albums": []}' '"no album waits only on a year-only date"'; return 0; fi
      if ((dry)); then
        show "$(jq -Rn '[inputs | split("\t") | {id: .[0], name: .[1]}] | {ok: true, dry_run: true, count: length, albums: .}' <<<"$ids")" \
          '"\(.count) album(s) would get the year as YYYY-01-01:\n" + (.albums | map("  \(.id)  \(.name)") | join("\n"))'
        return 0
      fi
      local done=() id name
      while IFS=$'\t' read -r id name; do
        music_api POST "/api/jobs/$id" '{"action": "resolve", "overrides": {"date_year_only": true}}'
        done+=("$id")
        [[ $JSON == 1 ]] || echo "$id  $name: $(jq -r .job.state <<<"$OUT") (queued again)"
      done <<<"$ids"
      show "$(jq -n --argjson n "${#done[@]}" --argjson ids "$(printf '%s\n' "${done[@]}" | jq -R . | jq -s .)" '{ok: true, count: $n, resolved: $ids}')" \
        '"\(.count) album(s) queued again with the year as YYYY-01-01"' ;;
    resolve)
      [[ -n ${1:-} ]] || usage_error "music resolve <id> [--release ..] [--cover URL|file] [--date ..] [--genre ..] [--album ..] [--artist ..] [--title D.TT=..] [--replace]"
      local id=$1 body='{"action": "resolve"}'
      shift
      while (($#)); do
        case $1 in
          --release) body=$(jq --arg v "$2" '.release = $v' <<<"$body"); shift ;;
          --cover)                                   # a URL goes with the decision; a file is uploaded first
            if [[ -f $2 ]]; then music_upload_job "$id" "$2"; echo "$(jq -r .result <<<"$OUT")"
            else body=$(jq --arg v "$2" '.cover = $v' <<<"$body"); fi
            shift ;;
          --date|--genre|--album) body=$(jq --arg k "${1#--}" --arg v "$2" '.overrides[$k] = $v' <<<"$body"); shift ;;
          --artist) body=$(jq --arg v "$2" '.overrides.artist_folder = $v' <<<"$body"); shift ;;
          --title) [[ $2 == *=* ]] || usage_error "--title D.TT=Title (e.g. 1.03=Song)"
            body=$(jq --arg k "${2%%=*}" --arg v "${2#*=}" '.overrides.tracks[$k].TITLE = $v' <<<"$body"); shift ;;
          --replace) body=$(jq '.replace = true' <<<"$body") ;;
          --date-year-only) body=$(jq '.overrides.date_year_only = true' <<<"$body") ;;
          --keep-order) body=$(jq '.keep_order = true' <<<"$body") ;;
          --replace-tracks) body=$(jq --arg v "$2" '.replace_tracks = ($v | split(","))' <<<"$body"); shift ;;
          *) usage_error "music resolve: unknown option $1" ;;
        esac
        shift
      done
      music_api POST "/api/jobs/$id" "$body"
      show "$OUT" '"\(.job.id): \(.job.state) (queued again)"' ;;
    covers)
      local act=${1:-list}
      (($#)) && shift
      case $act in
        list)
          music_api GET /api/covers
          show "$OUT" '(if .running != "" then "checking \(.running) (\(.queued) more)\n" else "" end) + (.entries | map("\(.verdict)\t\(.folder)" + (if .proposal then "  ←  \(.proposal.source) \(.proposal.w)x\(.proposal.h)" else "" end) + (if .applied then "  (applied)" else "" end) + (if .error then "  " + .error else "" end)) | join("\n"))' ;;
        check)
          music_api POST /api/covers/check "$(jq -cn --arg a "${1:-}" '{artist: $a}')"
          show "$OUT" '.result' ;;
        pick)
          [[ -n ${1:-} && ${2:-} =~ ^[0-9]+$ ]] || usage_error "music covers pick <Artist/Album> <n>"
          music_api POST /api/covers/pick "$(jq -cn --arg f "$1" --argjson n "$2" '{folder: $f, alt: $n}')"
          show "$OUT" '.result' ;;
        propose)
          [[ -n ${1:-} && -n ${2:-} ]] || usage_error "music covers propose <Artist/Album> <file|URL> [label]"
          if [[ -f $2 ]]; then music_upload "$1" "$2" "${3:-$(basename "$2")}"
          else music_api POST /api/covers/propose "$(jq -cn --arg f "$1" --arg u "$2" --arg l "${3:-}" '{folder: $f, url: $u, label: $l}')"; fi
          show "$OUT" '.result' ;;
        ask) music_covers_ask "$@" ;;
        apply | undo | keep)
          [[ -n ${1:-} ]] || usage_error "music covers $act <Artist/Album>"
          music_api POST "/api/covers/$act" "$(jq -cn --arg f "$1" '{folder: $f}')"
          show "$OUT" '.result' ;;
        *) usage_error "music covers list|check [artist]|apply|undo|keep|pick|propose|ask <Artist/Album> ..." ;;
      esac ;;
    restart)
      music_api POST /api/restart '{}'
      show "$OUT" '"music pipeline: restarting"' ;;
    scan)
      music_api POST /api/scan '{}'
      show "$OUT" '"music pipeline: \(.new) new album(s) queued"' ;;
    lidarr-flac-only)
      music_api POST /api/lidarr/flac-only '{}'
      show "$OUT" '.result' ;;
    lidarr-monitor | lidarr-search)
      [[ -n ${1:-} ]] || usage_error "music $sub <album ids, comma separated> [on|off]"
      local ids body
      ids=$(jq -cn --arg v "$1" '$v | split(",") | map(tonumber)')
      if [[ $sub == lidarr-monitor ]]; then
        body=$(jq -cn --argjson ids "$ids" --arg m "${2:-on}" '{ids: $ids, monitored: ($m == "on")}')
        music_api POST /api/lidarr/monitor "$body"
      else
        music_api POST /api/lidarr/search "{\"ids\": $ids}"
      fi
      show "$OUT" '.result' ;;
    lidarr-artists)
      music_api GET "/api/lidarr/artists?q=$(jq -rn --arg v "${1:-}" '$v | @uri')"
      show "$OUT" '.artists[] | "\(.id)\t\(.name)  \(.albums) albums, \(.files)/\(.tracks) tracks\(if .monitored then "" else "  (unmonitored)" end)"' ;;
    lidarr-artist-set)
      [[ -n ${1:-} ]] || usage_error "music lidarr-artist-set all|<artist ids> [--monitored on|off] [--new-albums all|none|new]"
      local body ids
      if [[ $1 == all ]]; then ids='"all"'; else ids=$(jq -cn --arg v "$1" '$v | split(",") | map(tonumber)'); fi
      shift
      body=$(jq -cn --argjson ids "$ids" '{ids: $ids}')
      while [[ $# -gt 0 ]]; do
        case $1 in
          --monitored) body=$(jq -c --arg m "${2:-on}" '.monitored = ($m == "on")' <<<"$body"); shift 2 ;;
          --new-albums) body=$(jq -c --arg m "${2:-}" '.monitor_new_items = $m' <<<"$body"); shift 2 ;;
          *) usage_error "music lidarr-artist-set: unknown option $1" ;;
        esac
      done
      music_api POST /api/lidarr/artists "$body"
      show "$OUT" '.result' ;;
    lidarr-commands)
      music_api GET /api/lidarr/commands
      show "$OUT" '.commands[] | "\(.id)\t\(.name) \(.status)  \(.started[0:19])  artist \(.artist_id // "-")  albums \(.albums)  (\(.trigger))"' ;;
    lidarr-enforce)
      MUSIC_API_TIMEOUT=900 music_api POST /api/lidarr/enforce '{}'
      show "$OUT" '.result' ;;
    adopt)
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "music adopt \"<Artist/Album>\" <MusicBrainz release id or URL>"
      music_api POST /api/library/adopt "$(jq -cn --arg f "$1" --arg r "$2" '{folder: $f, release: $r}')"
      show "$OUT" '.result' ;;
    lidarr-add)
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "music lidarr-add <MusicBrainz artist id> <artist folder in /music>"
      music_api POST /api/lidarr/add-artists "$(jq -cn --arg m "$1" --arg f "$2" '{artists: [{mbid: $m, folder: $f}]}')"
      show "$OUT" '.result' ;;
    lidarr-cancel)
      [[ -n ${1:-} ]] || usage_error "music lidarr-cancel <command id>"
      music_api POST /api/lidarr/command-cancel "{\"id\": $1}"
      show "$OUT" '.result' ;;
    lidarr-queue)
      music_api GET /api/lidarr/queue
      show "$OUT" '.queue[] | "\(.id)\t\(.artist) - \(.album)  \(.status)/\(.state)  \(.left_gb)/\(.size_gb) GB  \(.title)"' ;;
    lidarr-queue-remove)
      [[ -n ${1:-} ]] || usage_error "music lidarr-queue-remove <queue ids, comma separated>|all [--keep]   (--keep leaves the download in the client)"
      local ids body keep=false
      [[ ${2:-} == --keep ]] && keep=true
      if [[ $1 == all ]]; then
        music_api GET /api/lidarr/queue
        ids=$(jq -c '[.queue[].id]' <<<"$OUT")
      else
        ids=$(jq -cn --arg v "$1" '$v | split(",") | map(tonumber)')
      fi
      body=$(jq -cn --argjson ids "$ids" --argjson k "$keep" '{ids: $ids, blocklist: true, from_client: ($k | not)}')
      music_api POST /api/lidarr/queue-remove "$body"
      show "$OUT" '.result' ;;
    lidarr-albums)
      [[ -n ${1:-} ]] || usage_error "music lidarr-albums <artist name or id>"
      music_api GET "/api/lidarr/albums?artist=$(jq -rn --arg v "$1" '$v | @uri')"
      show "$OUT" '.albums[] | "\(.id)\t\(.date)  \(.title)  [\(.type)\(if (.secondary|length) > 0 then ", " + (.secondary|join(", ")) else "" end)]  \(.files)/\(.tracks)\(if .monitored then "  monitored" else "" end)\(if .canon == null then "" elif .canon == "" then "  · unofficial" else "  · " + .canon end)"' ;;
    seeds)
      if [[ ${1:-} == check ]]; then
        music_api POST /api/seeds/check '{}'
        show "$OUT" '.result'
        return
      fi
      local days="" live=""
      for a in "$@"; do
        case $a in --live) live=1 ;; *) days=$a ;; esac
      done
      music_api GET "/api/seeds?days=${days:-0}${live:+&live=1}"
      show "$OUT" 'def gb: (. / 1e9 * 100 | round / 100 | tostring) + " GB";
        def hrs: (. / 3600 | floor | tostring) + " h";
        def line: "\(.torrents) torrents  up \(.uploaded|gb)  down \(.downloaded|gb)  ratio \(.ratio)  seed avg \(.avg_seeding_time|hrs)  below 1: \(.below_1)";
        "policy: delete at ratio \(.policy.ratio) after \(.policy.min_hours) h, or \(.policy.max_days) days after finishing; keep \(.policy.min_free_gb) GB free",
        "seeding for the pipeline: \(.seeding // [] | length)",
        (.seeding // [] | .[:20][] | "  ratio \(.ratio)/\(.goal)  up \(.uploaded|gb)  \(.seeding_time|hrs)  \(if .days_left != null then "\(.days_left) d left" else "" end)  \(.trackers|join(","))  \(.name)"),
        "removed from qBittorrent\(if .days > 0 then " (last \(.days) days)" else "" end): " + (.total|line),
        (.trackers[] | "  \(.tracker): " + line),
        (if (.recent|length) > 0 then "latest:" else empty end),
        (.recent[:15][] | "  \(.removed|strftime("%Y-%m-%d"))  \(.reason)\t\(.uploaded|gb) / \(.downloaded|gb)  ratio \(.ratio)  \(.seeding_time|hrs)  \(.trackers|join(","))  \(.name)"),
        (if .live then "still in qBittorrent: " + (.live.total|line), (.live.torrents[:15][] | "  \(.uploaded|gb) / \(.downloaded|gb)  ratio \(.ratio)  \(.seeding_time|hrs)  \(.trackers|join(","))  \(.name)") else empty end)' ;;
    digest)
      music_api GET "/api/digest${1:+?days=$1}"
      show "$OUT" '.text' ;;
    lidarr-pending)
      music_api GET /api/lidarr/pending
      show "$OUT" '.pending[] | "\(.folder)\t\(.mbid)  waiting since \(.since | strftime("%Y-%m-%d"))"' ;;
    lidarr-stalled)
      music_api GET "/api/lidarr/stalled${1:+?hours=$1}"
      show "$OUT" '"stalled for more than \(.hours) h (the hourly check replaces them):", (.stalled[] | "\(.id)\t\(.title)  \(.state) \(.progress)%  quiet \(.quiet_h) h")' ;;
    lidarr-release-profiles)
      music_api GET /api/lidarr/release-profiles
      show "$OUT" '.profiles[] | "\(.id)\t\(if .enabled then "on " else "off" end)  ignored: \(.ignored | join("  ·  "))\(if (.required|length) > 0 then "  required: " + (.required | join(", ")) else "" end)"' ;;
    lidarr-profiles)
      music_api GET /api/lidarr/metadata-profiles
      show "$OUT" '.profiles[] | "\(.id)\t\(.name): \(.primary|join(", ")) | \(.secondary|join(", ")) | \(.statuses|join(", "))"' ;;
    lidarr-profile)
      [[ -n ${1:-} ]] || usage_error "music lidarr-profile <name> [--primary A,B] [--secondary A,B] [--statuses A,B] [--apply all|ids]"
      local body
      body=$(jq -cn --arg n "$1" '{name: $n, primary: [], secondary: [], statuses: ["Official"]}')
      shift
      while (($#)); do
        case $1 in
          --primary|--secondary|--statuses) body=$(jq -c --arg k "${1#--}" --arg v "$2" '.[$k] = ($v | split(","))' <<<"$body"); shift ;;
          --apply) if [[ $2 == all ]]; then body=$(jq -c '.apply_to = "all"' <<<"$body")
                   else body=$(jq -c --arg v "$2" '.apply_to = ($v | split(",") | map(tonumber))' <<<"$body"); fi; shift ;;
          *) usage_error "music lidarr-profile: unknown option $1" ;;
        esac
        shift
      done
      music_api POST /api/lidarr/metadata-profile "$body"
      show "$OUT" '.result' ;;
    lidarr-lists)
      music_api GET /api/lidarr/import-lists
      show "$OUT" '.lists[] | "\(.id)\t\(.name) (\(.type))\(if .enabled then "" else "  disabled" end)  monitor: \(.monitor)  \(.fields | to_entries | map("\(.key)=\(.value)") | join(" "))"' ;;
    lidarr-list)
      [[ -n ${2:-} ]] || usage_error "music lidarr-list <Type> <name> [field=value ...] [--monitor none|specificAlbum|entireArtist] [--search]"
      local body
      body=$(jq -cn --arg t "$1" --arg n "$2" '{type: $t, name: $n, fields: {}, monitor: "specificAlbum"}')
      shift 2
      while (($#)); do
        case $1 in
          --monitor) body=$(jq -c --arg v "$2" '.monitor = $v' <<<"$body"); shift ;;
          --search) body=$(jq -c '.search = true' <<<"$body") ;;
          --metadata-profile|--quality-profile) body=$(jq -c --arg k "$(tr - _ <<<"${1#--}")" --arg v "$2" '.[$k] = $v' <<<"$body"); shift ;;
          *=*) body=$(jq -c --arg k "${1%%=*}" --arg v "${1#*=}" '.fields[$k] = (if ($v | test("^[0-9]+$")) then ($v | tonumber) else $v end)' <<<"$body") ;;
          *) usage_error "music lidarr-list: unknown option $1" ;;
        esac
        shift
      done
      music_api POST /api/lidarr/import-list "$body"
      show "$OUT" '.result' ;;
    install) exec "$REPO/server/music/install.sh" ;;
    *) usage_error "music status|browse [page]|covers ...|restart|list [state]|show <id>|resolve <id> ...|retry|reject|undo <id>|scan|lidarr-...|install" ;;
  esac
}
