#!/bin/sh
# Marca o monitor principal (Alienware, HDMI-A-2) como "primary" no XWayland.
# No Hyprland ele fica em 0x0 e o de retrato em -1080x0, mas o XWayland não tem
# coordenadas negativas: o de retrato vira +0+0 e, sem primary, o Wine/Proton usa
# ele como monitor principal (jogos antigos em fullscreen abrem lá ou ficam pretos).
OUT="${1:-HDMI-A-2}"
# o XWayland pode demorar a subir: tenta por até ~60 s
i=0
while [ $i -lt 30 ]; do
    if xrandr --output "$OUT" --primary 2>/dev/null; then
        exit 0
    fi
    i=$((i + 1))
    sleep 2
done
exit 1
