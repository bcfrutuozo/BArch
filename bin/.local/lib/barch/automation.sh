# shellcheck shell=bash
# barch: automation: barch-events (agent/events.py: rules, events, metrics), NAS, disks, firewalls, RGB, Drop.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

events_py() { need python3; python3 -I "$REPO/agent/events.py" "$@"; }

cmd_rules() {
  local sub=${1:-list} out rc=0
  (($#)) && shift
  case $sub in
    list)
      out=$(events_py rules) || rc=$?
      show "$out" '.rules[] | "\(if .enabled then "●" else "○" end) \(.id | . + " " * (18 - length))  \(.description)"
        + "\n     when: " + (.when | if .event then "event \(.event)" + ([to_entries[] | select(.key != "event") | " \(.key)~\(.value)"] | join(""))
                              else "metric \(.metric) " + (if .above != null then "> \(.above)" else "< \(.below)" end) end)
        + (if (.do | length) > 0 then "\n     do: " + (.do | join("; ")) else "" end)
        + (if .notify != "" then "\n     notify: \(.notify)" else "" end)
        + "\n     last: " + (if .last then (.last | strflocaltime("%Y-%m-%d %H:%M")) + (if .last_ok == false then " (failed)" else "" end) else "never" end)
        + "  ·  fired \(.fired_7d)× in 7 days  ·  cooldown \(.cooldown)"' ;;
    test)
      [[ -n ${1:-} ]] || usage_error "rules test <event> [key=value...] | rules test metric <name> <value>"
      out=$(events_py test "$@") || rc=$?
      show "$out" 'if .rules | length > 0 then "would fire: \(.rules | join(", "))" else "no rule matches" end' ;;
    fire)
      [[ -n ${1:-} ]] || usage_error "rules fire <id> [key=value...]"
      out=$(events_py fire "$@") || rc=$?
      show "$out" 'if .error then "error: \(.error)" else "\(.rule): " + (if .ok then "ok" else "failed: \(.failed | join("; "))" end) + (if (.ran | length) > 0 then "\n  " + (.ran | join("\n  ")) else "" end) end' ;;
    enable | disable)
      [[ -n ${1:-} ]] || usage_error "rules $sub <id>"
      out=$(events_py "$sub" "$1") || rc=$?
      show "$out" 'if .ok then "\(.id): \(if .enabled then "enabled" else "disabled" end)" else "error: \(.error)" end' ;;
    edit) ${EDITOR:-nvim} "$REPO/agent/rules.json" ;;
    *) usage_error "rules list|test|fire|enable|disable|edit" ;;
  esac
  return "$rc"
}

cmd_events() {
  local sub=${1:-status} out rc=0 unit=barch-events.service
  (($#)) && shift
  case $sub in
    status)
      out=$(events_py status) || rc=$?
      show "$out" '"events: service \(.service), \(.rules) rules (\(.enabled) enabled), \(.metrics) metrics, last sample "
        + (if .last_sample > 0 then (.last_sample | strflocaltime("%H:%M:%S")) else "never" end)
        + ", \(.events_24h) events in 24 h, db \(.db_bytes / 1048576 | floor) MB"' ;;
    log)
      out=$(events_py events "$@") || rc=$?
      show "$out" '.events[] | "\(.ts | strflocaltime("%m-%d %H:%M:%S"))  \(.event | . + " " * (18 - length))  "
        + (.data | to_entries | map(select(.value != "" and .value != null) | "\(.key)=\(.value | tostring | .[0:60])") | join("  "))' ;;
    on) systemctl --user start "$unit" || die 1 "could not start $unit"; cmd_events status ;;
    off) systemctl --user stop "$unit" || die 1 "could not stop $unit"; cmd_events status ;;
    reload) systemctl --user reload "$unit" || die 1 "could not reload $unit"; cmd_events status ;;
    journal) journalctl --user -u "$unit" -n "${1:-60}" --no-pager -o short ;;
    *) usage_error "events status|log|on|off|reload|journal" ;;
  esac
  return "$rc"
}

cmd_metrics() {
  local sub=${1:-list} out rc=0
  (($#)) && shift
  case $sub in
    list)
      out=$(events_py metrics) || rc=$?
      show "$out" '.metrics[] | "\(.metric | . + " " * (22 - length))  " + (if .value != null then (.value * 10 | round / 10 | tostring) else "-" end)' ;;
    series)
      [[ -n ${1:-} ]] || usage_error "metrics series <metric> [--since 24h] [--points N]"
      out=$(events_py series "$@") || rc=$?
      show "$out" '"\(.metric): \(.points | length) points since \(.since | strflocaltime("%Y-%m-%d %H:%M")), min \(.min) avg \(.avg) max \(.max) last \(.last)"' ;;
    summary)
      out=$(events_py summary) || rc=$?
      show "$out" '"boot: " + (if .boot.seconds then "\(.boot.seconds)s (\(.boot.kernel)), average \(.boot.avg_seconds)s over \(.boot.count_90d) boots" else "unknown" end)
        + "\nfailures: \(.failures.today) today, \(.failures.week) this week (\(.failures.last_week) last week), \(.failures.month) in 30 days (incidents; \(.failures.logs.month) logs)"
        + (if (.failures.units_week | length) > 0 then "\n  this week: " + (.failures.units_week | join(", ")) else "" end)
        + "\nclaude: US$ \(.claude.today) today, \(.claude.week) this week, \(.claude.month) in 30 days"
        + "\nvpn: " + (if .vpn.connected then "connected, \(.vpn.latency_ms) ms" else "off" end) + ", \(.vpn.drops_7d) drops in 7 days"
        + "\nnow: cpu \(.now["cpu.temp"]) °C \(.now["cpu.pct"] // 0 | floor)%, gpu \(.now["gpu.temp"]) °C \(.now["gpu.util"] // 0 | floor)%, ram \(.now["ram.pct"] // 0 | floor)%, disk \(.now["disk.root.pct"] // 0 | floor)%, ping \(.now["net.latency_ms"]) ms"
        + "\nrules fired: \(.rules.fired_24h) in 24 h, \(.rules.fired_7d) in 7 days"' ;;
    *) usage_error "metrics list|series|summary" ;;
  esac
  return "$rc"
}

# nas status|setup: agent/nas.py prints the snapshot itself (text, or JSON with --json)
cmd_nas() {
  local sub=${1:-status}
  (($#)) && shift
  need python3
  case $sub in
    status) if [[ $JSON == 1 ]]; then python3 -I "$REPO/agent/nas.py" status --json "$@" | jq .; return "${PIPESTATUS[0]}"
            else python3 -I "$REPO/agent/nas.py" status "$@"; fi ;;
    setup) python3 -I "$REPO/agent/nas.py" setup ;;
    *) usage_error "nas status [--no-certs]|setup" ;;
  esac
}

# disk status: agent/disk.py parses what barch-disk-health (root, hourly) dumped
cmd_disk() {
  local sub=${1:-status}
  (($#)) && shift
  need python3
  case $sub in
    status) if [[ $JSON == 1 ]]; then python3 -I "$REPO/agent/disk.py" status --json; else python3 -I "$REPO/agent/disk.py" status; fi ;;
    *) usage_error "disk status" ;;
  esac
}

# fw status|clients|blocked|setup: agent/pfsense.py prints the snapshot itself (text, or JSON with --json)
cmd_fw() {
  local sub=${1:-status}
  (($#)) && shift
  need python3
  case $sub in
    status | clients | blocked)
      if [[ $JSON == 1 ]]; then python3 -I "$REPO/agent/pfsense.py" "$sub" "$@" --json | jq .; return "${PIPESTATUS[0]}"
      else python3 -I "$REPO/agent/pfsense.py" "$sub" "$@"; fi ;;
    setup) python3 -I "$REPO/agent/pfsense.py" setup ;;
    *) usage_error "fw status|clients|blocked [site]|setup" ;;
  esac
}

# rgb: agent/rgb.py drives ckb-next-daemon's pipes (text, or JSON with --json)
cmd_rgb() {
  need python3
  if [[ $JSON == 1 ]]; then python3 -I "$REPO/agent/rgb.py" "$@" --json | jq .; return "${PIPESTATUS[0]}"
  else python3 -I "$REPO/agent/rgb.py" "$@"; fi
}

# drop: agent/drop.py, the iPhone receiver (text, or JSON with --json)
cmd_drop() {
  local sub=${1:-status}
  (($#)) && shift
  need python3
  case $sub in
    status)
      if [[ $JSON == 1 ]]; then python3 -I "$REPO/agent/drop.py" status --json | jq .; return "${PIPESTATUS[0]}"
      else python3 -I "$REPO/agent/drop.py" status; fi ;;
    setup | open) python3 -I "$REPO/agent/drop.py" "$sub" ;;
    *) usage_error "drop status|setup|open" ;;
  esac
}
