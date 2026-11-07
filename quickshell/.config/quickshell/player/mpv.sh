#!/usr/bin/env bash
# The player's mpv (quickshell/player/Player.qml): audio only, idle, driven over the JSON IPC socket given as $1.
# --no-config keeps ~/.config/mpv (the video/HDR setup) out of it. MPRIS: mpv-mpris (pacman -S mpv-mpris) is
# loaded when installed, so the bar's media island, playerctl and the voice commands see what plays.
set -u
sock=$1
args=(--no-config --idle=yes --no-video --audio-display=no --really-quiet --gapless-audio=yes --keep-open=no
      --audio-client-name=barch-player --input-ipc-server="$sock" --loop-playlist=no --volume=100
      --cache=yes --demuxer-max-bytes=64MiB --demuxer-readahead-secs=60 --force-media-title=)
for s in /etc/mpv/scripts/mpris.so /usr/lib/mpv-mpris/mpris.so "$HOME/.config/mpv/scripts/mpris.so"; do
  [ -e "$s" ] && { args+=(--script="$s"); break; }
done
rm -f "$sock"
exec mpv "${args[@]}"
