#!/usr/bin/env bash
# record.sh — gravação de tela com o gpu-screen-recorder (a barra chama isto).
#   record.sh start full     grava o monitor em foco
#   record.sh start region   escolhe uma área com o slurp e grava só ela
#   record.sh stop           para e salva
#   record.sh status         "recording <início em segundos desde 1970>" ou "idle"
# Roda como unidade do systemd do usuário (gsr-record), então continua mesmo se a barra
# reiniciar. Ao parar, o gsr-replay-saved mostra a notificação com Open / Folder. Ela é
# chamada pelo "stop" (fora da unidade): se fosse pelo -sc do gravador, morreria junto com a
# unidade ao parar e o balão sumiria na hora.
# HDR: se o monitor gravado estiver em HDR, grava em HEVC HDR (igual ao replay).

unit=gsr-record
last="${XDG_RUNTIME_DIR:-/tmp}/gsr-record.file"     # arquivo da gravação em andamento
dir="${RECORD_DIR:-$HOME/Videos/Recordings}"

case "$1" in
  start)
    systemctl --user is-active --quiet "$unit" && exit 0
    if [[ "$2" == region ]]; then
      sel=$(slurp -f "%wx%h+%x+%y %o") || exit 0          # Esc cancela
      geom=${sel% *}; mon=${sel##* }
      target=(-w region -region "$geom")
    else
      mon=$(hyprctl activeworkspace -j | jq -r '.monitor')
      target=(-w "$mon")
    fi
    cm=$(hyprctl monitors -j | jq -r --arg m "$mon" '.[] | select(.name == $m) | .colorManagementPreset // ""')
    codec=hevc; [[ "$cm" == hdr ]] && codec=hevc_hdr
    mkdir -p "$dir"
    file="$dir/$(date +%Y-%m-%d_%H-%M-%S).mkv"
    printf '%s' "$file" > "$last"
    systemctl --user reset-failed "$unit" 2>/dev/null
    systemd-run --user --unit="$unit" --collect -p KillSignal=SIGINT -p TimeoutStopSec=10 \
      gpu-screen-recorder "${target[@]}" -f 60 -c mkv -k "$codec" -q very_high \
      -a default_output -o "$file" >/dev/null
    ;;
  stop)
    systemctl --user stop "$unit"            # espera o gravador fechar o arquivo (SIGINT)
    file=$(cat "$last" 2>/dev/null); rm -f "$last"
    saved="$HOME/.local/bin/gsr-replay-saved"
    [[ -n "$file" && -f "$file" && -x "$saved" ]] && "$saved" "$file" regular
    ;;
  status)
    if systemctl --user is-active --quiet "$unit"; then
      t=$(systemctl --user show "$unit" -p ActiveEnterTimestamp --value)
      echo "recording $(date -d "$t" +%s 2>/dev/null || date +%s)"
    else
      echo idle
    fi
    ;;
  *) echo "usage: record.sh start full|region | stop | status" >&2; exit 2 ;;
esac
