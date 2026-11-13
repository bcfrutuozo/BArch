# shellcheck shell=bash
# barch: failure: the OnFailure handler of every service, its logs and the compositor-crash report.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# The compositor went away: Hyprland died in the last two minutes (start-hyprland, uwsm, restarts
# it inside the same unit, so the unit never fails: the trace is its "exit not-cleanly" line), or
# its Wayland socket is gone right now. The second covers a clean exit (logout, a restart after an
# update): the services that lose it fail in the same second, before "exit cleanly" is logged.
#
# The socket file outlives the exit (libwayland unlinks it in wl_display_destroy, ~0.6 s after
# the clients got their broken pipe on 2026-11-09), so the socket is connected to, not just looked
# at; with the variables already cleaned up by uwsm the session is over. When neither says so,
# wait up to 2 s for start-hyprland's own "exit cleanly" / "exit not-cleanly" line.
compositor_lost() {
  local i
  [[ -z ${WAYLAND_DISPLAY:-} || -z ${XDG_RUNTIME_DIR:-} ]] && return 0
  python3 -I - "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" 2>/dev/null <<'EOF' || return 0
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
s.connect(sys.argv[1])
EOF
  for ((i = 0; i < 5; i++)); do
    journalctl --user -u 'wayland-wm@*.service' --since -120s -o cat --no-pager 2>/dev/null |
      grep -qE 'exit (not-)?cleanly' && return 0
    ((i < 4)) && sleep 0.5
  done
  return 1
}

# how the compositor ended since <epoch>: "clean", "crash" or "" (nothing logged)
compositor_exit() {
  journalctl --user -u 'wayland-wm@*.service' --since "@$(($1 - 5))" -o cat --no-pager 2>/dev/null |
    grep -oE 'exit (not-)?cleanly' | tail -1 | sed 's/exit not-cleanly/crash/; s/exit cleanly/clean/'
}

# failure --cascade-report: the one notification for a compositor crash, with its casualties
# (collected by cmd_failure in failures/.cascade/). Writes failures/hyprland-<stamp>.log with the
# coredumps, the newest Hyprland crash report and the journal of the session unit, then waits
# for the bar (up to a minute: it is being relaunched by the new Hyprland) to post.
cascade_report() {
  local cdir=$STATE/failures/.cascade since units log stamp crash i
  [[ -s $cdir/units ]] || return 0
  since=$(<"$cdir/since")
  mapfile -t units < <(sort -u "$cdir/units" | sed 's/\.service$//')
  if [[ $(compositor_exit "$since") == clean ]]; then
    # a logout or a restart of the session, not a failure: the logs stay, already dismissed
    cat "$cdir/logs" >>"$STATE/failures/.dismissed" 2>/dev/null
    rm -rf "$cdir"
    return 0
  fi
  rm -rf "$cdir"
  stamp=$(date -d "@$since" +%Y%m%d-%H%M%S)
  log=$STATE/failures/hyprland-$stamp.log
  crash=$(find "$HOME/.cache/hyprland" -maxdepth 1 -name 'hyprlandCrashReport*.txt' -newermt "@$((since - 120))" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  {
    echo "Unit: Hyprland (wayland-wm@hyprland.desktop.service; start-hyprland restarted it in place)"
    echo "Crashed: $(date -d "@$since" '+%Y-%m-%d %H:%M:%S') (time of the first user service that lost it)"
    echo "Casualties (${#units[@]}): ${units[*]}"
    echo
    echo "=== coredumps from two minutes before the crash"
    coredumpctl list --since "@$((since - 120))" --no-pager 2>&1
    echo
    if [[ -n $crash ]]; then
      echo "=== $crash (first 60 lines)"
      head -n 60 "$crash"
    else
      echo "=== no Hyprland crash report in ~/.cache/hyprland (SIGKILL leaves none)"
    fi
    echo
    echo "=== journal of wayland-wm@* from two minutes before the crash"
    journalctl --user -u 'wayland-wm@*.service' --since "@$((since - 120))" -o short-iso --no-pager 2>&1 | head -n 400
  } >"$log"

  local title body acts
  title="Hyprland crashed at $(date -d "@$since" +%H:%M)"
  body="${#units[@]} user service$( ((${#units[@]} > 1)) && echo s) restarted with it: ${units[*]}"
  acts=$(jq -sc . <(action "Investigate" "$BARCH" agent investigate "$log") \
                  <(action "Show log" foot -T "Hyprland" -e less +G "$log"))
  for ((i = 0; i < 12; i++)); do
    ipc_try notifs post "$title" "$body" critical "System" "$(actions_arg "$acts")" && return 0
    sleep 5
  done
  post "$title" "$body" critical "System" "$acts"
}

# failure list|dismiss|delete [<unit>|all]: the saved logs. A dismissed log stays on disk (the
# morning and weekly tasks still read it) but is out of what asks for attention: the Center's
# badges and the Inbox count the logs of the last day that are not in failures/.dismissed (one
# log file name per line). systemd always passes a full unit name (foo.service), so the three
# words cannot be taken for a unit.
failure_list() {   # [<unit>|all] → [{name, unit, time, size, path, dismissed}], newest first
  local dir=$STATE/failures
  find "$dir" -maxdepth 1 -name '*.log' -printf '%T@\t%s\t%f\n' 2>/dev/null | sort -rn |
    jq -Rn --rawfile seen <(cat "$dir/.dismissed" 2>/dev/null) --arg dir "$dir" --arg unit "${1:-all}" '
      ($seen | split("\n")) as $s
      | [inputs | split("\t")
         | {name: .[2], unit: (.[2] | sub("-[0-9]{8}-[0-9]{6}\\.log$"; "")), time: (.[0] | tonumber | floor),
            size: (.[1] | tonumber), path: ($dir + "/" + .[2])}
         | select($unit == "all" or .unit == $unit or .unit == $unit + ".service")
         | .dismissed = (.name | IN($s[]))]'
}

failure_manage() {
  local sub=$1 what=${2:-all} dir=$STATE/failures logs n f
  (($# <= 2)) || usage_error "failure $sub [<unit>|all]"
  logs=$(failure_list "$what")
  case $sub in
    list)
      show "$logs" 'if length == 0 then "no failure logs" else
        .[] | "\(.time | strflocaltime("%Y-%m-%d %H:%M"))  \(.unit)\(if .dismissed then "  (dismissed)" else "" end)" end'
      return ;;
    dismiss)
      n=$(jq '[.[] | select(.dismissed | not)] | length' <<<"$logs")
      jq -r '.[].name' <<<"$logs" >>"$dir/.dismissed" 2>/dev/null ;;
    delete)
      n=$(jq length <<<"$logs")
      while read -r f; do [[ -n $f ]] && rm -f -- "$dir/$f"; done < <(jq -r '.[].name' <<<"$logs") ;;
  esac
  # the names of logs that are gone (deleted, or beyond the 50 kept) leave the list
  if [[ -e $dir/.dismissed ]]; then
    sort -u "$dir/.dismissed" | while read -r f; do [[ -n $f && -e $dir/$f ]] && echo "$f"; done >"$dir/.dismissed.new"
    mv "$dir/.dismissed.new" "$dir/.dismissed"
  fi
  show "$(jq -nc --arg sub "$sub" --arg what "$what" --argjson n "$n" '{ok: true, action: $sub, what: $what, count: $n}')" \
    '"\(.count) failure log(s) \(if .action == "delete" then "deleted" else "dismissed" end)"'
}

# failure <unit> [--system]: OnFailure handler (user: barch-failure@.service; system:
# barch-failure-relay). systemd passes MONITOR_* about the failed run. Saves status and journal
# to ~/.local/state/barch/failures/ (every failure) and notifies with Investigate / Show log. At
# most one notification per unit every 30 min: failures inside that window are counted in the
# mark file (.last/<scope>-<unit>, whose mtime is the last notification) and the next notification
# says how many there were. agent/failure-ignore lists units to skip.
#
# When the compositor goes away, the user services that only lost it (portals, cliphist,
# hyprsunset...) fail together within a second: each log is still saved, but instead of one
# notification per service they are collected in .cascade/ and `failure --cascade-report`,
# scheduled 30 s after the first one (the bar is back by then), decides: Hyprland exited cleanly
# (logout, a restart after an update) → no notification, the logs go straight to .dismissed;
# otherwise one notification for the crash with the list.
cmd_failure() {
  case ${1:-} in list|dismiss|delete) failure_manage "$@"; return ;; esac
  local unit="" scope=--user glob
  while (($#)); do
    case $1 in
      --system) scope=--system ;;
      --cascade-report) cascade_report; return ;;
      -*) usage_error "failure: unknown option '$1'" ;;
      *) unit=$1 ;;
    esac
    shift
  done
  [[ -n $unit ]] || usage_error "failure <unit> [--system]"
  [[ $unit == *.* ]] || unit+=.service

  if [[ -r $REPO/agent/failure-ignore ]]; then
    while read -r glob; do
      [[ -z $glob || $glob == \#* ]] && continue
      # shellcheck disable=SC2053  # glob match on purpose
      [[ $unit == $glob ]] && return 0
    done <"$REPO/agent/failure-ignore"
  fi

  local dir=$STATE/failures stamp log mark quiet=0 count=0 cascade=0
  [[ $scope == --user ]] && compositor_lost && cascade=1
  mkdir -p "$dir/.last"
  mark=$dir/.last/${scope#--}-$unit
  if [[ -e $mark ]]; then
    count=$(<"$mark")
    [[ $count =~ ^[0-9]+$ ]] || count=0
    [[ -n $(find "$mark" -mmin -30 2>/dev/null) ]] && quiet=1
  fi

  stamp=$(date +%Y%m%d-%H%M%S)
  log=$dir/${unit}-$stamp.log
  local result=${MONITOR_SERVICE_RESULT:-failed} code=${MONITOR_EXIT_CODE:-} status=${MONITOR_EXIT_STATUS:-}
  local inv=${MONITOR_INVOCATION_ID:-} jscope=() lines
  [[ $scope == --user ]] && jscope=(--user)
  {
    echo "Unit: $unit (${scope#--} service)"
    echo "Failed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Result: $result${code:+, $code}${status:+ $status}"
    echo "Invocation: ${inv:-unknown}"
    echo
    echo "=== systemctl ${scope#--} status"
    systemctl "$scope" status "$unit" --no-pager -l -n 0 2>&1
    echo
    echo "=== journal of the failed run"
    if [[ -n $inv ]] && lines=$(journalctl "${jscope[@]}" "_SYSTEMD_INVOCATION_ID=$inv" -o short-iso --no-pager 2>&1) && [[ -n $lines && $lines != "-- No entries --" ]]; then
      echo "$lines"
    elif [[ $scope == --user ]]; then
      journalctl --user -u "$unit" -b -n 300 -o short-iso --no-pager 2>&1
    else
      journalctl -u "$unit" -b -n 300 -o short-iso --no-pager 2>&1
    fi
  } >"$log"
  # keep the last 50 logs
  find "$dir" -maxdepth 1 -name '*.log' -printf '%T@ %p\n' | sort -rn | tail -n +51 | cut -d' ' -f2- | xargs -r rm -f

  # the NVIDIA driver was updated and the old kernel module is still loaded: anything that opens
  # NVML (nvidia-cdi-refresh, triggered by the new modules.dep, five times in a row) fails until
  # the reboot, which fixes it. Logged, already dismissed, no notification.
  if grep -q 'Driver/library version mismatch' "$log"; then
    echo "${log##*/}" >>"$dir/.dismissed"
    echo "$log"
    return 0
  fi

  if ((cascade)); then
    # a casualty of the compositor: no notification of its own, the unit's mark stays untouched
    mkdir -p "$dir/.cascade"
    [[ -e $dir/.cascade/since ]] || date +%s >"$dir/.cascade/since"
    echo "$unit" >>"$dir/.cascade/units"
    echo "${log##*/}" >>"$dir/.cascade/logs"
    # one report for the whole burst; fails quietly when the first casualty already scheduled it
    systemd-run --user --quiet --collect --unit=barch-cascade --on-active=30 \
      "$BARCH" failure --cascade-report 2>/dev/null || true
    echo "$log"
    return 0
  fi

  if ((quiet)); then
    # inside the window: count it, keeping the mark's mtime (time of the last notification)
    echo $((count + 1)) >"$mark.new" && touch -r "$mark" "$mark.new" && mv "$mark.new" "$mark"
    echo "$log"
    return 0
  fi

  local last body acts title="$unit failed"
  ((count > 0)) && title+=" ($((count + 1))× since $(date -r "$mark" +%H:%M))"
  echo 0 >"$mark"
  last=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$log" | tail -1 | cut -d' ' -f3- | cut -c1-160)
  body="$result${status:+ ($code $status)}${last:+ — $last}"
  acts=$(jq -sc . <(action "Investigate" "$BARCH" agent investigate "$log") \
                  <(action "Show log" foot -T "$unit" -e less +G "$log"))
  post "$title" "$body" critical "System" "$acts"
  echo "$log"
}
