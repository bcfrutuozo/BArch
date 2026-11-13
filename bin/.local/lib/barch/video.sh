# shellcheck shell=bash
# barch: video: the PT-BR pipeline on the NAS (server/video), Radarr and Sonarr.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# video: the pipeline runs in its own container on the NAS (server/video); this only talks to its
# API with the URL and token install.sh left in ~/.config/barch/video.json (.pipeline)
video_api() {   # video_api GET|POST <path> [json body]
  local conf="$HOME/.config/barch/video.json" url token
  if [[ ! -r $conf ]] || ! jq -e .pipeline.token "$conf" >/dev/null 2>&1; then
    die 3 "no pipeline in $conf: run barch video install first"
  fi
  url=$(jq -r .pipeline.url "$conf"); token=$(jq -r .pipeline.token "$conf")
  OUT=$(curl -sS --max-time "${VIDEO_API_TIMEOUT:-60}" -X "$1" -H "X-Barch-Token: $token" -H "Content-Type: application/json" \
    ${3:+--data "$3"} "$url$2" 2>&1) || die 3 "video pipeline not reachable at $url ($OUT)"
  jq -e . >/dev/null 2>&1 <<<"$OUT" || die 3 "video pipeline answered: ${OUT:0:200}"
  [[ $(jq -r '.ok' <<<"$OUT") == true ]] || { [[ $JSON == 1 ]] && jq . <<<"$OUT"; die 1 "$(jq -r '.error // "failed"' <<<"$OUT")"; }
}

# video fix <id> ["hint"]: Fix with Agent for a dub job (quickshell/video/job-fix.md). Claude gets the job as
# barch video show prints it, researches the Brazilian title and the releases out there, searches Prowlarr
# through the pipeline with its own queries (barch video search), adds a release it found elsewhere (barch
# video add), picks a candidate (use) or retries, and reports; the download and the mux run in the pipeline
# afterwards, so the answer says what was queued and what is left for Bruno
video_fix_job() {
  local id=${1:-} hint=${2:-}
  [[ -n $id ]] || usage_error "video fix <id> [\"hint\"]"
  need claude
  video_api GET "/api/jobs/$id"
  local job run
  job=$(jq -c .job <<<"$OUT")
  run=$STATE/video-agent/job-$id-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$run"
  {
    echo "# Context"
    echo
    echo "- Job id: \`$id\` (use exactly this with barch video show / search / add / use / retry)"
    jq -r '"- Title: \(.title) (\(.year)) · original language \(.original) · IMDb \(.imdb // "?")\n- State: \(.state)\(if .reason != "" then " · " + .reason else "" end)\n- Kind: \(if .kind == "season" then "a season of a series (donor: a dubbed season pack, a range or single episodes)" else "a movie" end)\n- Audio now: \(.audio // [] | join(", "))\n- Titles the pipeline searched: \(.titles // [] | join(" · "))"' <<<"$job"
    echo "- Run folder (write here only): $run"
    if [[ -n $hint ]]; then echo; echo "## Bruno's hint"; echo; echo "$hint"; fi
    echo
    echo "## The job, as barch video show prints it"
    echo
    echo '```'
    "$0" video show "$id" 2>/dev/null || jq . <<<"$job"
    echo '```'
    echo
    echo "## The job as JSON (candidates with their guid and url, episodes, alignment, history)"
    echo
    echo '```json'
    jq '{id, kind, state, reason, title, show, year, original, imdb, file, audio, runtime, titles, failures, donor, candidates, episodes, alignment, last_search, history: (.history | .[-30:])}' <<<"$job"
    echo '```'
  } >"$run/context.md"
  { cat "$REPO/quickshell/.config/quickshell/video/job-fix.md"; echo; cat "$run/context.md"; } >"$run/prompt.md"
  MUSIC_CLAUDE_TIMEOUT=${VIDEO_CLAUDE_TIMEOUT:-30m} agent_claude_run video-agent "$run" "fix $id" "barch video show" "barch video search" "barch video add" "barch video use" "barch video retry" "barch video list"
  OUT=$(jq -c --arg id "$id" --arg run "$run" '{ok: true, id: $id, run: $run, summary: .structured_output.summary,
    fixed: .structured_output.proposed, session: .session_id, cost: .total_cost_usd}' "$run/result.json")
  show "$OUT" '.summary'
}

cmd_video() {
  local sub=${1:-status}
  (($#)) && shift
  need curl; need jq
  case $sub in
    browse) app_open video BARCH_VIDEO_PAGE "${1:-}"; return ;;
    status)
      video_api GET /api/status
      show "$OUT" '"video pipeline: " + ((.counts | to_entries | map(select(.value > 0) | "\(.value) \(.key)") | join(", ")) | if . == "" then "no movies yet" else . end) + (if .doing != "" then " · \(.doing)" else "" end) + (if ((.missing // []) | length) > 0 then "\nMISSING in the container: " + (.missing | join(", ")) + " (custom-cont-init.d not run?)" else "" end)' ;;
    list)
      video_api GET "/api/jobs${1:+?state=$1}"
      show "$OUT" '.jobs[] | "\(.id)\t\(.state)\t\(.title) (\(.year))  [\(.audio // [] | join(","))]\(if .donor != "" then "  ← \(.donor)\(if .progress then " \(.progress * 100 | floor) %" else "" end)" else "" end)\(if .reason != "" and .reason != null then "\n      " + .reason else "" end)"' ;;
    show)
      [[ -n ${1:-} ]] || usage_error "video show <id>"
      video_api GET "/api/jobs/$1"
      show "$OUT" '.job | "\(.id)  \(.state)  \(.title) (\(.year)), original \(.original)\n\(if .kind == "season" then "series" else "file" end): \(.file)\naudio: \(.audio // [] | join(", "))"
        + (if .episodes then "\nepisodes:\n" + (.episodes | to_entries | sort_by(.key | tonumber) | map("  E\(.key | tonumber | if . < 10 then "0\(.)" else "\(.)" end)  \(.value.state)\(if .value.offset_ms != null then "  \(.value.offset_ms) ms" else "" end)\(if (.value.reason // "") != "" then "  " + .value.reason else "" end)") | join("\n")) else "" end)
        + (if .reason then "\nreason: \(.reason)" else "" end)
        + (if .alignment then "\nalignment: \(if .alignment.ok then "offset \(.alignment.offset_ms) ms, speed \(.alignment.speed), \(.alignment.agreeing)/\(.alignment.windows) windows (\(.alignment.compared) vs original)" else .alignment.reason end)" else "" end)
        + (if (.candidates|length) > 0 then "\ncandidates:\n" + (.candidates | sort_by(-.score) | map("  [\(.status)] \(.score)  \(.title)  \(.size / 1073741824 * 10 | floor / 10) GB  \(.seeders) seeders  \(.indexer)\(if .reason != "" then "\n        " + .reason else "" end)\n        guid: \(.guid)") | join("\n")) else "" end)
        + (if .last_search then "\nlast search by hand (\(.last_search.query)): \(.last_search.found | length) candidate(s), \(.last_search.rejected | length) rejected:\n" + (.last_search.rejected[:15] | map("  - \(.title)  [\(.why)]  \(.size / 1073741824 * 10 | floor / 10) GB  \(.seeders) seeders\(if .url != "" then "\n      url: " + .url else "" end)") | join("\n")) else "" end)
        + "\nhistory:\n" + (.history[-12:] | map("  \(.t | strftime("%d/%m %H:%M"))  \(.msg)") | join("\n"))' ;;
    retry|skip|unskip)
      [[ -n ${1:-} ]] || usage_error "video $sub <id>"
      video_api POST "/api/jobs/$1" "$(jq -cn --arg a "$sub" '{action: $a}')"
      show "$OUT" '"\(.job.title): \(.job.state)"' ;;
    use)
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "video use <id> <guid>"
      video_api POST "/api/jobs/$1" "$(jq -cn --arg g "$2" '{action: "use", guid: $g}')"
      show "$OUT" '"\(.job.title): this candidate next"' ;;
    search)
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "video search <id> \"query\""
      video_api POST "/api/jobs/$1" "$(jq -cn --arg q "$2" '{action: "search", query: $q}')"
      show "$OUT" '.job.last_search | "\(.found | length) candidate(s) joined the job" + (if (.found | length) > 0 then ":\n" + (.found | map("  + " + .) | join("\n")) else "" end)
        + (if (.rejected | length) > 0 then "\n\(.rejected | length) rejected (barch video add <id> <url> takes one anyway):\n" + (.rejected[:20] | map("  - \(.title)  [\(.why)]  \(.size / 1073741824 * 10 | floor / 10) GB  \(.seeders) seeders\(if .url != "" then "\n      " + .url else "" end)") | join("\n")) else "" end)' ;;
    add)
      [[ -n ${1:-} && -n ${2:-} ]] || usage_error "video add <id> <magnet|torrent url> [\"title\"]"
      video_api POST "/api/jobs/$1" "$(jq -cn --arg u "$2" --arg t "${3:-}" '{action: "add", url: $u, title: $t}')"
      show "$OUT" '"\(.job.title): the release joined the job and is tried next (\(.job.state))"' ;;
    fix) video_fix_job "$@" ;;
    foreign)
      video_api GET /api/foreign
      show "$OUT" 'if (.files | length) == 0 then "no file has audio beyond the original and PT-BR" else
        "\(.files | length) file(s) with audio in another language:\n" + (.files | map("  \(.id)\t\(.title)  audio \(.audio | join(",")) (original \(.original))  extra: \(.extra | join(","))  trim: \(.trim)\(if .trim_error != "" then " (" + .trim_error + ")" else "" end)") | join("\n")) end' ;;
    scan)
      video_api POST /api/scan '{}'
      show "$OUT" '"video pipeline: running now"' ;;
    digest)
      video_api GET "/api/digest?days=${1:-7}"
      show "$OUT" '.text' ;;
    restart)
      video_api POST /api/restart '{}'
      show "$OUT" '"video pipeline: restarting"' ;;
    audit) exec python3 -I "$REPO/server/video/audit.py" "$@" ;;
    install) exec "$REPO/server/video/install.sh" ;;
    *) usage_error "video status|list [state]|show|retry|skip|unskip|use|search|add|fix|foreign|scan|digest|restart|audit|install" ;;
  esac
}
