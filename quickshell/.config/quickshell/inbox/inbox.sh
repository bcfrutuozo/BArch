#!/usr/bin/env bash
# inbox.sh — what waits for a decision of Bruno's, across everything the desktop runs, as one JSON for
# InboxWidget.qml (`barch inbox` shows the same): the music pipeline's review queue (and how many of those
# wait only on a year-only date, settled by one button), the library albums it could not tie to
# MusicBrainz, the video pipeline's review jobs, the book requests pending a pick, the failure logs of
# the last day, the health check's issues and every agent task whose last report was not "ok".
# Each item carries the command that opens the right place. Every source is optional: one that is not
# reachable (the NAS asleep) is left out, with its error in `errors`, never blocking the rest.
set -uo pipefail
barch=$HOME/.local/bin/barch
state=${XDG_STATE_HOME:-$HOME/.local/state}/barch
items=() errors=()
item() {   # item <id> <label> <count> <text> <cmd...>
  local id=$1 label=$2 count=$3 text=$4; shift 4
  ((count > 0)) || return 0
  items+=("$(jq -nc --arg id "$id" --arg label "$label" --argjson count "$count" --arg text "$text" \
                --args '{id: $id, label: $label, count: $count, text: $text, cmd: $ARGS.positional}' -- "$@")")
}
api() {   # api <name> <barch args...>: the JSON, or "" with the error noted
  local name=$1; shift
  local out
  if out=$(timeout 20 "$barch" --json "$@" 2>&1) && jq -e . >/dev/null 2>&1 <<<"$out"; then echo "$out"
  else errors+=("$name: $(tail -n1 <<<"$out" | cut -c1-120)"); echo ""; fi
}

# music: the review queue, the ones waiting only on the year, the library albums to decide
m=$(api music music list review)
if [[ -n $m ]]; then
  n=$(jq '[.jobs[] | select(.state == "review")] | length' <<<"$m")
  y=$(jq '[.jobs[] | select(.state == "review" and (.problems | length) == 1 and (.problems[0] | test("^no full original release date")))] | length' <<<"$m")
  t="album(s) in the review queue"; ((y > 0)) && t+=", $y waiting only on a year-only date (one button settles them)"
  item music "Music review" "$n" "$t" "$barch" music browse review
fi
lib=$(timeout 20 curl -sS --max-time 15 -H "X-Barch-Token: $(jq -r .token "$HOME/.config/barch/music.json" 2>/dev/null)" \
        "$(jq -r .url "$HOME/.config/barch/music.json" 2>/dev/null)/api/library/sweep" 2>/dev/null)
if jq -e '.decide' >/dev/null 2>&1 <<<"$lib"; then
  item library "Music library" "$(jq '.decide | length' <<<"$lib")" "album(s) the MusicBrainz sweep could not settle" "$barch" music browse library
fi

# video: the dub jobs in review
v=$(api video video list review)
[[ -n $v ]] && item video "Video dub" "$(jq '[.jobs[] | select(.state == "review")] | length' <<<"$v")" \
  "movie(s) or season(s) with no dubbed release that fits" "$barch" video browse dub

# books: requests pending a pick
b=$(api books books requests)
[[ -n $b ]] && item books "Book requests" "$(jq '[.requests[] | select(.status == "pending")] | length' <<<"$b")" \
  "request(s) the automatic download found no strict match for" "$barch" books browse requests

# failures in the last day (barch failure logs)
f=$(find "$state/failures" -maxdepth 1 -name '*.log' -mmin -1440 2>/dev/null | wc -l)
item failures "Failures" "$f" "service failure log(s) in the last 24 h" "$barch" center failures

# health: the bar's own check (pacnew, failed units, TPM, backup, disks)
h=$(api health health)
[[ -n $h ]] && item health "System health" "$(jq '.issues // 0' <<<"$h")" "issue(s): .pacnew, failed units, TPM, backup, disks" "$barch" center overview

# agent tasks whose last report was not ok
a=0; names=()
for r in "$state"/reports/*/latest.json; do
  [[ -r $r ]] || continue
  st=$(jq -r '.status // "ok"' "$r")
  [[ $st == ok ]] && continue
  a=$((a + 1)); names+=("$(jq -r '.task' "$r") ($st)")
done
item agent "Agent reports" "$a" "task(s) whose last report asks for attention: ${names[*]-}" "$barch" center agent

jq -nc --argjson at "$(date +%s%3N)" \
  --argjson items "$(printf '%s\n' "${items[@]-}" | jq -sc 'map(select(. != null))')" \
  --argjson errors "$(printf '%s\n' "${errors[@]-}" | jq -R . | jq -sc 'map(select(length > 0))')" \
  '{at: $at, total: ($items | map(.count) | add // 0), items: $items, errors: $errors}'
