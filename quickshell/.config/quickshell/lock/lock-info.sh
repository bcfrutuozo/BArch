#!/usr/bin/env bash
# lock-info.sh — textos extras da tela de bloqueio (hyprlock.conf chama com cmd[update:…]).
#   date     dia da semana e data + clima de agora (do widget de clima da barra)
#   media    música tocando (playerctl); vazio se nada estiver tocando
#   notifs   notificações que chegaram desde que a tela travou; vazio se nenhuma
# A saída usa marcação Pango; os ícones vêm da fonte Symbols Nerd Font.

icon() { printf '<span font_family="Symbols Nerd Font">%s</span>' "$1"; }
esc()  { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

case "$1" in
  date)
    d=$(LC_TIME=en_US.UTF-8 date +"%A, %B %-d")
    w="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/weather-now.txt"
    # só mostra o clima se o arquivo for recente (até 2 h)
    if [[ -s "$w" && $(( $(date +%s) - $(stat -c %Y "$w") )) -lt 7200 ]]; then
      IFS=$'\t' read -r gl temp desc < "$w"
      printf '%s     %s  %s  %s\n' "$d" "$(icon "$gl")" "$temp" "$(esc <<<"$desc")"
    else
      echo "$d"
    fi
    ;;
  media)
    command -v playerctl >/dev/null || exit 0
    [[ "$(playerctl status 2>/dev/null)" == "Playing" ]] || exit 0
    t=$(playerctl metadata --format '{{artist}}|{{title}}' 2>/dev/null)
    artist=${t%%|*}; title=${t#*|}
    [[ -n "$title" ]] || exit 0
    line=$title; [[ -n "$artist" ]] && line="$artist — $title"
    (( ${#line} > 70 )) && line="${line:0:67}…"
    printf '%s  %s\n' "$(icon '󰎇')" "$(esc <<<"$line")"   # music_note
    ;;
  notifs)
    pid=$(pgrep -xo hyprlock) || exit 0
    since=$(stat -c %Y "/proc/$pid")
    n=$(qs ipc call notifs awayCount "$since" 2>/dev/null | tr -dc '0-9')
    [[ -n "$n" && "$n" -gt 0 ]] || exit 0
    [[ "$n" -eq 1 ]] && s="notification" || s="notifications"
    printf '%s  %s %s while you were away\n' "$(icon '󰂚')" "$n" "$s"   # bell
    ;;
esac
