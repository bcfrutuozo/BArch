# shellcheck shell=bash
# barch: helpers every module uses: errors, the bar's IPC, notifications, app windows, Claude runs and their cost.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

die() { echo "$PROG: $2" >&2; exit "$1"; }
usage_error() { echo "$PROG: $1" >&2; echo "Try '$PROG help'." >&2; exit 2; }
need() { command -v "$1" >/dev/null || die 3 "$1 not found"; }

need jq

# ipc_try <target> <function> [args...] → JSON answer in $OUT, error text in $ERR.
# Returns 0 ok, 1 refused by the bar, 3 bar not reachable. qs ipc call exits 0 even for
# "Target not found.", so the answer itself is checked.
OUT="" ERR=""
ipc_try() {
  local out
  OUT="" ERR=""
  command -v qs >/dev/null || { ERR="qs (quickshell) not found"; return 3; }
  out=$(qs ipc call "$@" 2>&1) || { ERR="the bar is not reachable: ${out:-qs ipc failed}"; return 3; }
  if ! jq -e 'type == "object" and has("ok")' >/dev/null 2>&1 <<<"$out"; then
    ERR="the bar is not reachable (qs ipc call $1 $2): ${out:-no answer}"
    return 3
  fi
  OUT=$out
  if [[ $(jq -r '.ok' <<<"$out") != true ]]; then
    ERR=$(jq -r '.error // "unknown error"' <<<"$out")
    return 1
  fi
}

# ipc: like ipc_try, but exits on failure. (A global $OUT instead of $(ipc ...), so that die
# exits the script and not a subshell.)
ipc() {
  local rc=0
  ipc_try "$@" || rc=$?
  ((rc == 0)) && return
  [[ $rc == 1 && $JSON == 1 ]] && jq . <<<"$OUT"
  die "$rc" "$ERR"
}

# show <json> <jq filter for the text output>
show() {
  if [[ $JSON == 1 ]]; then jq . <<<"$1"; else jq -r "$2" <<<"$1"; fi
}

# toggle <target> <function> on|off|status <text filter>: status, or set and show the new state
toggle() {
  local target=$1 fn=$2 arg=$3 text=$4 status=status
  [[ $target == notifs ]] && status=dndStatus
  case $arg in
    status) ipc "$target" "$status" ;;
    on) ipc "$target" "$fn" true ;;
    off) ipc "$target" "$fn" false ;;
    *) usage_error "expected on, off or status, got '$arg'" ;;
  esac
  show "$OUT" "$text"
}

# post <title> <body> <urgency> <app> [<actions: JSON array>]: notification for internal use.
# Never exits: without the bar it falls back to notify-send (no buttons there).
post() {
  ipc_try notifs post "$1" "$2" "$3" "$4" "$(actions_arg "${5:-}")" && return 0
  command -v notify-send >/dev/null && notify-send -u "$3" -a "$4" "$1" "$2" 2>/dev/null
  return 0
}

# the bar takes the buttons as {"actions": [...]}: qs ipc call strips the brackets of an
# argument that is a bare "[...]"
actions_arg() { [[ -z $1 || $1 == '[]' ]] || jq -c '{actions: .}' <<<"$1"; }

# action <label> <command words...> → {"text","cmd"} for a notification button
action() {
  local label=$1 cmd
  shift
  printf -v cmd '%q ' "$@"
  jq -nc --arg t "$label" --arg c "${cmd% }" '{text: $t, cmd: $c}'
}

# agent_claude_run <cost source> <run dir> <cost note> <barch command>...: Claude on $run/prompt.md (dontAsk,
# read-only but for the barch commands listed, e.g. "barch music cover"), the answer in $run/result.json;
# MUSIC_CLAUDE_TIMEOUT (20m) bounds it. Always Sonnet (MUSIC_CLAUDE_MODEL): a fix that chained three
# rounds cost US$ 1.48 on the default model (2026-11-03); these are lookups, not reasoning.
# music_claude_run is the same with the cost logged as music-agent; video_fix_job logs video-agent
music_claude_run() { agent_claude_run music-agent "$@"; }
agent_claude_run() {
  local source=$1 run=$2 note=$3 rc=0 c
  shift 3
  # read-only helpers too: a command chained with an unlisted tool (curl … | head) is refused whole
  local allowed=(Read Glob WebSearch WebFetch "Bash(curl *)" "Bash(magick *)" "Bash(identify *)" "Bash(ffprobe *)" "Bash(sleep *)"
                 "Bash(head *)" "Bash(tail *)" "Bash(ls *)" "Bash(cat *)" "Bash(wc *)" "Bash(grep *)" "Bash(jq *)" "Bash(file *)"
                 "Bash(sort *)" "Bash(cut *)" "Bash(tr *)" "Bash(echo *)" "Bash(mkdir *)")
  for c in "$@"; do allowed+=("Bash($c *)"); done
  local schema='{"type":"object","properties":{"summary":{"type":"string"},"proposed":{"type":"boolean"}},"required":["summary","proposed"]}'
  (cd "$run" && timeout "${MUSIC_CLAUDE_TIMEOUT:-20m}" claude -p --model "${MUSIC_CLAUDE_MODEL:-sonnet}" --output-format json --permission-mode dontAsk --strict-mcp-config \
    --add-dir "$run" --json-schema "$schema" --disallowedTools Edit Write NotebookEdit \
    --allowedTools "${allowed[@]}" \
    <"$run/prompt.md" >"$run/result.json" 2>"$run/claude.log") || rc=$?
  cost_log "$source" "$(jq -r '.total_cost_usd // empty' "$run/result.json" 2>/dev/null)" "$note"
  jq -e '.structured_output | type == "object"' "$run/result.json" >/dev/null 2>&1 ||
    die 1 "Claude did not finish (exit $rc): see $run/claude.log"
}

# app_open <quickshell dir> <ENV var for the page> [page]: one instance; a running one gets the
# request over its IPC, otherwise a new Quickshell starts on that page
app_open() {
  local cfg=$HOME/.config/quickshell/$1 var=$2 page=${3:-}
  if qs -p "$cfg" ipc show >/dev/null 2>&1; then
    qs -p "$cfg" ipc call app open "$page" >/dev/null
    return
  fi
  env "$var=$page" setsid -f qs -p "$cfg" >/dev/null 2>&1
}

# cost_log <source> <usd> [note]: one line per Claude call, read by barch-events (metrics summary)
cost_log() { [[ -n ${2:-} ]] && echo "$(date +%s) $1 $2 ${3:-}" >>"$STATE/claude-cost.log"; return 0; }
