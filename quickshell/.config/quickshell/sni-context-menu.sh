#!/usr/bin/env bash
# Abre o menu de contexto de um ícone do tray que não tem menu próprio (apps Wine/Proton).
# Uso: sni-context-menu.sh <Id do ícone>
target="$1"

# Monitor que o Wine trata como principal (a origem 0,0 dele)
WINE_PRIMARY="HDMI-A-2"

# Origem de um monitor no espaço do XWayland, pelo nome
xwl_origin() {
  xrandr --listmonitors 2>/dev/null | awk -v n="$1" '
    { gsub(/^[+*]+/, "", $2) }
    $2 == n { split($3, p, "+"); print p[2], p[3] }'
}

# Posição do cursor em coordenadas lógicas do Hyprland
read -r cx cy < <(hyprctl cursorpos | tr -d ',')

# Monitor sob o cursor: nome, origem lógica e escala
# (transform ímpar = tela girada 90°/270°, então largura e altura trocam)
read -r name mx my scale < <(hyprctl monitors -j | jq -r --argjson cx "$cx" --argjson cy "$cy" '
  .[]
  | (if (.transform % 2) == 1 then {w: .height, h: .width} else {w: .width, h: .height} end) as $s
  | select($cx >= .x and $cx < .x + $s.w / .scale and $cy >= .y and $cy < .y + $s.h / .scale)
  | "\(.name) \(.x) \(.y) \(.scale)"' | head -n1)

read -r ox oy < <(xwl_origin "$name")
read -r px py < <(xwl_origin "$WINE_PRIMARY")
ox=${ox:-0}; oy=${oy:-0}; px=${px:-0}; py=${py:-0}

# Posição dentro do monitor × escala + origem dele − origem do monitor principal
read -r x y < <(awk -v cx="$cx" -v cy="$cy" -v mx="$mx" -v my="$my" -v s="${scale:-1}" \
  -v ox="$ox" -v oy="$oy" -v px="$px" -v py="$py" \
  'BEGIN { printf "%d %d\n", (cx - mx) * s + ox - px, (cy - my) * s + oy - py }')

echo "$(date +%T) mon=$name cursor=$cx,$cy -> $x,$y" >> /tmp/sni-menu.log

items=$(busctl --user --json=short get-property org.kde.StatusNotifierWatcher \
  /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems \
  | jq -r '.data[]')

for item in $items; do
  # Cada entrada é "endereço/caminho"; algumas trazem só o endereço
  if [[ "$item" == */* ]]; then
    addr="${item%%/*}"
    path="/${item#*/}"
  else
    addr="$item"
    path="/StatusNotifierItem"
  fi

  id=$(busctl --user --json=short get-property "$addr" "$path" \
    org.kde.StatusNotifierItem Id 2>/dev/null | jq -r '.data')

  if [[ "$id" == "$target" ]]; then
    # O "--" permite passar coordenadas negativas sem o busctl confundi-las com opções
    busctl --user call -- "$addr" "$path" org.kde.StatusNotifierItem ContextMenu ii "$x" "$y"
    exit 0
  fi
done
