#!/usr/bin/env bash
# Installs (or updates) the video rules on the NAS over the appdata share:
#   recyclarr/recyclarr.yml, settings.yml, custom-formats/  -> appdata/recyclarr/   (replaced every run)
#   secrets.yml (Radarr/Sonarr URLs and API keys)          -> appdata/recyclarr/   (only when missing,
#       from ~/.config/barch/video.json, which never enters the repo)
# Validates the config first with `recyclarr sync --preview` when a local recyclarr binary is given
# (RECYCLARR=/path/to/recyclarr). Nothing runs on the server by itself: the container template is
# printed at the end, and the container syncs daily on its own.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
dst=$APPDATA/recyclarr
keys=$HOME/.config/barch/video.json

[ -d "$APPDATA" ] || { echo "install: $APPDATA not found (is the appdata share mounted?)" >&2; exit 1; }
[ -r "$keys" ] || { echo "install: $keys missing ({\"radarr\":{\"url\",\"key\"},\"sonarr\":{...}})" >&2; exit 1; }

secrets() {
  jq -r '"radarr_url: \(.radarr.url)\nradarr_key: \(.radarr.key)\nsonarr_url: \(.sonarr.url)\nsonarr_key: \(.sonarr.key)"' "$keys"
}

if [ -n "${RECYCLARR:-}" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cp -r "$here/recyclarr/." "$tmp/"
  sed -i "s#/config/#$tmp/#" "$tmp/settings.yml"
  (umask 077; secrets > "$tmp/secrets.yml")
  out=$(RECYCLARR_CONFIG_DIR=$tmp RECYCLARR_DATA_DIR=$tmp/data "$RECYCLARR" sync --preview 2>&1)
  if grep -q '\[ERR\]' <<<"$out"; then grep '\[ERR\]\|\[WRN\]' <<<"$out" >&2; exit 1; fi
  echo "preview: config valid"
fi

mkdir -p "$dst"
cp "$here/recyclarr/recyclarr.yml" "$here/recyclarr/settings.yml" "$dst/"
rm -rf "$dst/custom-formats"
cp -r "$here/recyclarr/custom-formats" "$dst/"
[ -f "$dst/secrets.yml" ] || { (umask 077; secrets > "$dst/secrets.yml"); echo "secrets.yml created"; }
echo "config copied to $dst"

cat <<'EOF'

Unraid, once (Docker > Add Container):
  Name        recyclarr
  Repository  ghcr.io/recyclarr/recyclarr:8.8.0
  Extra Parameters  --user 99:100
  Path  /mnt/user/appdata/recyclarr -> /config
  Variable  TZ = America/Sao_Paulo
  Variable  CRON_SCHEDULE = @daily
First sync by hand (and after every install):
  docker exec recyclarr recyclarr sync
EOF
