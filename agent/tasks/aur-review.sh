#!/usr/bin/env bash
# aur-review: PKGBUILD diffs of the pending AUR updates (paru -Qua), one per package base.
# Usage: aur-review.sh prepare <rundir>                    diffs + context.md for the bases not
#                                                          reviewed yet (exit 75 = nothing new)
#        aur-review.sh finish <rundir> <result.json> <report.md>   stores the verdicts
#        aur-review.sh status                              pending updates with their verdicts (JSON)
# Verdicts are cached per package base and AUR commit in $BARCH_STATE/verdicts.json, so each
# change is reviewed once. Git copies: paru's (~/.cache/paru/clone) or ~/.cache/barch/aur.
# Fetching only updates the remote refs; paru's own checkout is left alone.

cache=$BARCH_STATE/verdicts.json
paru_clones=$HOME/.cache/paru/clone
mirror=$HOME/.cache/barch/aur
[[ -s $cache ]] || echo '{}' >"$cache"

# version (epoch:pkgver-pkgrel) of a .SRCINFO on stdin
srcinfo_version() {
  awk -F' = ' '/^\tepoch/ {e=$2} /^\tpkgver/ {v=$2} /^\tpkgrel/ {r=$2}
               END {printf "%s%s-%s", (e ? e ":" : ""), v, r}'
}
source_hosts() { grep -E '^\s*source(_[a-z0-9_]+)? = ' | grep -oE '[a-z+]+://[^/]+' | sed 's/^[a-z]*+//' | sort -u; }

# pending AUR updates as JSON [{name, base, old, new, dir, target}] (fetch: 1 = git fetch first)
pending() {
  local fetch=$1 lines names info
  # AUR_REVIEW_PENDING="name old new" lines replace paru -Qua (for testing)
  lines=${AUR_REVIEW_PENDING:-$(timeout 90 paru -Qua 2>/dev/null | awk '$3 == "->" {print $1, $2, $4}')}
  [[ -n $lines ]] || { echo '[]'; return; }
  names=$(awk '{printf "&arg[]=%s", $1}' <<<"$lines")
  info=$(curl -fsS --max-time 30 "https://aur.archlinux.org/rpc/v5/info?${names#&}") || info='{"results":[]}'
  while read -r name old new; do
    local base dir target
    base=$(jq -r --arg n "$name" '.results[] | select(.Name == $n) | .PackageBase' <<<"$info")
    [[ -n $base ]] || base=$name
    if [[ -d $paru_clones/$base/.git ]]; then dir=$paru_clones/$base
    else
      dir=$mirror/$base
      [[ -d $dir/.git ]] || { mkdir -p "$mirror"; git clone -q "https://aur.archlinux.org/$base.git" "$dir" 2>/dev/null; fetch=0; }
    fi
    [[ $fetch == 1 ]] && git -C "$dir" fetch -q origin 2>/dev/null
    target=$(git -C "$dir" rev-parse -q --verify origin/master 2>/dev/null) || target=""
    jq -nc --arg name "$name" --arg base "$base" --arg old "$old" --arg new "$new" --arg dir "$dir" --arg target "$target" \
      '{name: $name, base: $base, old: $old, new: $new, dir: $dir, target: $target}'
  done <<<"$lines" | jq -s .
}

# commit of the AUR repo whose .SRCINFO has the installed version
baseline() {
  local dir=$1 want=$2 c
  while read -r c; do
    [[ $(git -C "$dir" show "$c:.SRCINFO" 2>/dev/null | srcinfo_version) == "$want" ]] && { echo "$c"; return; }
  done < <(git -C "$dir" log --format=%H origin/master -- .SRCINFO 2>/dev/null)
  # VCS packages (-git) have versions no commit carries: fall back to what paru built last
  [[ $dir == "$paru_clones"/* ]] && git -C "$dir" rev-parse -q --verify HEAD
}

# heuristic flags for one diff (or full listing) on stdin → one flag per line
flags_of() {
  local added
  added=$(grep -E '^\+' | grep -vE '^\+\+\+ ')
  local -A pat=(
    ["download piped to a shell"]='(curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh'
    ["base64 decoding"]='base64[[:space:]]+(-d|--decode)'
    ["eval"]='(^|[^a-z_])eval[[:space:]]'
    ["raw TCP (/dev/tcp)"]='/dev/tcp/'
    ["setuid / setgid bit"]='chmod[[:space:]]+([ugoa]*\+[rwx]*s|[0-7]?[4-7][0-7]{3})'
    ["sudo"]='(^|[^a-z_])sudo[[:space:]]'
    ["ssh keys / credentials"]='\.ssh/|authorized_keys|\.gnupg|\.netrc|id_rsa|id_ed25519'
    ["cron"]='crontab|/etc/cron'
    ["plain http source"]='http://'
    ["netcat"]='(^|[^a-z_])(nc|ncat|netcat)[[:space:]]+-'
    ["raw IP address"]='https?://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
    ["paste / shortener host"]='pastebin|paste\.ee|hastebin|bit\.ly|tinyurl|transfer\.sh|0x0\.st'
    ["checksum SKIP"]="'SKIP'|\"SKIP\"|[[:space:]]SKIP[[:space:]]*\)"
  )
  local name
  for name in "${!pat[@]}"; do
    grep -qiE -- "${pat[$name]}" <<<"$added" && echo "$name: $(grep -iE -- "${pat[$name]}" <<<"$added" | head -1 | cut -c2-140)"
  done
}

prepare() {
  local rundir=$1 list todo n=0
  list=$(pending 1)
  # one review per package base and AUR commit not in the cache yet
  todo=$(jq -c --slurpfile cache "$cache" '
    [group_by(.base)[] | {base: .[0].base, dir: .[0].dir, target: .[0].target,
      names: map(.name), old: .[0].old, new: .[0].new}
     | select(.target != "" and ($cache[0][.base + "@" + .target] | not))]' <<<"$list")
  [[ $(jq length <<<"$todo") -gt 0 ]] || return 75

  local entries=() e base dir target old new base_c diff flags authors hosts_old hosts_new
  while read -r e; do
    base=$(jq -r .base <<<"$e"); dir=$(jq -r .dir <<<"$e"); target=$(jq -r .target <<<"$e")
    old=$(jq -r .old <<<"$e"); new=$(jq -r .new <<<"$e")
    diff=$rundir/$base.diff
    base_c=$(baseline "$dir" "$old")
    [[ $base_c == "$target" ]] && base_c=""     # an empty diff would hide the change
    if [[ -n $base_c ]]; then
      { git -C "$dir" log --format='commit %h %an <%ae> %cs: %s' "$base_c..$target"
        echo; git -C "$dir" diff --stat "$base_c" "$target" -- . ':(exclude).SRCINFO'
        echo; git -C "$dir" diff "$base_c" "$target" -- . ':(exclude).SRCINFO'; } >"$diff"
      flags=$(git -C "$dir" diff "$base_c" "$target" -- . ':(exclude).SRCINFO' | flags_of)
      hosts_old=$(git -C "$dir" show "$base_c:.SRCINFO" 2>/dev/null | source_hosts | paste -sd' ')
      hosts_new=$(git -C "$dir" show "$target:.SRCINFO" 2>/dev/null | source_hosts | paste -sd' ')
      [[ $hosts_old != "$hosts_new" ]] && flags+=$'\n'"source hosts changed: ${hosts_old:-none} → ${hosts_new:-none}"
      git -C "$dir" diff --name-status "$base_c" "$target" | grep -qE '^[AM]\s+.*\.install$' &&
        flags+=$'\n'"install script added or changed"
      # committers of the new commits that never committed before the baseline
      authors=$(comm -23 <(git -C "$dir" log --format=%ae "$base_c..$target" | sort -u) \
                         <(git -C "$dir" log --format=%ae "$base_c" | sort -u) | paste -sd' ')
      [[ -n $authors ]] && flags+=$'\n'"new committer: $authors"
    else
      { echo "(no baseline: the installed version $old is not in the AUR history; full files at $target)"
        git -C "$dir" log -5 --format='commit %h %an <%ae> %cs: %s' "$target"
        git -C "$dir" ls-tree -r --name-only "$target" | grep -v '^.SRCINFO$' | while read -r f; do
          printf '\n=== %s\n' "$f"; git -C "$dir" show "$target:$f" | sed 's/^/+/'; done; } >"$diff"
      flags=$(flags_of <"$diff")
      flags+=$'\n'"no baseline: full review of the current files"
    fi
    flags=$(grep -v '^$' <<<"$flags" | jq -Rsc 'split("\n") | map(select(length > 0))')
    entries+=("$(jq -c --arg diff "$diff" --argjson flags "$flags" --arg baseline "${base_c:-}" \
      '. + {key: (.base + "@" + .target), diff: $diff, flags: $flags, baseline: $baseline} | del(.dir)' <<<"$e")")
    n=$((n + 1))
  done < <(jq -c '.[]' <<<"$todo")

  printf '%s\n' "${entries[@]}" | jq -s . >"$rundir/pending.json"
  {
    echo "# Pending AUR updates to review — $(date '+%Y-%m-%d %H:%M')"
    echo
    jq -r '.[] | "## \(.base) (\(.names | join(", "))): \(.old) → \(.new)\n\n- Diff: \(.diff)\n- AUR commit: \(.target)\n- Baseline commit: \(if .baseline == "" then "none" else .baseline end)\n- Heuristic flags: \(if (.flags | length) == 0 then "none" else "\n" + (.flags | map("  - " + .) | join("\n")) end)\n"' "$rundir/pending.json"
  } >"$rundir/context.md"
  echo "$n package base(s) to review"
}

finish() {
  local rundir=$1 result=$2 report=$3 tmp
  tmp=$(mktemp)
  jq --slurpfile p "$rundir/pending.json" --slurpfile r "$result" --arg report "$report" --arg t "$(date -Is)" '
    . as $c
    | reduce $p[0][] as $e ($c;
        ($r[0].structured_output.packages // [] | map(select(.base == $e.base)) | first) as $v
        | .[$e.key] = {base: $e.base, names: $e.names, old: $e.old, new: $e.new,
                       status: ($v.status // "warn"), summary: ($v.summary // "not covered by the review"),
                       flags: $e.flags, time: $t, report: $report})' "$cache" >"$tmp" && mv "$tmp" "$cache"
}

# pending updates (no fetch) joined with their verdicts
status() {
  pending 0 | jq --slurpfile cache "$cache" '
    map(. + {verdict: ($cache[0][.base + "@" + .target] // null)} | del(.dir))'
}

case ${1:-} in
  prepare) prepare "$2" ;;
  finish) finish "$2" "$3" "$4" ;;
  status) status ;;
  *) echo "usage: $0 prepare <rundir> | finish <rundir> <result.json> <report.md> | status" >&2; exit 2 ;;
esac
