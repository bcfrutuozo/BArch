#!/usr/bin/env bash
# Kicks the AW back into HDR after DPMS or a resume: 120 Hz, then its own config again.
# The mode comes from BArch.monitors (monitors.lua) plus the bar's overrides (HDR, SDR
# brightness), so the kick never undoes what the Control Center set.
#
# If nvidia-drm has refused a modeset since the screen came back ("Failed to apply atomic
# modeset" after a bad resume), it stops: more modesets on a GPU in that state hung the
# whole machine (2026-10-28).
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
