#!/usr/bin/env bash
# Installs (or updates) the music pipeline on the NAS from this repo, over the appdata share. It runs
# in its own container, barch-music (the linuxserver Alpine base image; the s6 scripts install what it
# needs), like barch-video:
#   app        -> appdata/barch-music/pipeline/app/barch_music   (replaced on every run, tests first)
#   settings   -> appdata/barch-music/pipeline/config.json       (only when missing: the beets container's,
#                 where the pipeline lived until 2026-11-04, or the example)
#   secrets    -> appdata/barch-music/pipeline/secrets.json      (only when missing and there is nothing to
#                 move: a fresh API token; the beets container's is moved by root, see the end)
#   s6 scripts -> staged in the temporary share when they change; root installs them in barch-music-init
# and writes ~/.config/barch/music.json (URL + token) for `barch music` when it can read the token.
# Jobs, reviews, the seed history and every cache live in /data/music-pipeline, not here.
# The steps that need root or the Unraid UI are printed at the end; nothing runs on the server by itself.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
NAS_URL=${NAS_URL:-http://100.100.0.10:8338}
dst=$APPDATA/barch-music/pipeline
old=$APPDATA/beets/pipeline            # where it ran before; config and secrets come from there once

[ -d "$APPDATA" ] || { echo "install: $APPDATA not found (is the appdata share mounted?)" >&2; exit 1; }
python3 -m unittest discover -s "$here/tests" -q 2>&1 | tail -1

mkdir -p "$dst/app"
# the previous version is moved aside, not deleted in place: files the container wrote in it
# (bytecode of older versions) belong to its user and cannot be removed from here
stamp=$(date +%Y%m%d%H%M%S)
rm -rf "$dst/app/barch_music.new"
cp -r "$here/barch_music" "$dst/app/barch_music.new"
find "$dst/app/barch_music.new" -name __pycache__ -prune -exec rm -rf {} +
[ -d "$dst/app/barch_music" ] && mv "$dst/app/barch_music" "$dst/app/.old-$stamp"
mv "$dst/app/barch_music.new" "$dst/app/barch_music"
for o in "$dst/app"/.old-*; do
  [ -e "$o" ] && { rm -rf "$o" 2>/dev/null || echo "note: $o could not be removed from here (container files); harmless"; }
done
echo "app copied to $dst/app/barch_music"

moving=0
if [ ! -f "$dst/config.json" ]; then
  # (-r is not enough over SMB: the mode says readable, the open is refused)
  if [ -e "$old/config.json" ] && cp "$old/config.json" "$dst/config.json" 2>/dev/null; then
    echo "config.json moved over from the beets container"
  elif [ -e "$old/config.json" ]; then
    rm -f "$dst/config.json"
    moving=1        # the beets container's, owned by its user: root copies it (below)
  else
    cp "$here/deploy/config.example.json" "$dst/config.json"; echo "config.json created"
  fi
fi
if [ ! -f "$dst/secrets.json" ]; then
  if [ -e "$old/secrets.json" ]; then
    moving=1        # the beets container's: root copies it (mode 600, unreadable from here); a fresh one would change the token
  else
    token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    python3 - "$here/deploy/secrets.example.json" "$dst/secrets.json" "$token" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["token"] = sys.argv[3]
d["lidarr"]["api_key"] = d["plex"]["token"] = d["telegram"]["bot_token"] = d["telegram"]["chat_id"] = ""
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
    echo "secrets.json created: fill in the Lidarr API key, Plex token and Telegram bot there"
  fi
fi
token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$dst/secrets.json" 2>/dev/null || true)
if [ -n "$token" ]; then
  mkdir -p "$HOME/.config/barch"
  (umask 077; printf '{"url": "%s", "token": "%s"}\n' "$NAS_URL" "$token" > "$HOME/.config/barch/music.json")
  echo "$HOME/.config/barch/music.json written (barch music)"
fi
# the service reloads only when it restarts: ask it to (s6 brings it back with the new code)
if [ -r "$HOME/.config/barch/music.json" ] && curl -sf --max-time 10 -X POST -H "X-Barch-Token: $(jq -r .token "$HOME/.config/barch/music.json")" \
     "$(jq -r .url "$HOME/.config/barch/music.json")/api/restart" >/dev/null 2>&1; then
  echo "pipeline restarted with the new code"
else
  echo "the pipeline did not restart itself (not running yet): see the container steps below"
fi

# barch-music-init must be owned by root (linuxserver skips custom scripts otherwise) and /config is
# handed to the container user, so neither can be written from here: when the s6 scripts change they
# are staged in the temporary share and root installs them from there
stage_smb=${STAGE:-/mnt/nasfrutuozo/temporary/barch-music-s6}
stage_srv=/mnt/user/temporary/barch-music-s6
seen="$HOME/.cache/barch/music-s6.sha"
sum=$(cd "$here/deploy" && { echo barch-music; sha256sum custom-cont-init.d/* custom-services.d/*; } | sha256sum | cut -c1-16)
if [ "$(cat "$seen" 2>/dev/null)" != "$sum" ]; then
  mkdir -p "$stage_smb"
  cp -r "$here/deploy/custom-cont-init.d" "$here/deploy/custom-services.d" "$stage_smb/"
  echo
  echo "the s6 scripts changed: on Unraid, as root, then docker restart barch-music:"
  for f in custom-cont-init.d/50-music-pipeline-packages custom-services.d/music-pipeline; do
    echo "  install -D -m 755 -o root -g root $stage_srv/$f /mnt/user/appdata/barch-music-init/$f"
  done
  echo "  rm -rf $stage_srv"
  mkdir -p "$(dirname "$seen")" && echo "$sum" > "$seen"
else
  echo "s6 scripts unchanged since the last install"
fi

if ((moving)); then
  cat <<'EOF'

Moving from the beets container (once, on Unraid, as root; the pipeline must never run in both):
  docker stop beets                       (and set its autostart off in the Docker tab)
  cp -n /mnt/user/appdata/beets/pipeline/config.json /mnt/user/appdata/beets/pipeline/secrets.json /mnt/user/appdata/barch-music/pipeline/
  then create barch-music as below, start it and check: barch music status
  once it has run well for a few days: remove the beets container, and
  rm -rf /mnt/user/appdata/beets /mnt/user/appdata/beets-init   (nothing else used them)
EOF
fi
cat <<'EOF'

Unraid, once:
  barch-music (Docker > Add Container):
    Repository  ghcr.io/linuxserver/baseimage-alpine:3.23-0eccc513-ls2
    Network     frutuozoproxy                                (qbittorrent, lidarr by name)
    Variables   PUID=99  PGID=100  TZ=America/Sao_Paulo
    Port        8338 -> 8338                                 (the pipeline API, for barch music)
    Path  /mnt/user/appdata/barch-music                      -> /config
    Path  /mnt/user/appdata/barch-music-init/custom-cont-init.d -> /custom-cont-init.d   (read only)
    Path  /mnt/user/appdata/barch-music-init/custom-services.d  -> /custom-services.d    (read only)
    Path  /mnt/user/downloads/torrents                       -> /data     (as qBittorrent sees it)
    Path  /mnt/user/media/music                              -> /music    (the library, read-write)
  then: chown -R 99:100 /mnt/user/appdata/barch-music && chmod -R u=rwX,g=rwX,o=rwX /mnt/user/appdata/barch-music/pipeline
        chmod 600 /mnt/user/appdata/barch-music/pipeline/secrets.json   (the container reads it; this desktop no longer can)
  log: docker logs -f barch-music | grep -i pipeline
EOF
