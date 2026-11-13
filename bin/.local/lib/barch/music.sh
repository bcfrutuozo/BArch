# shellcheck shell=bash
# barch: music: the NAS pipeline's API (server/music), the Claude agents over albums and the library.
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

# music mb-add <id>: an edition MusicBrainz lacks. The job's download (artist, album, year, every track
# with its title and length) becomes a "release editor seed": a form that opens the MusicBrainz
# release editor in the browser already filled in; Bruno, logged in there, checks and submits (nothing
# is written from here). Then `barch music resolve <id> --release <the new mbid>`.
music_mb_add() {
  local id=${1:-}
  [[ -n $id ]] || usage_error "music mb-add <id>|\"<Artist/Album>\""
  local job out
  if [[ $id == */* ]]; then
    # an album of the library the sweep could not tie to MusicBrainz (the Library tab): its files' tracks
    music_api GET /api/library/sweep
    job=$(jq -c --arg f "$id" '.decide[] | select(.folder == $f) | {id: ($f | gsub("[^A-Za-z0-9]+"; "-")), name: $f, tracks,
      hints: {artist: ($f | split("/")[0]), album: ($f | split("/")[1] | sub(" \\((19|20)[0-9]{2}\\)$"; ""))}, proposal: {}}' <<<"$OUT")
    [[ -n $job ]] || die 1 "$id is not among the library albums waiting for a decision"
  else
    music_api GET "/api/jobs/$id"
    job=$(jq -c .job <<<"$OUT")
  fi
  [[ $(jq -r '.tracks | length' <<<"$job") -gt 0 ]] || die 1 "the job has no track list yet (run it once: barch music retry $id)"
  out=$STATE/music-agent/mb-seed-$id.html
  mkdir -p "$(dirname "$out")"
  jq -r '
    def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub("\""; "&quot;");
    def field(k; v): "<input type=\"hidden\" name=\"" + (k | esc) + "\" value=\"" + (v | esc) + "\">";
    (.proposal.album // .hints.album // .name) as $album |
    (.proposal.artist_folder // .hints.artist // "") as $artist |
    (.proposal.date // "") as $date |
    ((.hints.year // "") | tostring) as $year |
    "<!doctype html><meta charset=utf-8><title>MusicBrainz: add " + ($album | esc) + "</title>",
    "<body onload=\"document.forms[0].submit()\" style=\"font-family:sans-serif;padding:2em\">",
    "<p>Opening the MusicBrainz release editor with <b>" + ($artist | esc) + " – " + ($album | esc) + "</b> filled in. Log in if asked, check every field, then submit.</p>",
    "<form method=post action=\"https://musicbrainz.org/release/add\">",
    field("name"; $album),
    field("artist_credit.names.0.name"; $artist),
    field("artist_credit.names.0.artist.name"; $artist),
    field("status"; "official"),
    (if ($date | test("^\\d{4}-\\d{2}-\\d{2}$")) then
        field("events.0.date.year"; $date[0:4]), field("events.0.date.month"; $date[5:7]), field("events.0.date.day"; $date[8:10])
     elif ($year | test("^\\d{4}$")) then field("events.0.date.year"; $year) else empty end),
    ((.tracks | group_by(.disc)) | to_entries[] | .key as $m | .value as $ts |
        field("mediums.\($m).format"; "CD"),
        ($ts | sort_by(.index) | to_entries[] |
            field("mediums.\($m).track.\(.key).number"; (.value.index | tostring)),
            field("mediums.\($m).track.\(.key).name"; .value.title),
            field("mediums.\($m).track.\(.key).length"; ((.value.seconds * 1000) | floor | tostring)))),
    field("edit_note"; "Added from a download with the BArch music pipeline (track lengths from the files); job " + .id + " · " + (.name // "")),
    "<button>Open the release editor</button></form>"
  ' <<<"$job" >"$out"
  xdg-open "$out" >/dev/null 2>&1 &
  echo "release editor seed opened in the browser: $out"
  if [[ $id == */* ]]; then
    echo "after submitting, paste the new release in the Library tab and Tag (or: curl the API's /api/library/tag)"
  else
    echo "after submitting, take the new release id and run: barch music resolve $id --release <mbid>"
  fi
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

# music library ...: the albums of /music the sweep could not tie to MusicBrainz (server/music/library.py,
# the Music app's Library tab), from a shell and for the agent.
music_library() {
  local sub=${1:-list} folder=${2:-} release=${3:-}
  case $sub in
    list)
      music_api GET /api/library/sweep
      show "$OUT" '"sweep: " + (.counts | to_entries | map("\(.key) \(.value)") | join(", ")) + " · \(.albums) albums · \(.decide | length) to decide" +
        (if .paused then " · paused" else "" end) + "\n" + (.decide | map("\(.state | .[0:9] | . + (" " * (9 - length)))  \(.folder)\n      \(.why | .[0:150])" + (if (.candidates | length) > 0 then "  (\(.candidates | length) candidates)" else "" end)) | join("\n"))' ;;
    show)
      [[ -n $folder ]] || usage_error "music library show \"<Artist/Album>\""
      music_api GET /api/library/sweep
      OUT=$(jq -c --arg f "$folder" '.decide[] | select(.folder == $f)' <<<"$OUT")
      [[ -n $OUT ]] || die 1 "$folder is not among the library albums waiting for a decision (barch music library)"
      show "$OUT" '"\(.folder)  [\(.state)]\n\(.why)\n\ncandidates:\n" + ((.candidates // []) | map("  \(.mbid)  \(.artist) – \(.title)  \(.date) \(.country)  \(.tracks) tracks  score \(.score)" + (if .ok then "  fits" else "" end) + "\n      " + (.why | join("; "))) | join("\n")) +
        "\n\nfiles:\n" + ((.tracks // []) | map("  \(.disc).\(.index | tostring | if length < 2 then "0" + . else . end)  \((.seconds / 60 | floor) | tostring):\((.seconds % 60 | floor) | tostring | if length < 2 then "0" + . else . end)  \(.title)") | join("\n"))' ;;
    compare)
      [[ -n $folder && -n $release ]] || usage_error "music library compare \"<Artist/Album>\" <release mbid or URL>"
      music_api GET "/api/library/compare?folder=$(jq -rn --arg v "$folder" '$v | @uri')&release=$(jq -rn --arg v "$release" '$v | @uri')"
      show "$OUT" '"release \(.mbid): \(.artist // "") – \(.title // "") · \(.date // "") \(.country // "") · MusicBrainz discs \(.media | map(.tracks) | join(" + ")) vs files \(.ours | join(" + "))" +
        (if .split then " (the files follow the discs in one list)" else "" end) + " · worst \(.worst)s, mean \(.mean)s off" +
        (if (.reorder // [] | map(select(.moves)) | length) > 0 then "\n  the same songs in another order; barch music library reorder moves " + (.reorder | map(select(.moves)) | map("\(.disc).\(.index | tostring | if length < 2 then "0" + . else . end)→\(.to_disc).\(.to_pos | tostring | if length < 2 then "0" + . else . end) (\(.title))") | join(", ")) else "" end) + "\n" +
        ((.rows // []) | map("  \(.disc).\(.pos | tostring | if length < 2 then "0" + . else . end)  file \(.file)  \(.title)  \(.seconds)s  ↔  \(.mb_title)  \(.mb_seconds)s  Δ\(.diff)s" + (if (.diff // 0) > 10 then "  ✗" else "" end)) | join("\n"))' ;;
    tag|reorder)
      [[ -n $folder && -n $release ]] || usage_error "music library $sub \"<Artist/Album>\" <release mbid or URL>"
      music_api POST "/api/library/$sub" "$(jq -cn --arg f "$folder" --arg r "$release" '{folder: $f, release: $r}')"
      show "$OUT" '.result' ;;
    delete)
      [[ -n $folder ]] || usage_error "music library delete \"<Artist/Album>\" [<release mbid or URL>]"
      music_api POST /api/library/delete "$(jq -cn --arg f "$folder" --arg r "$release" '{folder: $f, release: $r}')"
      show "$OUT" '.result' ;;
    skip|retry)
      [[ -n $folder ]] || usage_error "music library $sub \"<Artist/Album>\""
      music_api POST "/api/library/$sub" "$(jq -cn --arg f "$folder" '{folder: $f}')"
      show "$OUT" '.result' ;;
    fix) music_library_fix "$folder" "${3:-}" ;;
    *) usage_error "music library [list|show|compare|tag|reorder|delete|skip|retry|fix] ..." ;;
  esac
}

# music artists: the artist folders of /music tied to Lidarr's MusicBrainz artists (server/music/barch_music/artists.py)
music_artists() {
  local sub=${1:-list} arg=${2:-} mbid=${3:-}
  case $sub in
    list|all)
      music_api GET /api/artists
      [[ $sub == all ]] || OUT=$(jq -c '.artists |= map(select(.state | IN("linked", "no-folder") | not))' <<<"$OUT")
      show "$OUT" '"artists: " + (.counts | to_entries | map("\(.key) \(.value)") | join(", ")) + "\n" +
        (.artists |
         map("\(.state | . + (" " * (9 - length)))  \(if .folder != "" then .folder else .lidarr.name end)" +
             (if .lidarr then "  [Lidarr \(.lidarr.id): \(.lidarr.name) \(.lidarr.mbid)]" else "" end) + "\n      \(.why)") | join("\n"))' ;;
    show|find)
      [[ -n $arg ]] || usage_error "music artists $sub \"<$([[ $sub == show ]] && echo folder || echo name)>\""
      music_api GET "/api/artists/candidates?$([[ $sub == show ]] && echo folder || echo q)=$(jq -rn --arg v "$arg" '$v | @uri')"
      show "$OUT" '"\(.query)" + (if .tied > 0 then " · \(.tied) tied album(s) looked at" else "" end) + "\n" +
        (.candidates | map("  \(.mbid)  \(.name)" + (if .disambiguation != "" then " (\(.disambiguation))" else "" end) +
          "  \([.type, .country, .years] | map(select(. != "")) | join(" · "))" +
          (if .releases > 0 then "  credited on \(.releases) of your albums" else "" end) +
          (if .lidarr then "  [Lidarr: \(.lidarr.path), \(.lidarr.files) files]" else "" end)) | join("\n"))' ;;
    link)
      [[ -n $arg && -n $mbid ]] || usage_error "music artists link \"<folder>\" <artist mbid or URL>"
      music_api POST /api/artists/link "$(jq -cn --arg f "$arg" --arg m "$mbid" '{folder: $f, mbid: $m}')"
      show "$OUT" '.result' ;;
    add)
      [[ -n $arg ]] || usage_error "music artists add <artist mbid or URL>"
      music_api POST /api/artists/add "$(jq -cn --arg m "$arg" '{mbid: $m}')"
      show "$OUT" '.result' ;;
    remove)
      [[ $arg =~ ^[0-9]+$ ]] || usage_error "music artists remove <lidarr artist id>"
      music_api POST /api/artists/remove "$(jq -cn --argjson i "$arg" '{id: $i}')"
      show "$OUT" '.result' ;;
    skip|unskip)
      [[ -n $arg ]] || usage_error "music artists $sub \"<folder>\""
      music_api POST "/api/artists/$sub" "$(jq -cn --arg f "$arg" '{folder: $f}')"
      show "$OUT" '.result' ;;
    move)
      [[ -n $arg && -n $mbid ]] || usage_error "music artists move \"<folder>\" \"<into folder>\" [--replace]"
      music_api POST /api/artists/move "$(jq -cn --arg f "$arg" --arg i "$mbid" --argjson r "$([[ ${4:-} == --replace ]] && echo true || echo false)" '{folder: $f, into: $i, replace: $r}')"
      show "$OUT" '.result' ;;
    *) usage_error "music artists [list|all|show|find|link|add|remove|move|skip|unskip] ..." ;;
  esac
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
