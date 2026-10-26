#!/usr/bin/env bash
# tools.sh — ferramentas de tela do launcher. O resultado vai para o clipboard + notificação.
#   ocr    seleciona uma área e copia o texto dela (inglês + português)
#   pick   conta-gotas: clica num pixel e copia a cor em hex
#   qr     seleciona uma área com um QR code e copia o conteúdo (link vira botão "Open")
# Depende de: grim, slurp, wl-clipboard, tesseract (+ tesseract-data-eng/por), hyprpicker, zbar.

tool="$1"
sleep 0.25    # dá tempo do launcher sumir da tela

need() {
  command -v "$1" >/dev/null && return 0
  notify-send -a "Tools" -i dialog-warning "Missing: $1" "Install with: sudo pacman -S $2"
  exit 1
}
notify() { notify-send -a "Tools" -i "$1" "$2" "$3"; }
preview() { tr '\n' ' ' <<<"$1" | cut -c1-140; }

case "$tool" in
  ocr)
    need grim grim; need slurp slurp; need tesseract "tesseract tesseract-data-eng tesseract-data-por"
    area=$(slurp) || exit 0
    langs="eng"
    tesseract --list-langs 2>/dev/null | grep -qx por && langs="eng+por"
    text=$(grim -g "$area" - | tesseract stdin stdout -l "$langs" --psm 6 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/N;/^\n$/D')
    if [[ -z "${text//[[:space:]]/}" ]]; then
      notify dialog-warning "No Text Found" "Try selecting a larger or sharper area."
      exit 0
    fi
    printf '%s' "$text" | wl-copy
    notify edit-copy "Text Copied" "$(preview "$text")"
    ;;

  pick)
    need hyprpicker hyprpicker
    color=$(hyprpicker -f hex -n 2>/dev/null) || exit 0
    [[ -z "$color" ]] && exit 0
    printf '%s' "$color" | wl-copy
    # amostra da cor como ícone da notificação
    icon="${XDG_RUNTIME_DIR:-/tmp}/picked-color.svg"
    printf '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" rx="14" fill="%s"/></svg>' "$color" > "$icon"
    notify "$icon" "Color Copied" "$color"
    ;;

  qr)
    need grim grim; need slurp slurp; need zbarimg zbar
    area=$(slurp) || exit 0
    data=$(grim -g "$area" - | zbarimg -q --raw - 2>/dev/null)
    if [[ -z "$data" ]]; then
      notify dialog-warning "No QR Code Found" "Select the whole code, with a little margin around it."
      exit 0
    fi
    printf '%s' "$data" | wl-copy
    if [[ "$data" =~ ^https?:// ]]; then
      ( action=$(timeout 300 notify-send -a "Tools" -i edit-copy -A open="Open" "QR Code Copied" "$(preview "$data")")
        [[ "$action" == open ]] && xdg-open "$data" ) >/dev/null 2>&1 &
    else
      notify edit-copy "QR Code Copied" "$(preview "$data")"
    fi
    ;;

  *)
    echo "usage: tools.sh ocr|pick|qr" >&2; exit 2 ;;
esac
