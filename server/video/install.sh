#!/usr/bin/env bash
# Installs (or updates) the video side on the NAS over the appdata share. Two parts:
#
# Recyclarr (what Radarr/Sonarr grab):
#   recyclarr/recyclarr.yml, settings.yml, custom-formats/  -> appdata/recyclarr/   (replaced every run)
#   secrets.yml (Radarr/Sonarr URLs and API keys)          -> appdata/recyclarr/   (only when missing)
#   With RECYCLARR=/path/to/recyclarr the config is validated first with `sync --preview`.
#
# The video pipeline (PT-BR dub muxed into the 4K file, barch_video/):
#   app        -> appdata/barch-video/pipeline/app/barch_video   (replaced on every run, tests first)
#   settings   -> appdata/barch-video/pipeline/config.json       (only when missing)
#   secrets    -> appdata/barch-video/pipeline/secrets.json      (only when missing; a fresh API token,
#                 the Radarr key from ~/.config/barch/video.json, the Prowlarr key from its config.xml)
#   s6 scripts -> staged in the temporary share when they change; root installs them
#
# Keys live in ~/.config/barch/video.json (never in the repo). Nothing runs on the server by itself:
# the steps that need root or the Unraid UI are printed at the end.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
NAS_URL=${NAS_URL:-http://100.100.0.10:8339}
keys=$HOME/.config/barch/video.json

[ -d "$APPDATA" ] || { echo "install: $APPDATA not found (is the appdata share mounted?)" >&2; exit 1; }
[ -r "$keys" ] || { echo "install: $keys missing ({\"radarr\":{\"url\",\"key\"},\"sonarr\":{...}})" >&2; exit 1; }

# ------------------------------------------------------------------------------------- Recyclarr
rc=$APPDATA/recyclarr
secrets_yml() {
  jq -r '"radarr_url: \(.radarr.url)\nradarr_key: \(.radarr.key)\nsonarr_url: \(.sonarr.url)\nsonarr_key: \(.sonarr.key)"' "$keys"
}
if [ -n "${RECYCLARR:-}" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cp -r "$here/recyclarr/." "$tmp/"
  sed -i "s#/config/#$tmp/#" "$tmp/settings.yml"
  (umask 077; secrets_yml > "$tmp/secrets.yml")
  out=$(RECYCLARR_CONFIG_DIR=$tmp RECYCLARR_DATA_DIR=$tmp/data "$RECYCLARR" sync --preview 2>&1)
  if grep -q '\[ERR\]' <<<"$out"; then grep '\[ERR\]\|\[WRN\]' <<<"$out" >&2; exit 1; fi
  echo "recyclarr: preview valid"
fi
mkdir -p "$rc"
cp "$here/recyclarr/recyclarr.yml" "$here/recyclarr/settings.yml" "$rc/"
rm -rf "$rc/custom-formats"
cp -r "$here/recyclarr/custom-formats" "$rc/"
[ -f "$rc/secrets.yml" ] || { (umask 077; secrets_yml > "$rc/secrets.yml"); echo "recyclarr: secrets.yml created"; }
echo "recyclarr: config copied to $rc"

# ---------------------------------------------------------------------------------- the pipeline
dst=$APPDATA/barch-video/pipeline
python3 -m unittest discover -s "$here/tests" -q 2>&1 | tail -1
mkdir -p "$dst/app"
stamp=$(date +%Y%m%d%H%M%S)
rm -rf "$dst/app/barch_video.new"
cp -r "$here/barch_video" "$dst/app/barch_video.new"
find "$dst/app/barch_video.new" -name __pycache__ -prune -exec rm -rf {} +
[ -d "$dst/app/barch_video" ] && mv "$dst/app/barch_video" "$dst/app/.old-$stamp"
mv "$dst/app/barch_video.new" "$dst/app/barch_video"
for old in "$dst/app"/.old-*; do
  [ -e "$old" ] && { rm -rf "$old" 2>/dev/null || echo "note: $old could not be removed from here (container files); harmless"; }
done
echo "pipeline: app copied to $dst/app/barch_video"

[ -f "$dst/config.json" ] || { cp "$here/deploy/config.example.json" "$dst/config.json"; echo "pipeline: config.json created"; }
if [ ! -f "$dst/secrets.json" ]; then
  token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  pk=$(grep -oP '(?<=<ApiKey>)[^<]+' "$APPDATA/prowlarr/config.xml" 2>/dev/null || true)
  (umask 077; jq -n --arg t "$token" --arg rk "$(jq -r .radarr.key "$keys")" --arg pk "$pk" \
    '{token: $t, radarr: {api_key: $rk}, prowlarr: {api_key: $pk}, qbittorrent: {username: "", password: ""},
      telegram: {bot_token: "", chat_id: ""}}' > "$dst/secrets.json")
  echo "pipeline: secrets.json created${pk:+ (Prowlarr key found)}; Telegram: copy bot_token/chat_id from the music pipeline's"
fi
# Sonarr's key in a file of its own: secrets.json belongs to the container user once it runs (mode 600),
# so it cannot be edited from here; group users (100, the container's PGID) may read this one
if [ ! -f "$dst/secrets-sonarr.json" ] && [ "$(jq -r '.sonarr.key // ""' "$keys")" != "" ]; then
  (umask 027; jq -n --arg k "$(jq -r .sonarr.key "$keys")" '{sonarr: {api_key: $k}}' > "$dst/secrets-sonarr.json")
  echo "pipeline: secrets-sonarr.json created (series: the dub for every season Sonarr has)"
fi
token=$(jq -r .token "$dst/secrets.json" 2>/dev/null || true)
if [ -n "$token" ] && [ "$token" != null ]; then
  tmpk=$(mktemp)
  jq --arg u "$NAS_URL" --arg t "$token" '.pipeline = {url: $u, token: $t}' "$keys" > "$tmpk" && chmod 600 "$tmpk" && mv "$tmpk" "$keys"
  echo "pipeline: $keys knows the API (barch video)"
else
  echo "pipeline: secrets.json is not readable from here (owned by the container user): $keys left as it is"
fi
# the service reloads only when it restarts: ask it to (s6 brings it back with the new code)
if jq -e .pipeline.token "$keys" >/dev/null 2>&1 && curl -sf --max-time 10 -X POST \
     -H "X-Barch-Token: $(jq -r .pipeline.token "$keys")" "$(jq -r .pipeline.url "$keys")/api/restart" >/dev/null 2>&1; then
  echo "pipeline: restarted with the new code"
else
  echo "pipeline: not running yet (or older): see the container steps below"
fi

# Radarr and Sonarr call the pipeline when a file comes in, is upgraded or goes (a "Webhook" connection,
# made once through their API): the probe and the trim happen then, not at the next 5-minute tick
if jq -e .pipeline.token "$keys" >/dev/null 2>&1; then
  hook="http://barch-video:8339/api/webhook?token=$(jq -r .pipeline.token "$keys")"
  # the apps test the URL when the connection is created: give the service just restarted time to listen
  for _ in $(seq 1 20); do
    curl -sf --max-time 3 -H "X-Barch-Token: $(jq -r .pipeline.token "$keys")" "$(jq -r .pipeline.url "$keys")/api/status" >/dev/null 2>&1 && break
    sleep 2
  done
  for app in radarr sonarr; do
    url=$(jq -r ".$app.url // \"\"" "$keys"); key=$(jq -r ".$app.key // \"\"" "$keys")
    [ -n "$url" ] && [ -n "$key" ] || continue
    have=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/notification" | jq -r '.[] | select(.name == "BArch video pipeline") | .id' 2>/dev/null | head -1)
    if [ -n "$have" ]; then
      echo "$app: webhook to the pipeline already there (connection $have)"
      continue
    fi
    if [ "$app" = radarr ]; then
      events='{onDownload: true, onUpgrade: true, onMovieFileDelete: true, onMovieFileDeleteForUpgrade: true}'
    else
      events='{onDownload: true, onUpgrade: true, onImportComplete: true, onEpisodeFileDelete: true, onEpisodeFileDeleteForUpgrade: true}'
    fi
    body=$(jq -cn --arg u "$hook" "$events + {name: \"BArch video pipeline\", implementation: \"Webhook\", configContract: \"WebhookSettings\",
      tags: [], fields: [{name: \"url\", value: \$u}, {name: \"method\", value: 1}]}")
    if curl -sf --max-time 15 -X POST -H "X-Api-Key: $key" -H 'Content-Type: application/json' -d "$body" "$url/api/v3/notification" >/dev/null; then
      echo "$app: webhook to the pipeline created"
    else
      echo "$app: could not create the webhook connection (Settings > Connect > Webhook, URL $hook)" >&2
    fi
  done
fi

stage_smb=${STAGE:-/mnt/nasfrutuozo/temporary/barch-video-s6}
stage_srv=/mnt/user/temporary/barch-video-s6
seen="$HOME/.cache/barch/video-s6.sha"
sum=$(cd "$here/deploy" && sha256sum custom-cont-init.d/* custom-services.d/* | sha256sum | cut -c1-16)
if [ "$(cat "$seen" 2>/dev/null)" != "$sum" ]; then
  mkdir -p "$stage_smb"
  cp -r "$here/deploy/custom-cont-init.d" "$here/deploy/custom-services.d" "$stage_smb/"
  echo
  echo "the s6 scripts changed: on Unraid, as root, then docker restart barch-video:"
  for f in custom-cont-init.d/50-video-pipeline-packages custom-services.d/video-pipeline; do
    echo "  install -D -m 755 -o root -g root $stage_srv/$f /mnt/user/appdata/barch-video-init/$f"
  done
  echo "  rm -rf $stage_srv"
  mkdir -p "$(dirname "$seen")" && echo "$sum" > "$seen"
else
  echo "pipeline: s6 scripts unchanged since the last install"
fi

cat <<'EOF'

Unraid, once:
  Recyclarr (Docker > Add Container): ghcr.io/recyclarr/recyclarr:8.8.0, Extra Parameters --user 99:100,
    /mnt/user/appdata/recyclarr -> /config, TZ=America/Sao_Paulo, CRON_SCHEDULE=@daily
    after every install: docker exec recyclarr recyclarr sync
  barch-video (Docker > Add Container):
    Repository  ghcr.io/linuxserver/baseimage-alpine:3.23-0eccc513-ls2
    Network     frutuozoproxy
    Variables   PUID=99  PGID=100  TZ=America/Sao_Paulo
    Port        8339 -> 8339
    Path  /mnt/user/appdata/barch-video                     -> /config
    Path  /mnt/user/appdata/barch-video-init/custom-cont-init.d -> /custom-cont-init.d   (read only)
    Path  /mnt/user/appdata/barch-video-init/custom-services.d  -> /custom-services.d    (read only)
    Path  /mnt/user/downloads/torrents                      -> /data     (as qBittorrent sees it)
    Path  /mnt/user/media/movies                            -> /movies   (as Radarr sees it)
    Path  /mnt/user/media/tv                                -> /tv
  then: chown -R 99:100 /mnt/user/appdata/barch-video && chmod -R u=rwX,g=rwX,o=rwX /mnt/user/appdata/barch-video/pipeline
        chmod 600 /mnt/user/appdata/barch-video/pipeline/secrets.json   (the container reads it; this desktop no longer can)
  log: docker logs -f barch-video | grep -i pipeline
EOF
