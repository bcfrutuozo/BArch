# shellcheck shell=bash
# barch: agent: the scheduled read-only tasks (agent/tasks) and the AUR review.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# frontmatter field of a task file: task_field <file> <key>
task_field() { awk -v k="$2" 'NR == 1 && $0 == "---" {f = 1; next} f && $0 == "---" {exit}
                              f && index($0, k ":") == 1 {sub(/^[^:]*:[ \t]*/, ""); print; exit}' "$1"; }
task_body() { awk 'NR == 1 && $0 == "---" {f = 1; next} f == 1 && $0 == "---" {f = 2; next} f != 1' "$1"; }

# split "Read Bash(git log *) WebFetch(domain:x)" into words, keeping the parentheses whole
split_tools() {
  local s=$1 re='^[[:space:]]*([^[:space:](]+(\([^)]*\))?)'
  TOOLS=()
  while [[ $s =~ $re ]]; do
    TOOLS+=("${BASH_REMATCH[1]}")
    s=${s:${#BASH_REMATCH[0]}}
  done
}

default_schema='{"type":"object","properties":{
  "status":{"type":"string","enum":["ok","warn","alert"]},
  "title":{"type":"string"},"summary":{"type":"string"},"report":{"type":"string"}},
  "required":["status","title","summary","report"]}'

agent_footer() {
  cat <<EOF

---

## How this run works

You are running unattended and read-only, started by a timer: there is nobody to answer
questions. Tools outside the allowed list are denied; do not try to work around a denial, mention
it in the report instead. The facts for this run are in $1 (start with context.md); those files
and the files of this repository are the sources to use.

Write in Brazilian Portuguese (code, paths and commands stay as they are). Fill:
- \`status\`: \`ok\` (nothing needs attention), \`warn\` (worth a look soon), \`alert\` (needs action now);
- \`title\`: one line for the notification title, under 70 characters;
- \`summary\`: one or two sentences for the notification body;
- \`report\`: the full report in Markdown, starting with the conclusion.

Today is $(date '+%A, %Y-%m-%d %H:%M %Z').
EOF
}

# agent_fail <task> <message> <log>: notify and exit 1
agent_fail() {
  post "Agent task $1 failed" "$2" normal "Agent" "[$(action "Show log" foot -T "$1" -e less "$3")]"
  die 1 "$1: $2 (log: $3)"
}

agent_run() {
  local task="" quiet=0
  while (($#)); do
    case $1 in
      --quiet) quiet=1 ;;
      -*) usage_error "agent run: unknown option '$1'" ;;
      *) task=$1 ;;
    esac
    shift
  done
  local file=$REPO/agent/tasks/$task.md helper=$REPO/agent/tasks/$task.sh
  [[ -n $task && -r $file ]] || usage_error "agent run <task> (tasks: $(agent_names | paste -sd' '))"
  need claude

  local tstate=$STATE/agent/$task stamp rundir rc=0
  mkdir -p "$tstate/runs" "$STATE/reports/$task"
  exec 9>"$tstate/lock"
  flock -n 9 || die 1 "$task is already running"
  stamp=$(date +%Y%m%d-%H%M%S)
  rundir=$tstate/runs/$stamp
  mkdir -p "$rundir"
  export BARCH_REPO=$REPO BARCH_STATE=$tstate BARCH_STATE_ROOT=$STATE

  # prepare: the task's script collects the facts (exit 75 = nothing to do this time)
  if [[ -f $helper ]]; then
    bash "$helper" prepare "$rundir" >"$rundir/prepare.log" 2>&1 || rc=$?
    if ((rc == 75)); then
      rm -rf "$rundir"
      if [[ $JSON == 1 ]]; then jq -n --arg t "$task" '{ok: true, task: $t, skipped: true}'
      else echo "$task: nothing to do"; fi
      return 0
    fi
    ((rc == 0)) || agent_fail "$task" "preparing the facts failed" "$rundir/prepare.log"
  fi

  local schema=$default_schema model
  [[ -r $REPO/agent/tasks/$task.schema.json ]] && schema=$(jq -c . "$REPO/agent/tasks/$task.schema.json")
  model=$(task_field "$file" model)
  split_tools "$(task_field "$file" tools)"
  { task_body "$file"; agent_footer "$rundir"; } >"$rundir/prompt.md"

  local -a args=(-p --output-format json --permission-mode dontAsk --strict-mcp-config
    --add-dir "$rundir" --json-schema "$schema")
  [[ -n $model ]] && args+=(--model "$model")
  args+=(--disallowedTools Edit Write NotebookEdit --allowedTools "${TOOLS[@]}")
  (cd "$REPO" && BARCH_AGENT_TASK=$task timeout 35m claude "${args[@]}" \
    <"$rundir/prompt.md" >"$rundir/result.json" 2>"$rundir/claude.log") || rc=$?
  if ! jq -e '.subtype == "success" and (.is_error | not) and (.structured_output | type == "object")' \
      "$rundir/result.json" >/dev/null 2>&1; then
    { echo "exit code: $rc"; cat "$rundir/claude.log"; jq -r '.result // empty' "$rundir/result.json" 2>/dev/null; } >>"$rundir/error.log"
    agent_fail "$task" "Claude did not finish the task (exit $rc)" "$rundir/error.log"
  fi

  local out=$STATE/reports/$task report meta
  report=$out/$stamp.md
  meta=$out/$stamp.json
  jq -r --arg task "$task" --arg when "$(date '+%Y-%m-%d %H:%M')" '
    .structured_output as $o
    | "# \($o.title)\n\n_\($task) · \($when) · \($o.status)_\n\n\($o.report)\n\n---\n\nSession `\(.session_id)`: `barch agent continue \(.session_id)`\n"' \
    "$rundir/result.json" >"$report"
  jq --arg task "$task" --arg time "$(date -Is)" --arg report "$report" '
    {ok: true, task: $task, time: $time, status: .structured_output.status, title: .structured_output.title,
     summary: .structured_output.summary, session: .session_id, cost: .total_cost_usd, report: $report}' \
    "$rundir/result.json" >"$meta"
  ln -sfn "$stamp.md" "$out/latest.md"
  ln -sfn "$stamp.json" "$out/latest.json"
  cost_log "$task" "$(jq -r '.total_cost_usd // empty' "$rundir/result.json")" "$(jq -r '.structured_output.title // empty' "$rundir/result.json")"

  [[ -f $helper ]] && { bash "$helper" finish "$rundir" "$rundir/result.json" "$report" >>"$rundir/prepare.log" 2>&1 ||
    echo "$PROG: $task: finish step failed (see $rundir/prepare.log)" >&2; }

  # keep the last 10 runs (facts) and 60 reports
  find "$tstate/runs" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +11 | xargs -r rm -rf
  find "$out" -maxdepth 1 -name '2*' | sort -r | tail -n +121 | xargs -r rm -f

  local status notify urgency
  status=$(jq -r .status "$meta")
  notify=$(task_field "$file" notify)
  if ((quiet == 0)) && [[ $notify != never && ($notify != issues || $status != ok) ]]; then
    case $status in alert) urgency=critical ;; warn) urgency=normal ;; *) urgency=low ;; esac
    post "$(jq -r .title "$meta")" "$(jq -r .summary "$meta")" "$urgency" "Agent" \
      "$(jq -sc . <(action "Open report" foot -T "$task" -e nvim -R "$report") \
                  <(action "Continue" "$BARCH" agent continue "$(jq -r .session "$meta")"))"
  fi
  show "$(cat "$meta")" '"[\(.status)] \(.title)\n\(.summary)\nreport: \(.report)"'
}

agent_names() { find "$REPO/agent/tasks" -maxdepth 1 -name '*.md' -printf '%f\n' | sed 's/\.md$//' | sort; }

agent_list() {
  local t file last next enabled rows=()
  while read -r t; do
    file=$REPO/agent/tasks/$t.md
    last=$(cat "$STATE/reports/$t/latest.json" 2>/dev/null || echo null)
    enabled=$(systemctl --user is-enabled "barch-agent@$t.timer" 2>/dev/null)
    next=$(systemctl --user show "barch-agent@$t.timer" -p NextElapseUSecRealtime --value 2>/dev/null)
    rows+=("$(jq -nc --arg t "$t" --arg d "$(task_field "$file" description)" --argjson last "$last" \
      --arg en "${enabled:-not installed}" --arg next "$next" \
      '{task: $t, description: $d, timer: $en, next: $next, last: $last}')")
  done < <(agent_names)
  show "$(printf '%s\n' "${rows[@]}" | jq -s .)" '.[] |
    "\(.task) — \(.description)\n  timer: \(.timer)\(if .next != "" then ", next \(.next)" else "" end)\n  last: "
    + (if .last == null then "never" else "\(.last.time[0:16] | sub("T"; " ")) [\(.last.status)\(if .last.dismissed then ", dismissed" else "" end)] \(.last.title)" end)'
}

# agent dismiss [<task>|all]: the latest report of a task that asked for attention (warn, alert)
# stops counting in the Center's badge and in the Inbox: "dismissed" (the time) goes into its
# meta JSON, so every reader sees it; the report stays, and the next run starts clean.
agent_dismiss() {
  local what=${1:-all} f t n=0
  (($# <= 1)) || usage_error "agent dismiss [<task>|all]"
  [[ $what == all || -e $STATE/reports/$what/latest.json ]] || die 1 "no report for '$what'"
  for f in "$STATE"/reports/*/latest.json; do
    [[ -r $f ]] || continue
    t=${f%/latest.json}; t=${t##*/}
    [[ $what == all || $what == "$t" ]] || continue
    jq -e '.status != "ok" and (.dismissed | not)' "$f" >/dev/null 2>&1 || continue
    f=$(readlink -f "$f")
    jq --arg at "$(date -Is)" '.dismissed = $at' "$f" >"$f.tmp" && mv "$f.tmp" "$f" && n=$((n + 1))
  done
  show "$(jq -nc --arg what "$what" --argjson n "$n" '{ok: true, what: $what, count: $n}')" '"\(.count) report(s) dismissed"'
}

agent_continue() {
  [[ ${1:-} =~ $UUID_RE ]] || usage_error "agent continue <session id>"
  need foot
  setsid -f foot -D "$REPO" -T "Claude" claude --resume "$1" >/dev/null 2>&1
}

agent_ask() {
  local args=() text=()
  while (($#)); do
    case $1 in
      --continue) args+=(--continue) ;;
      *) text+=("$1") ;;
    esac
    shift
  done
  need foot
  need claude
  ((${#text[@]})) && args+=("${text[*]}")
  setsid -f foot -D "$REPO" -T "Claude" claude "${args[@]}" >/dev/null 2>&1
}

agent_investigate() {
  local log=${1:-} unit
  [[ -r $log ]] || usage_error "agent investigate <failure log>"
  need foot
  need claude
  unit=$(sed -n 's/^Unit: //p' "$log" | head -1)
  setsid -f foot -D "$REPO" -T "Investigate: $unit" claude \
    "The service $unit failed. Its status and the journal of the failed run are in $log. Read it, find the cause (check more of the journal, the unit and its config as needed) and explain it to me. Propose the fix and wait for my go-ahead before changing anything." \
    >/dev/null 2>&1
}

cmd_agent() {
  local sub=${1:-}
  (($#)) && shift
  case $sub in
    list) agent_list ;;
    run) agent_run "$@" ;;
    report)
      [[ -n ${1:-} && -r $STATE/reports/$1/latest.md ]] || die 1 "no report for '${1:-}'"
      cat "$STATE/reports/$1/latest.md" ;;
    dismiss) agent_dismiss "$@" ;;
    continue) agent_continue "$@" ;;
    ask) agent_ask "$@" ;;
    investigate) agent_investigate "$@" ;;
    *) usage_error "agent list|run|report|dismiss|continue|ask|investigate" ;;
  esac
}

# aur review: runs the aur-review task for changes not reviewed yet, then prints the verdict of
# every pending AUR update. Exit 0 all ok (or nothing pending), 4 something to look at or not
# reviewed, 1 the review could not run. run-update.sh asks before paru -Syu when it is not 0.
cmd_aur() {
  [[ ${1:-} == review ]] || usage_error "aur review"
  local rc=0 data
  export BARCH_REPO=$REPO BARCH_STATE=$STATE/agent/aur-review BARCH_STATE_ROOT=$STATE
  mkdir -p "$BARCH_STATE"
  [[ $JSON == 1 ]] || echo "Checking the pending AUR updates (new changes are reviewed by Claude, ~1–2 min)…" >&2
  (JSON=0 agent_run aur-review --quiet >&2) || rc=$?
  data=$(bash "$REPO/agent/tasks/aur-review.sh" status) || die 1 "could not list the pending AUR updates"
  show "$data" '
    def tag: {"ok": "ok   ", "warn": "WARN ", "alert": "ALERT"}[.] // "?    ";
    if length == 0 then "No pending AUR updates." else
      (.[] | "\(.verdict.status // "none" | tag)  \(.name) \(.old) → \(.new)"
             + (if .verdict then "\n         \(.verdict.summary)" else "\n         not reviewed" end)
             + (if (.verdict.flags // []) | length > 0 then "\n         flags: \(.verdict.flags | join("; "))" else "" end)),
      (if any(.[]; .verdict.report) then "\nReport: \([.[] | .verdict.report // empty] | unique | join(" "))" else empty end)
    end'
  ((rc == 0)) || return 1
  jq -e 'all(.[]; .verdict.status == "ok")' >/dev/null <<<"$data" || return 4
}
