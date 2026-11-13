# shellcheck shell=bash
# barch: music agents: Claude over an album's cover, a review job, a library album, or all of them (agent-sweep), each with the pipeline's commands as its only tools.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# music_covers_ask <Artist/Album> "what is wrong": a Claude run in a folder with the album's
# candidate images, the pipeline's notes and Bruno's complaint; it may adapt one (magick) or
# search the web, and proposes the result with `barch music covers propose` (never applies it)
music_covers_ask() {
  local folder=${1:-} complaint=${2:-}
  [[ -n $folder && -n $complaint ]] || usage_error "music covers ask <Artist/Album> \"what is wrong with the candidates\""
  need claude
  music_api GET /api/covers
  local entry
  entry=$(jq -c --arg f "$folder" '.entries[] | select(.folder == $f)' <<<"$OUT")
  [[ -n $entry ]] || die 1 "$folder was not checked yet: barch music covers check \"${folder%%/*}\""
  local conf="$HOME/.config/barch/music.json" url token run i n
  url=$(jq -r .url "$conf"); token=$(jq -r .token "$conf")
  run=$STATE/music-covers/$(date +%Y%m%d-%H%M%S)
  mkdir -p "$run"
  fetch() { curl -sSf --max-time 60 -G -H "X-Barch-Token: $token" --data-urlencode "folder=$folder" -d "which=$1" -o "$run/$2" "$url/api/covers/image" 2>/dev/null; }
  fetch current current.jpg || true
  n=$(jq '.alts // [] | length' <<<"$entry")
  for ((i = 0; i < n; i++)); do fetch "alt:$i" "alt$i.jpg" || true; done
  {
    echo "# Context"
    echo
    echo "- Album folder: \`$folder\` (use exactly this with barch music covers propose)"
    echo "- Artist: $(jq -r '.artist // ""' <<<"$entry") · album tag: $(jq -r '.album // ""' <<<"$entry")"
    jq -r 'if .mbid and .mbid != "" then "- MusicBrainz release: https://musicbrainz.org/release/\(.mbid)" else "- No MusicBrainz release id in the tags" end' <<<"$entry"
    echo "- Run folder (write here only): $run"
    echo
    echo "## Bruno's complaint"
    echo
    echo "$complaint"
    echo
    echo "## Images"
    echo
    echo "| file | what | size | notes |"
    echo "|---|---|---|---|"
    jq -r '"| current.jpg | the library'"'"'s cover.jpg now | \(.current.w // "?")x\(.current.h // "?") | \(if .current.framed then "scan frame detected" else "" end) |"' <<<"$entry"
    jq -r '.alts // [] | to_entries[] | "| alt\(.key).jpg | \(.value.source) | \(.value.orig) (as converted: \(.value.w)x\(.value.h)) | \([(if .value.framed then "scan frame (trimmed in this file)" else empty end), (if .value.same != null then "similarity to the scans \(.value.same * 100 | floor / 100)" else empty end), (if .value.trusted | not then "rejected: other artwork" else empty end), (if .value.best then "the pipeline'"'"'s pick" else empty end)] | join("; ")) |"' <<<"$entry"
    echo
    echo "## What the pipeline tried"
    echo
    jq -r '.tried // [] | map("- " + .) | join("\n")' <<<"$entry"
  } >"$run/context.md"
  { cat "$REPO/quickshell/.config/quickshell/music/cover-ask.md"; echo; cat "$run/context.md"; } >"$run/prompt.md"
  music_claude_run "$run" "cover $folder" "barch music covers propose"
  OUT=$(jq -c --arg f "$folder" --arg run "$run" '{ok: true, folder: $f, run: $run, summary: .structured_output.summary,
    proposed: .structured_output.proposed, session: .session_id, cost: .total_cost_usd}' "$run/result.json")
  show "$OUT" '.summary + (if .proposed then "\n(new proposal in Covers: barch music covers apply \"" + .folder + "\" to use it)" else "" end)'
}

# music fix <id> ["hint"]: the Fix with Agent button. Claude gets the whole job (problems, candidates,
# proposal, merge plan, what was tried), researches, decides with `barch music resolve` / `barch music
# cover`, waits for the run and goes on with the next problem until the album is in (job-fix.md).
music_fix_job() {
  local id=${1:-} hint=${2:-}
  [[ -n $id ]] || usage_error "music fix <id> [\"hint\"]"
  need claude
  music_api GET "/api/jobs/$id"
  local job run
  job=$(jq -c .job <<<"$OUT")
  run=$STATE/music-agent/job-$id-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$run"
  {
    echo "# Context"
    echo
    echo "- Job id: \`$id\` (use exactly this with barch music resolve / cover / show)"
    jq -r '"- Download: \(.name)\n- State: \(.state)\n- Source on the NAS: \(.source)\n- Audio: \(.audio.tracks // "?") tracks on \(.audio.discs // "?") disc(s), \((.audio.format // []) | join(", "))"' <<<"$job"
    jq -r '.source | if startswith("/data/") then "- The same folder on this machine (read only; its images can be looked at with Read): /mnt/nasfrutuozo/downloads/torrents/" + .[6:] else empty end' <<<"$job"
    echo "- Run folder (write here only): $run"
    if [[ -n $hint ]]; then echo; echo "## Bruno's hint"; echo; echo "$hint"; fi
    echo
    echo "## The job, as barch music show prints it"
    echo
    echo '```'
    "$0" music show "$id" 2>/dev/null || jq . <<<"$job"
    echo '```'
    echo
    echo "## The job as JSON (hints, track lengths, overrides, merge plan, cover sources tried)"
    echo
    echo '```json'
    jq '{id, state, kind, hints, audio, problems, notes, chosen, cover, cover_label, overrides, keep_order, replace, replace_tracks,
         match, candidates, proposal, merge, cover_tried, result, after, log: (.log | .[-40:])}' <<<"$job"
    echo '```'
  } >"$run/context.md"
  { cat "$REPO/quickshell/.config/quickshell/music/job-fix.md"; echo; cat "$run/context.md"; } >"$run/prompt.md"
  MUSIC_CLAUDE_TIMEOUT=40m music_claude_run "$run" "fix $id" "barch music show" "barch music resolve" "barch music cover"
  OUT=$(jq -c --arg id "$id" --arg run "$run" '{ok: true, id: $id, run: $run, summary: .structured_output.summary,
    fixed: .structured_output.proposed, session: .session_id, cost: .total_cost_usd}' "$run/result.json")
  show "$OUT" '.summary'
}

# music cover-ask <id> ["hint"]: an album stopped for its cover (or about to get a bad one): Claude
# searches the web for the real front, checks it and delivers it with `barch music cover`, which runs
# the album again. The music-cover rule of agent/rules.json calls this for every album that waits
# only for a cover; the Review tab has a button for it too.
music_cover_ask_job() {
  local id=${1:-} hint=${2:-}
  [[ -n $id ]] || usage_error "music cover-ask <id> [\"hint\"]"
  need claude
  music_api GET "/api/jobs/$id"
  local job run
  job=$(jq -c .job <<<"$OUT")
  run=$STATE/music-covers/job-$id-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$run"
  {
    echo "# Context"
    echo
    echo "- Job id: \`$id\` (use exactly this with barch music cover)"
    jq -r '"- Download: \(.name)\n- State: \(.state)\n- Artist folder: \(.proposal.artist_folder // .hints.artist // "?") · album tag: \(.proposal.album // .hints.album // "?") · date: \(.proposal.date // "?")"' <<<"$job"
    jq -r 'if .match.mbid then "- MusicBrainz release: https://musicbrainz.org/release/\(.match.mbid)  (\(.match.title) · \(.match.date) · \(.match.country))" else "- No MusicBrainz release matched yet" end' <<<"$job"
    echo "- Run folder (write here only): $run"
    echo
    echo "## Why it stopped"
    echo
    jq -r '.problems // [] | map("- " + .) | join("\n")' <<<"$job"
    if [[ -n $hint ]]; then echo; echo "## Bruno's hint"; echo; echo "$hint"; fi
    echo
    echo "## What the pipeline tried"
    echo
    jq -r '.cover_tried // [] | map("- " + .) | join("\n")' <<<"$job"
  } >"$run/context.md"
  { cat "$REPO/quickshell/.config/quickshell/music/job-cover-ask.md"; echo; cat "$run/context.md"; } >"$run/prompt.md"
  music_claude_run "$run" "cover job $id" "barch music cover"
  OUT=$(jq -c --arg id "$id" --arg run "$run" '{ok: true, id: $id, run: $run, summary: .structured_output.summary,
    proposed: .structured_output.proposed, session: .session_id, cost: .total_cost_usd}' "$run/result.json")
  show "$OUT" '.summary'
}

# music library fix "<Artist/Album>" ["hint"]: Claude ties one library album to MusicBrainz (library-fix.md):
# the entry (why, candidates, the files' lengths and titles) as context, compare/tag as tools.
music_library_fix() {
  local folder=${1:-} hint=${2:-}
  [[ -n $folder ]] || usage_error "music library fix \"<Artist/Album>\" [\"hint\"]"
  need claude
  music_api GET /api/library/sweep
  local entry run
  entry=$(jq -c --arg f "$folder" '.decide[] | select(.folder == $f)' <<<"$OUT")
  [[ -n $entry ]] || die 1 "$folder is not among the library albums waiting for a decision (barch music library)"
  run=$STATE/music-agent/library-$(tr -c 'A-Za-z0-9' '-' <<<"$folder" | cut -c1-60)-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$run"
  {
    echo "# Context"
    echo
    echo "- Album folder: \`$folder\` (use exactly this, quoted, with barch music library show / compare / tag)"
    jq -r '"- Artist folder: \(.folder | split("/")[0]) · album folder: \(.folder | split("/")[1])\n- Files: \(.tracks | length) on \(.tracks | map(.disc) | unique | length) disc(s), \((.tracks | map(.seconds) | add) / 60 | floor) min in all"' <<<"$entry"
    echo "- The files on this machine (read only; ffprobe reads their tags, Read looks at a cover): /mnt/nasfrutuozo/media/music/$folder/"
    echo "- Run folder (write here only): $run"
    if [[ -n $hint ]]; then echo; echo "## Bruno's hint"; echo; echo "$hint"; fi
    echo
    echo "## The entry, as barch music library show prints it"
    echo
    echo '```'
    "$0" music library show "$folder" 2>/dev/null || jq . <<<"$entry"
    echo '```'
    echo
    echo "## The entry as JSON"
    echo
    echo '```json'
    jq . <<<"$entry"
    echo '```'
  } >"$run/context.md"
  { cat "$REPO/quickshell/.config/quickshell/music/library-fix.md"; echo; cat "$run/context.md"; } >"$run/prompt.md"
  # show, compare, tag and reorder only: delete and skip are Bruno's decisions (library-fix.md says so too)
  MUSIC_CLAUDE_TIMEOUT=${MUSIC_CLAUDE_TIMEOUT:-25m} music_claude_run "$run" "library fix $folder" \
    "barch music library show" "barch music library compare" "barch music library tag" "barch music library reorder"
  OUT=$(jq -c --arg f "$folder" --arg run "$run" '{ok: true, folder: $f, run: $run, summary: .structured_output.summary,
    tagged: .structured_output.proposed, session: .session_id, cost: .total_cost_usd}' "$run/result.json")
  show "$OUT" '.summary'
}

# music agent-sweep [library|review|all] [--parallel N] [--limit N]: Claude over everything waiting for a
# decision, as a detached user unit (survives the terminal): `music library fix` on every Library tab
# album, `music fix` on every review job. One log of JSON lines per sweep in
# ~/.local/state/barch/music-agent/sweep-<stamp>/; stops by itself when the Claude plan's week passes 90 %
# (barch claude) or when `agent-sweep stop` touches its stop file. `status` reads the latest sweep.
music_agent_sweep() {
  local kind=all parallel=2 limit=0 sweeps=$STATE/music-agent dir
  case ${1:-} in
    status|stop)
      dir=$(ls -d "$sweeps"/sweep-* 2>/dev/null | sort | tail -1)
      [[ -n $dir ]] || die 1 "no sweep yet"
      if [[ $1 == stop ]]; then
        touch "$dir/stop"
        systemctl --user stop "barch-music-sweep-$(basename "$dir" | cut -d- -f2-)" 2>/dev/null || true
        echo "sweep stopped: $dir"; return
      fi
      local unit state
      unit="barch-music-sweep-$(basename "$dir" | cut -d- -f2-)"
      state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
      OUT=$(jq -sc --arg dir "$dir" --arg state "$state" --arg total "$(wc -l <"$dir/items" 2>/dev/null || echo 0)" '{dir: $dir, unit_state: $state, planned: ($total | tonumber), done: length,
        ok: map(select(.ok)) | length, tagged_or_fixed: map(select(.proposed)) | length, failed: map(select(.ok | not)) | length,
        cost: (map(.cost // 0) | add // 0), seconds: (map(.seconds // 0) | add // 0), last: (.[-3:] | map({item, proposed, summary: (.summary | .[0:160])}))}' "$dir/log.jsonl" 2>/dev/null || echo '{}')
      show "$OUT" '"\(.dir)\nunit \(.unit_state) · \(.done)/\(.planned) done · \(.tagged_or_fixed) tagged or delivered · \(.failed) failed · US$ \(.cost * 100 | round / 100) · \(.seconds / 60 | floor) min\n" + (.last | map("  \(if .proposed then "✓" else "·" end) \(.item): \(.summary)") | join("\n"))'
      return ;;
  esac
  while (($#)); do
    case $1 in
      library|review|all) kind=$1 ;;
      --parallel) parallel=${2:-2}; shift ;;
      --limit) limit=${2:-0}; shift ;;
      *) usage_error "music agent-sweep [library|review|all] [--parallel N] [--limit N] · status · stop" ;;
    esac
    shift
  done
  need claude; need systemd-run
  dir=$sweeps/sweep-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$dir"
  {
    if [[ $kind != review ]]; then
      music_api GET /api/library/sweep
      jq -r '.decide[] | "library\t" + .folder' <<<"$OUT"
    fi
    if [[ $kind != library ]]; then
      music_api GET "/api/jobs?state=review"
      jq -r '.jobs[] | select(.state == "review") | "review\t" + .id' <<<"$OUT"
    fi
  } | { if ((limit > 0)); then head -n "$limit"; else cat; fi; } >"$dir/items"
  local n; n=$(wc -l <"$dir/items")
  ((n > 0)) || die 1 "nothing waiting for a decision"
  systemd-run --user --quiet --collect --unit="barch-music-sweep-$(basename "$dir" | cut -d- -f2-)" \
    --property=WorkingDirectory="$HOME/BArch" -E HOME="$HOME" -E PATH="$PATH" -E MUSIC_CLAUDE_MODEL="${MUSIC_CLAUDE_MODEL:-sonnet}" \
    "$0" music agent-sweep-run "$dir" "$parallel"
  echo "sweep started: $n item(s) with $parallel at a time, log in $dir/log.jsonl (barch music agent-sweep status|stop)"
}

# the sweep's worker: items, N at a time, one JSON line each; stops at 90 % of the Claude week or on the stop file
music_agent_sweep_run() {
  local dir=$1 parallel=${2:-2}
  export SWEEP_DIR=$dir
  xargs -P "$parallel" -d '\n' -I{} "$0" music agent-sweep-item "$dir" "{}" <"$dir/items"
  local seen ok prop cost
  seen=$(wc -l <"$dir/log.jsonl" 2>/dev/null || echo 0)
  prop=$(jq -s 'map(select(.proposed)) | length' "$dir/log.jsonl" 2>/dev/null || echo 0)
  cost=$(jq -s 'map(.cost // 0) | add // 0 | . * 100 | round / 100' "$dir/log.jsonl" 2>/dev/null || echo 0)
  ok=$( [[ -e $dir/stop ]] && echo " (stopped early)" || true)
  "$0" notify "Music agent sweep" "$seen album(s) looked at$ok, $prop tagged or delivered, US\$ $cost · barch music agent-sweep status" --app "BArch music" \
    --action "Library=barch music browse library" --action "Review=barch music browse review" >/dev/null 2>&1 || true
}
music_agent_sweep_item() {
  local dir=$1 line=$2 kind item t0 rc=0 res pct
  kind=${line%%$'\t'*}; item=${line#*$'\t'}
  [[ -e $dir/stop ]] && return 0
  pct=$("$0" --json claude 2>/dev/null | jq -r '[.limits[] | select(.kind == "weekly_all" or .kind == "weekly_scoped") | .percent] | max // 0')
  if [[ -n $pct && $pct -ge 90 ]]; then
    touch "$dir/stop"
    jq -cn --arg item "$item" --arg kind "$kind" --argjson pct "$pct" '{kind: $kind, item: $item, ok: false, proposed: false, summary: "stopped: the Claude week is at \($pct) %", cost: 0, seconds: 0}' >>"$dir/log.jsonl"
    return 0
  fi
  t0=$(date +%s)
  if [[ $kind == library ]]; then
    res=$("$0" --json music library fix "$item" 2>"$dir/err-$(tr -c 'A-Za-z0-9' '-' <<<"$item" | cut -c1-60).log") || rc=$?
  else
    res=$("$0" --json music fix "$item" 2>"$dir/err-$item.log") || rc=$?
  fi
  if ((rc == 0)) && jq -e . >/dev/null 2>&1 <<<"$res"; then
    jq -c --arg kind "$kind" --arg item "$item" --argjson s "$(( $(date +%s) - t0 ))" '{kind: $kind, item: $item, ok: true, proposed: (.tagged // .fixed // false), summary, cost: (.cost // 0), seconds: $s, run}' <<<"$res" >>"$dir/log.jsonl"
  else
    jq -cn --arg kind "$kind" --arg item "$item" --argjson s "$(( $(date +%s) - t0 ))" --arg e "$(tail -c 300 "$dir/err-"*"$(tr -c 'A-Za-z0-9' '-' <<<"$item" | cut -c1-60)"*.log 2>/dev/null | tail -2 | tr '\n' ' ')" \
      '{kind: $kind, item: $item, ok: false, proposed: false, summary: ("failed: " + $e), cost: 0, seconds: $s}' >>"$dir/log.jsonl"
  fi
  return 0
}
