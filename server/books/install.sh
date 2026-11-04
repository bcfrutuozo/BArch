#!/usr/bin/env bash
# Stages the Unraid templates of the book stack (Shelfmark, Calibre-Web-Automated, Audiobookshelf) in
# the temporary share and prints what root runs on Unraid to put them in place. Nothing runs on the
# server by itself. The Prowlarr API key is filled into the staged Shelfmark template (read from
# appdata/prowlarr/config.xml), never into the repo; the other keys go in the Unraid form.
#   ./install.sh            stage + print the steps
#   ./install.sh cleanup    also print the removal of the old Readarr/Calibre setup
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
stage_smb=${STAGE:-/mnt/nasfrutuozo/temporary/barch-books}
stage_srv=/mnt/user/temporary/barch-books
tpl=/boot/config/plugins/dockerMan/templates-user

[ -d "$APPDATA" ] || { echo "install: $APPDATA not found (is the appdata share mounted?)" >&2; exit 1; }
for f in "$here"/templates/*.xml; do
  python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$f"
done

mkdir -p "$stage_smb"
cp "$here"/templates/*.xml "$stage_smb/"
pk=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/prowlarr/config.xml" 2>/dev/null || true)
if [ -n "$pk" ]; then
  python3 - "$stage_smb/shelfmark.xml" "$pk" <<'PY'
import re, sys
p, key = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r'(Target="PROWLARR_API_KEY"[^>]*>)[^<]*(<)', lambda m: m.group(1) + key + m.group(2), s)
open(p, "w").write(s)
PY
  echo "templates staged in $stage_smb (Prowlarr key filled in)"
else
  echo "templates staged in $stage_smb (Prowlarr key not found: paste it in the form)"
fi

if [ "${1:-}" = cleanup ]; then
  cat <<'EOF'

1. The old setup, on Unraid as root (stop and remove the containers in the Docker tab first:
   readarr, calibre, calibre-web), then:
  rm -rf /mnt/user/appdata/readarr /mnt/user/appdata/calibre /mnt/user/appdata/calibre-web
  rm -f  /boot/config/plugins/dockerMan/templates-user/my-readarr.xml \
         /boot/config/plugins/dockerMan/templates-user/my-calibre.xml \
         /boot/config/plugins/dockerMan/templates-user/my-calibre-web.xml
  rm -rf /mnt/user/downloads/torrents/completed/books/readarr \
         /mnt/user/downloads/calibre-import /mnt/user/downloads/calibre-export
  rm -f  /mnt/user/appdata/swag/nginx/proxy-confs/readarr.subdomain.conf
   In qBittorrent: delete the torrents of the readarr category (with files) and the category.
EOF
fi

cat <<EOF

2. On Unraid as root, once (folders for user 99:100, the templates into the Docker tab):
  mkdir -p /mnt/user/media/books /mnt/user/media/audiobooks /mnt/user/downloads/torrents/books-ingest \\
           /mnt/user/downloads/torrents/completed/books /mnt/user/downloads/torrents/completed/audiobooks \\
           /mnt/user/appdata/calibre-web-automated /mnt/user/appdata/shelfmark /mnt/user/appdata/audiobookshelf
  chown 99:100 /mnt/user/media/books /mnt/user/media/audiobooks /mnt/user/downloads/torrents/books-ingest \\
           /mnt/user/downloads/torrents/completed/books /mnt/user/downloads/torrents/completed/audiobooks \\
           /mnt/user/appdata/calibre-web-automated /mnt/user/appdata/shelfmark /mnt/user/appdata/audiobookshelf
  for t in calibre-web-automated audiobookshelf shelfmark; do
    install -m 600 $stage_srv/\$t.xml $tpl/my-\$t.xml
  done
  rm -rf $stage_srv

3. Docker > Add Container > Template: in this order (Shelfmark reads Calibre-Web-Automated's app.db,
   which must exist before it starts, or Docker creates a folder in its place):
   calibre-web-automated -> Apply; open http://100.100.0.10:8083 (admin / admin123), change the password
   audiobookshelf        -> Apply; open http://100.100.0.10:13378, create the root user, a "Audiobooks"
                            library on /audiobooks; Settings > Users > you > API Token
   shelfmark             -> fill in HARDCOVER_API_KEY, SLSKD_API_KEY, AUDIOBOOKSHELF_TOKEN, Apply;
                            log in with the Calibre-Web-Automated user

4. SWAG: library.frutuozo.com.br points at the old container; in
   /mnt/user/appdata/swag/nginx/proxy-confs/calibre-web.subdomain.conf set
   \$upstream_app calibre-web-automated, then: docker exec swag nginx -s reload
EOF
