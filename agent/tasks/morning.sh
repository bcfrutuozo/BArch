#!/usr/bin/env bash
# morning: facts for the morning brief → $2/context.md
# Usage: morning.sh prepare <rundir>
[[ $1 == prepare ]] || exit 0
out=$2/context.md
qs_dir=$BARCH_REPO/quickshell/.config/quickshell

section() { printf '\n## %s\n\n```\n' "$1"; shift; "$@" 2>&1; printf '```\n'; }

{
  echo "# Morning facts — $(date '+%A, %Y-%m-%d %H:%M')"
  section "Agenda today" khal list today 1d
  section "Agenda tomorrow" khal list tomorrow 1d
  section "Updates (updates-check.sh)" bash "$qs_dir/updates/updates-check.sh"
  section "System health" bash "$qs_dir/health/health-check.sh"
  section "Failed units now" sh -c 'systemctl --failed --no-legend; systemctl --user --failed --no-legend'
  section "Service failures reported in the last 24 h" \
    find "$BARCH_STATE_ROOT/failures" -maxdepth 1 -name '*.log' -mtime -1 -printf '%TY-%Tm-%Td %TH:%TM  %f\n'
  section "Errors in the journal since yesterday (count by unit)" sh -c \
    "journalctl -p err --since yesterday -o json --no-pager | jq -r '._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // \"?\"' | sort | uniq -c | sort -rn | head -20"
  section "Agent reports in the last 24 h" sh -c \
    "find '$BARCH_STATE_ROOT/reports' -name '*.json' -mtime -1 -exec jq -r '\"\(.time) \(.task): [\(.status)] \(.title)\"' {} + 2>/dev/null | sort"
  section "Disk space" df -h / /home
} >"$out"
