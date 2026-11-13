# shellcheck shell=bash
# barch: snapshot: the safety snapshot pairs of the Claude sessions in ~/BArch.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

SNAP_RUN=/run/barch-agent-snapshot
SNAP_LOG=/var/log/barch-agent-snapshots.log

# Claude Code hook (SessionStart and SessionEnd, see claude/.claude/settings.json). Only sessions
# whose folder is ~/BArch (or inside it); never the scheduled tasks (read-only, BARCH_AGENT_TASK).
# SessionStart's output goes into Claude's context, so the agent knows the snapshot numbers.
# Always exits 0: a failed snapshot must not block the session, it is reported instead.
snapshot_hook() {
  local input event sid cwd source out num
  input=$(cat)
  [[ -n ${BARCH_AGENT_TASK:-} ]] && return 0
  event=$(jq -r '.hook_event_name // ""' <<<"$input")
  sid=$(jq -r '.session_id // ""' <<<"$input")
  cwd=$(jq -r '.cwd // ""' <<<"$input")
  source=$(jq -r '.source // ""' <<<"$input")
  cwd=$(readlink -f "$cwd" 2>/dev/null) || return 0
  [[ $cwd == "$REPO" || $cwd == "$REPO"/* ]] || return 0
  [[ $sid =~ $UUID_RE ]] || return 0

  case $event in
    SessionStart)
      [[ $source == startup || $source == resume ]] || return 0
      if out=$(systemctl start --no-ask-password "barch-agent-snapshot@pre-$sid.service" 2>&1); then
        num=$(cat "$SNAP_RUN/$sid.pre" 2>/dev/null)
        echo "Safety net: snapper snapshot #${num:-?} (pre) of / was taken before this session; a post"
        echo "snapshot is taken when it ends. What the session changed outside the repo:"
        echo "\`sudo snapper -c root status ${num:-N}..<post>\`; undo: \`sudo snapper -c root undochange ${num:-N}..<post>\`"
        echo "(\`barch snapshot list\` shows the post number). /home is not in the snapshot; the repo is covered by git."
      else
        echo "WARNING: the safety snapshot before this session failed: ${out:-unknown error}"
        echo "Tell Bruno before changing anything outside the repo (/etc, /boot, /usr/local, packages)."
      fi
      ;;
    SessionEnd)
      # no-block: SessionEnd hooks get little time; the snapshot finishes on its own
      [[ -r $SNAP_RUN/$sid.pre ]] &&
        systemctl start --no-block --no-ask-password "barch-agent-snapshot@post-$sid.service" >/dev/null 2>&1
      ;;
  esac
  return 0
}

snapshot_list() {
  local data
  [[ -r $SNAP_LOG ]] || { [[ $JSON == 1 ]] && echo '[]' || echo "No safety snapshots yet."; return 0; }
  # log lines: <iso time> <pre|post> <number> <session>
  data=$(jq -Rn '[inputs | split(" ") | {time: .[0], type: .[1], number: (.[2] | tonumber), session: .[3]}]
                 | group_by(.session) | map({session: .[0].session, time: (map(select(.type == "pre")) | last | .time // .[0].time),
                   pre: (map(select(.type == "pre")) | last | .number), post: (map(select(.type == "post")) | last | .number)})
                 | sort_by(.time)' "$SNAP_LOG")
  show "$data" '
    if length == 0 then "No safety snapshots yet." else
      (.[] | "\(.time[0:16] | sub("T"; " "))  #\(.pre // "?")..\(.post // "(open)")  session \(.session[0:8])"),
      "",
      "What a session changed:  sudo snapper -c root status <pre>..<post>",
      "Undo it:                 sudo snapper -c root undochange <pre>..<post>"
    end'
}

cmd_snapshot() {
  case ${1:-} in
    hook) snapshot_hook ;;
    list) snapshot_list ;;
    *) usage_error "snapshot list|hook" ;;
  esac
}
