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
MON="HDMI-A-2"
METHOD="${1:-modeset}"   # modeset | dpms
SINCE=$(date -d '-15 seconds' '+%Y-%m-%d %H:%M:%S')

drm_failed() {
  journalctl -k -q --no-pager -o cat --since "$SINCE" 2>/dev/null |
    grep -q 'Failed to apply atomic modeset'
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
  sleep 3
  aw "" >/dev/null
  sleep 5
}

# espera o AW voltar (até ~10s)
for _ in $(seq 20); do
  hyprctl monitors | grep -A25 "Monitor $MON" | grep -q "dpmsStatus: 1" && break
  sleep 0.5
done
sleep 2
drm_failed && give_up "before the kick"

if [ "$METHOD" = "dpms" ]; then
  hyprctl dispatch "hl.dsp.dpms({ action = \"disable\", monitor = \"$MON\" })"
  sleep 3
  hyprctl dispatch "hl.dsp.dpms({ action = \"enable\", monitor = \"$MON\" })"
else
  aw "3840x2160@120"
  sleep 2
  drm_failed && give_up "at 120 Hz"
  aw ""
fi

sleep 2
want=$(refresh_wanted)
[ -n "$want" ] || exit 0
got=$(refresh_now)
if [ -n "$got" ] && [ "$got" -lt "$want" ]; then
  drm_failed && give_up "before reconnecting"
  reconnect "$want"
  got=$(refresh_now)
  if [ -n "$got" ] && [ "$got" -lt "$want" ]; then
    logger -t hdr-kick "$MON is still at $got Hz after reconnecting (wanted $want)"
    barch notify "Display" "The main monitor came back at $got Hz instead of $want Hz and reconnecting it did not help. A reboot usually does." \
      --critical --app "hdr-kick" >/dev/null 2>&1
    exit 1
  fi
  logger -t hdr-kick "$MON back at $got Hz after reconnecting"
fi
