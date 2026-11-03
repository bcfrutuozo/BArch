#!/usr/bin/env bash
# Installs (or updates) the music pipeline on the NAS from this repo, over the SMB shares:
#   app        -> appdata/beets/pipeline/app/barch_music   (replaced on every run)
#   settings   -> appdata/beets/pipeline/config.json       (only when missing)
#   secrets    -> appdata/beets/pipeline/secrets.json      (only when missing; a fresh API token)
#   s6 scripts -> staged in the temporary share when they change; root installs them in beets-init
# and writes ~/.config/barch/music.json (URL + token) for `barch music`. The steps that need
# root on the Unraid side are printed at the end; nothing here runs on the server by itself.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
NAS_URL=${NAS_URL:-http://100.100.0.10:8338}
dst=$APPDATA/beets/pipeline

[ -d "$APPDATA/beets" ] || { echo "install: $APPDATA/beets not found (is the appdata share mounted?)" >&2; exit 1; }
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
for old in "$dst/app/barch_music.old" "$dst/app"/.old-*; do
  [ -e "$old" ] && { rm -rf "$old" 2>/dev/null || echo "note: $old could not be removed from here (container files); harmless"; }
done
echo "app copied to $dst/app/barch_music"
# the service reloads only when it restarts: ask it to (s6 brings it back with the new code)
if [ -r "$HOME/.config/barch/music.json" ] && curl -sf --max-time 10 -X POST -H "X-Barch-Token: $(jq -r .token "$HOME/.config/barch/music.json")" \
     "$(jq -r .url "$HOME/.config/barch/music.json")/api/restart" >/dev/null 2>&1; then
  echo "pipeline restarted with the new code"
else
  echo "the pipeline did not restart itself (older version or not running): docker restart beets on Unraid"
fi

[ -f "$dst/config.json" ] || { cp "$here/deploy/config.example.json" "$dst/config.json"; echo "config.json created"; }
if [ ! -f "$dst/secrets.json" ]; then
  token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  python3 - "$here/deploy/secrets.example.json" "$dst/secrets.json" "$token" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["token"] = sys.argv[3]
d["lidarr"]["api_key"] = d["plex"]["token"] = d["telegram"]["bot_token"] = d["telegram"]["chat_id"] = ""
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
  echo "secrets.json created: fill in the Lidarr API key, Plex token and Telegram bot there"
fi
token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$dst/secrets.json" 2>/dev/null || true)
if [ -n "$token" ]; then
  mkdir -p "$HOME/.config/barch"
  umask 077
  printf '{"url": "%s", "token": "%s"}\n' "$NAS_URL" "$token" > "$HOME/.config/barch/music.json"
  echo "$HOME/.config/barch/music.json written (barch music)"
else
  echo "secrets.json is not readable from here (owned by the container user): ~/.config/barch/music.json left as it is"
fi

# beets-init must be owned by root (linuxserver skips custom scripts otherwise) and /config is
# handed back to the container user at every start, so neither can be written from here: when
# the s6 scripts change they are staged in the temporary share and root installs them from there
stage_smb=${STAGE:-/mnt/nasfrutuozo/temporary/barch-music-s6}
stage_srv=/mnt/user/temporary/barch-music-s6
seen="$HOME/.cache/barch/music-s6.sha"
sum=$(cd "$here/deploy" && sha256sum custom-cont-init.d/* custom-services.d/* | sha256sum | cut -c1-16)
if [ "$(cat "$seen" 2>/dev/null)" != "$sum" ]; then
  mkdir -p "$stage_smb"
  cp -r "$here/deploy/custom-cont-init.d" "$here/deploy/custom-services.d" "$stage_smb/"
  echo "the s6 scripts changed: on Unraid, as root, then docker restart beets:"
  for f in custom-cont-init.d/50-music-pipeline-packages custom-services.d/music-pipeline; do
    echo "  install -D -m 755 -o root -g root $stage_srv/$f /mnt/user/appdata/beets-init/$f"
  done
  echo "  rm -rf $stage_srv"
  mkdir -p "$(dirname "$seen")" && echo "$sum" > "$seen"
else
  echo "s6 scripts unchanged since the last install"
fi

cat <<EOF

On the Unraid side (once):
  install the s6 scripts as printed above (beets-init owned by root, mode 755)
  chown -R 99:100 /mnt/user/appdata/beets/pipeline && chmod -R u=rwX,g=rwX,o=rwX /mnt/user/appdata/beets/pipeline
  chmod 600 /mnt/user/appdata/beets/pipeline/secrets.json   (the container reads it; this desktop no longer can)

beets container template (Docker > beets > Edit):
  Path  /mnt/user/downloads/torrents        -> /data                 (instead of the old /downloads)
  Path  /mnt/user/appdata/beets-init/custom-cont-init.d -> /custom-cont-init.d   (read only)
  Path  /mnt/user/appdata/beets-init/custom-services.d  -> /custom-services.d    (read only)
  Port  8338 -> 8338                                     (the pipeline API, for barch music)
  Network: frutuozoproxy                                 (qbittorrent, lidarr by name)
  remove the /config/install.sh path
Then disable the old User Script and watch the log: docker logs -f beets | grep -i pipeline
EOF
