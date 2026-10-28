#!/usr/bin/env bash
# weekly-review: facts for the weekly review → $2/context.md
# Usage: weekly-review.sh prepare <rundir>
[[ $1 == prepare ]] || exit 0
out=$2/context.md
qs_dir=$BARCH_REPO/quickshell/.config/quickshell

section() { printf '\n## %s\n\n```\n' "$1"; shift; "$@" 2>&1; printf '```\n'; }
# errors of the week grouped by unit: count and the latest message
errors() {
  journalctl "$@" -p err --since -7d -o json --no-pager |
    jq -rs 'group_by(._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "?") | map({u: (.[0]._SYSTEMD_UNIT // .[0].SYSLOG_IDENTIFIER // "?"), n: length, last: (.[-1].MESSAGE | tostring | .[0:200])})
            | sort_by(-.n) | .[0:25][] | "\(.n)\t\(.u)\t\(.last)"'
}

{
  echo "# Weekly facts — $(date '+%Y-%m-%d %H:%M')"
  section "System journal errors, last 7 days (count, unit, latest message)" errors
  section "User journal errors, last 7 days" errors --user
  section "Service failures reported this week" \
    find "$BARCH_STATE_ROOT/failures" -maxdepth 1 -name '*.log' -mtime -7 -printf '%TY-%Tm-%Td %TH:%TM  %f\n'
  section "Failed units now" sh -c 'systemctl --failed --no-legend; systemctl --user --failed --no-legend'
  section "Agent safety snapshots (date type number session)" sh -c 'tail -n 40 /var/log/barch-agent-snapshots.log 2>/dev/null || echo "none yet"'
  section "System health" bash "$qs_dir/health/health-check.sh"
  section "Disk space" df -h / /home
  section "BArch repo: unsaved changes" git -C "$BARCH_REPO" status --short
  section "BArch repo: last save" git -C "$BARCH_REPO" log -1 --format='%cr — %s'
  section "BArch repo: modification time of the unsaved files" sh -c \
    "git -C '$BARCH_REPO' status --porcelain | cut -c4- | while read -r f; do stat -c '%y  %n' '$BARCH_REPO/'\"\$f\" 2>/dev/null; done"
} >"$out"
