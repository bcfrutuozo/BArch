#!/usr/bin/env bash
# Installs (or updates) the torrent statistics on the NAS over the appdata share:
#
#   app        -> appdata/barch-torrents/app/barch_torrents   (replaced on every run, tests first)
#   settings   -> appdata/barch-torrents/config.json          (only when missing)
#   secrets    -> appdata/barch-torrents/secrets.json         (only when missing: a fresh API token)
#   *arr keys  -> appdata/barch-torrents/secrets-arr.json     (every run: Radarr's and Sonarr's from
#                 ~/.config/barch/video.json, Lidarr's from .lidarr.key in ~/.config/barch/torrents.json)
#   s6 scripts -> staged in the temporary share when they change; root installs them
#
# The database (appdata/barch-torrents/data/torrents.db) is never touched from here. Nothing runs on
# the server by itself: the steps that need root or the Unraid UI are printed at the end.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
NAS_URL=${NAS_URL:-http://100.100.0.10:8340}
conf=$HOME/.config/barch/torrents.json
video=$HOME/.config/barch/video.json

[ -d "$APPDATA" ] || { echo "install: $APPDATA not found (is the appdata share mounted?)" >&2; exit 1; }

dst=$APPDATA/barch-torrents
python3 -m unittest discover -s "$here/tests" -q 2>&1 | tail -1
mkdir -p "$dst/app"
stamp=$(date +%Y%m%d%H%M%S)
rm -rf "$dst/app/barch_torrents.new"
cp -r "$here/barch_torrents" "$dst/app/barch_torrents.new"
find "$dst/app/barch_torrents.new" -name __pycache__ -prune -exec rm -rf {} +
[ -d "$dst/app/barch_torrents" ] && mv "$dst/app/barch_torrents" "$dst/app/.old-$stamp"
mv "$dst/app/barch_torrents.new" "$dst/app/barch_torrents"
for old in "$dst/app"/.old-*; do
  [ -e "$old" ] && { rm -rf "$old" 2>/dev/null || echo "note: $old could not be removed from here (container files); harmless"; }
done
echo "torrents: app copied to $dst/app/barch_torrents"

[ -f "$dst/config.json" ] || { cp "$here/deploy/config.example.json" "$dst/config.json"; echo "torrents: config.json created"; }
if [ ! -f "$dst/secrets.json" ]; then
  token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  (umask 077; jq -n --arg t "$token" '{token: $t, qbittorrent: {username: "", password: ""}}' > "$dst/secrets.json")
  echo "torrents: secrets.json created"
fi
token=$(jq -r .token "$dst/secrets.json" 2>/dev/null || true)
mkdir -p "$(dirname "$conf")"
[ -f "$conf" ] || (umask 077; echo '{"lidarr": {"key": ""}}' > "$conf")
if [ -n "$token" ] && [ "$token" != null ]; then
  tmpk=$(mktemp)
  jq --arg u "$NAS_URL" --arg t "$token" '.url = $u | .token = $t' "$conf" > "$tmpk" && chmod 600 "$tmpk" && mv "$tmpk" "$conf"
  echo "torrents: $conf knows the API (barch torrents)"
else
  echo "torrents: secrets.json is not readable from here (owned by the container user): $conf left as it is"
fi

# the *arr keys in a file of their own: secrets.json belongs to the container user once it runs
# (mode 600) and cannot be edited from here; group users (100, the container's PGID) may read this one
key() { jq -r "$1 // \"\"" "$2" 2>/dev/null || true; }
lk=$(key .lidarr.key "$conf"); rk=$(key .radarr.key "$video"); sk=$(key .sonarr.key "$video")
if (umask 027; jq -n --arg l "$lk" --arg r "$rk" --arg s "$sk" \
     '{lidarr: {api_key: $l}, radarr: {api_key: $r}, sonarr: {api_key: $s}} | with_entries(select(.value.api_key != ""))' \
     > "$dst/secrets-arr.json") 2>/dev/null; then
  echo "torrents: secrets-arr.json written (indexers from:$([ -n "$lk" ] && echo " lidarr")$([ -n "$rk" ] && echo " radarr")$([ -n "$sk" ] && echo " sonarr"))"
else
  echo "torrents: secrets-arr.json could not be written from here"
fi
[ -n "$lk" ] || echo "torrents: no Lidarr key: put it in $conf as .lidarr.key (Lidarr > Settings > General) and run this again,"\
  "or the music torrents have no indexer"

# the service reloads only when it restarts: ask it to (s6 brings it back with the new code)
if [ -n "$token" ] && [ "$token" != null ] && curl -sf --max-time 10 -X POST -H "X-Barch-Token: $token" \
     "$NAS_URL/api/restart" >/dev/null 2>&1; then
  echo "torrents: restarted with the new code"
else
  echo "torrents: not running yet: see the container steps below"
fi

stage_smb=${STAGE:-/mnt/nasfrutuozo/temporary/barch-torrents-s6}
stage_srv=/mnt/user/temporary/barch-torrents-s6
seen="$HOME/.cache/barch/torrents-s6.sha"
sum=$(cd "$here/deploy" && sha256sum custom-cont-init.d/* custom-services.d/* | sha256sum | cut -c1-16)
if [ "$(cat "$seen" 2>/dev/null)" != "$sum" ]; then
  mkdir -p "$stage_smb"
  cp -r "$here/deploy/custom-cont-init.d" "$here/deploy/custom-services.d" "$stage_smb/"
  echo
  echo "the s6 scripts changed: on Unraid, as root, then docker restart barch-torrents:"
  for f in custom-cont-init.d/50-torrents-packages custom-services.d/torrents; do
    echo "  install -D -m 755 -o root -g root $stage_srv/$f /mnt/user/appdata/barch-torrents-init/$f"
  done
  echo "  rm -rf $stage_srv"
  mkdir -p "$(dirname "$seen")" && echo "$sum" > "$seen"
else
  echo "torrents: s6 scripts unchanged since the last install"
fi

cat <<'EOT'

Unraid, once:
  barch-torrents (Docker > Add Container):
    Repository  ghcr.io/linuxserver/baseimage-alpine:3.23-0eccc513-ls2
    Network     frutuozoproxy                                (qbittorrent, lidarr, radarr, sonarr by name)
    Variables   PUID=99  PGID=100  TZ=America/Sao_Paulo
    Port        8340 -> 8340
    Path  /mnt/user/appdata/barch-torrents                          -> /config
    Path  /mnt/user/appdata/barch-torrents-init/custom-cont-init.d -> /custom-cont-init.d   (read only)
    Path  /mnt/user/appdata/barch-torrents-init/custom-services.d  -> /custom-services.d    (read only)
  then: chown -R 99:100 /mnt/user/appdata/barch-torrents && chmod -R u=rwX,g=rwX,o=rwX /mnt/user/appdata/barch-torrents
        chmod 600 /mnt/user/appdata/barch-torrents/secrets.json   (the container reads it; this desktop no longer can)
  log: docker logs -f barch-torrents | grep -i torrents
EOT
