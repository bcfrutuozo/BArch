# shellcheck shell=bash
# barch: music library: the albums of /music not tied to MusicBrainz (Library tab), the artist folders against Lidarr (Artists tab), MusicBrainz release-editor seeds.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

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
