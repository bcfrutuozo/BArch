#!/usr/bin/env bash
MON="HDMI-A-2"
METHOD="${1:-modeset}"   # modeset | dpms

aw() {  # aplica a regra do AW com o modo passado
  hyprctl eval "hl.monitor({
    output = \"$MON\", mode = \"$1\", position = \"auto\",
    bitdepth = 10, scale = \"2\", cm = \"hdr\",
    supports_hdr = 1, supports_wide_color = 1, vrr = 2,
    sdr_min_luminance = 0.005, sdr_max_luminance = 200,
    sdrbrightness = 1.0, sdrsaturation = 1.0,
    min_luminance = 0.0002, max_luminance = 426, max_avg_luminance = 250,
  })"
}

# espera o AW voltar (até ~10s)
for _ in $(seq 20); do
  hyprctl monitors | grep -A25 "Monitor $MON" | grep -q "dpmsStatus: 1" && break
  sleep 0.5
done
sleep 2

if [ "$METHOD" = "dpms" ]; then
  hyprctl dispatch "hl.dsp.dpms({ action = \"disable\", monitor = \"$MON\" })"
  sleep 3
  hyprctl dispatch "hl.dsp.dpms({ action = \"enable\", monitor = \"$MON\" })"
else
  aw "3840x2160@120HZ"
  sleep 2
  aw "3840x2160@240HZ"
fi
