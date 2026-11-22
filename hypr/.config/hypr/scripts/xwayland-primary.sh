#!/bin/sh
# Marca o monitor principal (Alienware, HDMI-A-2) como "primary" no XWayland.
# No Hyprland ele fica em 0x0 e o de retrato em -1080x0, mas o XWayland não tem
# coordenadas negativas: o de retrato vira +0+0 e, sem primary, o Wine/Proton usa
# ele como monitor principal (jogos antigos em fullscreen abrem lá ou ficam pretos).
# Also run by the xwayland-primary rule on monitor.added. Right after a reconnect
# xrandr accepts --primary before XWayland has rebuilt the output and the mark is
# lost (2026-11-22: "ok" at 16:32, no primary afterwards), so it is confirmed with
# --listmonitors ("*NAME") a few seconds later and set again until it sticks.
OUT="${1:-HDMI-A-2}"

is_primary() {
    xrandr --listmonitors 2>/dev/null | grep -q "[*]$OUT "
}

# o XWayland pode demorar a subir: tenta por até ~60 s
i=0
while [ $i -lt 20 ]; do
    xrandr --output "$OUT" --primary 2>/dev/null
    sleep 3
    is_primary && exit 0
    i=$((i + 1))
done
exit 1
