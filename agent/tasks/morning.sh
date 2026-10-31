#!/usr/bin/env bash
# morning: facts for the morning brief → $2/context.md
# Usage: morning.sh prepare <rundir>
[[ $1 == prepare ]] || exit 0
out=$2/context.md
qs_dir=$BARCH_REPO/quickshell/.config/quickshell
failures=$BARCH_STATE_ROOT/failures

section() { printf '\n## %s\n\n```\n' "$1"; shift; "$@" 2>&1; printf '```\n'; }
# the head of every failure log saved in the last N days: unit, result, the last journal lines
failure_heads() {
  local f
  find "$failures" -maxdepth 1 -name '*.log' -mtime "-$1" -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2- |
    while read -r f; do
      echo "### $(basename "$f")"
      sed -n '1,3p' "$f"
      grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$f" | tail -n 2 | cut -c1-220
      echo
    done
}

{
  echo "# Morning facts — $(date '+%A, %Y-%m-%d %H:%M')"
  section "Agenda today" khal list today 1d
  section "Agenda tomorrow" khal list tomorrow 1d
  section "Updates (updates-check.sh)" bash "$qs_dir/updates/updates-check.sh"
  section "System health" bash "$qs_dir/health/health-check.sh"
  section "Failed units now" sh -c 'systemctl --failed --no-legend; systemctl --user --failed --no-legend'
  section "Service failures reported in the last 24 h (head of each log; full logs in $failures)" failure_heads 1
  section "Errors in the journal since yesterday (count by unit)" sh -c \
    "journalctl -p err --since yesterday -o json --no-pager | jq -r '._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // \"?\"' | sort | uniq -c | sort -rn | head -20"
  section "Most repeated error messages since yesterday (hex ids as #, numbers as N)" sh -c \
    "journalctl -p err --since yesterday -o cat --no-pager | sed -E 's/[0-9a-f]{8,}/#/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -15"
  section "Agent reports in the last 24 h" sh -c \
    "find '$BARCH_STATE_ROOT/reports' -name '2*.json' -mtime -1 -exec jq -r '\"\(.time) \(.task): [\(.status)] \(.title)\"' {} + 2>/dev/null | sort"
  section "Crashes since yesterday (coredumpctl)" coredumpctl list --since yesterday --no-pager --no-legend
  section "Network shares (fstab cifs/nfs entries and what is mounted now)" sh -c \
    "grep -E '^[^#].*[[:space:]](cifs|nfs4?)[[:space:]]' /etc/fstab | awk '{print \$2, \$3}'; echo '--- mounted:'; findmnt -t cifs,nfs,nfs4 -o TARGET,SOURCE,FSTYPE --noheadings"
  section "Disk space" df -h / /home
} >"$out"
