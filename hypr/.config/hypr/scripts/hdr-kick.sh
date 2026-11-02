#!/usr/bin/env bash
# Kicks the AW back into HDR after DPMS or a resume: 120 Hz, then its own config again.
# The mode comes from BArch.monitors (monitors.lua) plus the bar's overrides (HDR, SDR
# brightness), so the kick never undoes what the Control Center set.
#
# If nvidia-drm has refused a modeset since the screen came back ("Failed to apply atomic
# modeset" after a bad resume), it stops: more modesets on a GPU in that state hung the
# whole machine (2026-10-28).
#
# After the kick it checks the refresh rate the monitor really got. After a resume the
# driver can silently refuse every mode above 60 Hz (the atomic test commit fails with
# EINVAL, the 10-bit swapchain cannot be allocated) and Hyprland falls back to 60 Hz
# without the kernel logging anything, so the old check saw nothing (2026-10-29). What
# brings the link back is a fresh negotiation: disable the output and enable it again
# with its config. If even that leaves it low, it says so in a notification.
#
# hypridle calls it twice for one resume (after_sleep_cmd and the on-resume of the dpms
# listener). The second call reconnected the output again right after the first had
# given up, the AW vanished from `hyprctl monitors` and the empty rate read as success
# (2026-11-02). So the runs are serialized, a call within 30 s of the last one's start is
# dropped, and a monitor missing after the reconnect counts as a failure.
MON="HDMI-A-2"
METHOD="${1:-modeset}"   # modeset | dpms

RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
exec 9>"$RUNDIR/barch-hdr-kick.lock"
flock 9
STAMP="$RUNDIR/barch-hdr-kick.last"
now=$(date +%s)
if [ -f "$STAMP" ] && [ $((now - $(cat "$STAMP" 2>/dev/null || echo 0))) -lt 30 ]; then
  logger -t hdr-kick "another kick ran less than 30 s ago; skipping"
  exit 0
fi
echo "$now" >"$STAMP"
SINCE=$(date -d '-15 seconds' '+%Y-%m-%d %H:%M:%S')

drm_failed() {
  journalctl -k -q --no-pager -o cat --since "$SINCE" 2>/dev/null |
    grep -q 'Failed to apply atomic modeset'
}

# HDMI 2.1 link training failed when the AW woke up: the driver fell back to TMDS (60 Hz at
# 4K) and only a fresh link (reconnect) brings FRL back; the 120 Hz kick cannot (2026-11-02,
# every dpms wake of the day)
frl_failed() {
  journalctl -k -q --no-pager -o cat --since "$SINCE" 2>/dev/null |
    grep -q 'HDMI FRL link training failed'
}

give_up() {
  logger -t hdr-kick "nvidia-drm refused a modeset on $MON ($1); skipping the HDR kick"
  barch notify "Display" "The GPU refused a modeset after the screen came back; HDR kick skipped." \
    --critical --app "hdr-kick" >/dev/null 2>&1
  exit 1
}

aw() {  # $1 = mode to apply over the monitor's config; empty = the config itself
  if [ -n "$1" ]; then
    hyprctl eval "local t = {}
      for k, v in pairs(BArch.monitors['$MON']) do t[k] = v end
      for k, v in pairs(BArch.monitor_overrides['$MON'] or {}) do t[k] = v end
      t.mode = '$1'
      hl.monitor(t)"
  else
    hyprctl eval "BArch.apply_monitor('$MON')"
  fi
}

# refresh rate the monitor is really running at, rounded (240.00000 -> 240)
refresh_now() {
  hyprctl -j monitors 2>/dev/null | jq -r --arg m "$MON" '.[] | select(.name == $m) | .refreshRate | round'
}

# refresh rate the config asks for ("3840x2160@240" -> 240). `hyprctl eval` prints nothing
# but errors, so the value comes back inside one; empty if the mode has no rate.
refresh_wanted() {
  hyprctl eval "error('WANT=' .. tostring(BArch.monitors['$MON'].mode))" 2>&1 |
    grep -o 'WANT=[^ ]*' | grep -o '@[0-9]*' | tr -d @
}

# a fresh link: off, then on again with the full config (apply_monitor sets disabled = false)
reconnect() {
  logger -t hdr-kick "$MON came back at $(refresh_now) Hz instead of $1; reconnecting the output"
  hyprctl eval "hl.monitor({ output = '$MON', disabled = true })" >/dev/null
  sleep 1.5
  aw "" >/dev/null
  wait_rate "$1"
}

# poll until the AW runs at $1 Hz (up to $2 half-seconds, 16 = 8 s); returns as soon as it does
wait_rate() {
  local r
  for _ in $(seq "${2:-16}"); do
    sleep 0.5
    r=$(refresh_now)
    [ -n "$r" ] && [ "$r" -ge "$1" ] && return 0
  done
  return 1
}

# espera o AW voltar (até ~10s)
for _ in $(seq 20); do
  hyprctl monitors | grep -A25 "Monitor $MON" | grep -q "dpmsStatus: 1" && break
  sleep 0.5
done
sleep 2
drm_failed && give_up "before the kick"
want=$(refresh_wanted)

if frl_failed && [ -n "$want" ]; then
  # straight to the reconnect: the kick below would only be one more modeset on a dead link
  logger -t hdr-kick "HDMI FRL link training failed on wake; reconnecting $MON right away"
  reconnect "$want"
elif [ "$METHOD" = "dpms" ]; then
  hyprctl dispatch "hl.dsp.dpms({ action = \"disable\", monitor = \"$MON\" })"
  sleep 3
  hyprctl dispatch "hl.dsp.dpms({ action = \"enable\", monitor = \"$MON\" })"
else
  aw "3840x2160@120"
  sleep 2
  drm_failed && give_up "at 120 Hz"
  aw ""
fi

[ -n "$want" ] || exit 0
wait_rate "$want" 4
got=$(refresh_now)
if [ -n "$got" ] && [ "$got" -lt "$want" ]; then
  drm_failed && give_up "before reconnecting"
  reconnect "$want"
  got=$(refresh_now)
  if [ -z "$got" ]; then   # the output did not come back after the reconnect: once more
    logger -t hdr-kick "$MON missing after reconnecting; enabling it again"
    aw "" >/dev/null
    wait_rate "$want"
    got=$(refresh_now)
  fi
  if [ -z "$got" ]; then
    logger -t hdr-kick "$MON did not come back after reconnecting (wanted $want Hz)"
    barch notify "Display" "The main monitor did not come back after reconnecting it. A reboot usually does." \
      --critical --app "hdr-kick" >/dev/null 2>&1
    exit 1
  fi
  if [ "$got" -lt "$want" ]; then
    logger -t hdr-kick "$MON is still at $got Hz after reconnecting (wanted $want)"
    barch notify "Display" "The main monitor came back at $got Hz instead of $want Hz and reconnecting it did not help. A reboot usually does." \
      --critical --app "hdr-kick" >/dev/null 2>&1
    exit 1
  fi
  logger -t hdr-kick "$MON back at $got Hz after reconnecting"
fi
