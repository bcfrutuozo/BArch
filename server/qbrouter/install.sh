#!/usr/bin/env bash
# Prepares (or updates) qbittorrent-private and barch-qbrouter on the NAS over the appdata and temporary shares:
#
#   app        -> appdata/barch-qbrouter/app/barch_qbrouter   (replaced on every run, tests first)
#   settings   -> appdata/barch-qbrouter/config.json          (only when missing: the routes live there)
#   secrets    -> appdata/barch-qbrouter/secrets.json         (only when missing: Prowlarr's key from its config.xml)
#   qBittorrent.conf -> appdata/qbittorrent-private/qBittorrent/ (only before its first start: paths, port 6882,
#                 no DHT/PeX/LSD, whitelist, SWAG trusted, a new password kept in ~/.config/barch/qbittorrent-private.json)
#   staged     -> temporary/barch-qbrouter: the two Unraid templates, the s6 scripts, the SWAG proxy-conf with the
#                 real domain (read from qbittorrent.subdomain.conf; the repo only has example.com)
#
# Nothing runs on the server by itself: what needs root, the Unraid UI, DNS or pfSense is printed at the end.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPDATA=${APPDATA:-/mnt/nasfrutuozo/appdata}
stage_smb=${STAGE:-/mnt/nasfrutuozo/temporary/barch-qbrouter}
stage_srv=/mnt/user/temporary/barch-qbrouter
tpl=/boot/config/plugins/dockerMan/templates-user
creds=$HOME/.config/barch/qbittorrent-private.json

[ -d "$APPDATA" ] || { echo "install: $APPDATA not found (is the appdata share mounted?)" >&2; exit 1; }
python3 -m unittest discover -s "$here/tests" -q 2>&1 | tail -1
for f in "$here"/templates/*.xml; do python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$f"; done

# ---- the router's code and settings ----
# Once the container ran, its folder belongs to it (99:100, not readable over the share): the code is then
# staged with the rest and root copies it (printed at the end).
dst=$APPDATA/barch-qbrouter
fresh=0
if [ ! -e "$dst" ]; then
  fresh=1
  mkdir -p "$dst/app"
  cp -r "$here/barch_qbrouter" "$dst/app/barch_qbrouter"
  find "$dst/app/barch_qbrouter" -name __pycache__ -prune -exec rm -rf {} +
  cp "$here/deploy/config.example.json" "$dst/config.json"
  pk=$(grep -oP '(?<=<ApiKey>)[^<]+' "$APPDATA/prowlarr/config.xml" 2>/dev/null || true)
  (umask 077; jq -n --arg p "$pk" '{prowlarr_api_key: $p, backends: {vpn: {username: "", password: ""},
                                     private: {username: "", password: ""}}}' > "$dst/secrets.json")
  echo "qbrouter: app, config.json and secrets.json written to $dst$([ -n "$pk" ] || echo " (Prowlarr key not found: fill in prowlarr_api_key)")"
fi

# ---- qbittorrent-private's configuration, before its first start ----
qconf=$APPDATA/qbittorrent-private/qBittorrent/qBittorrent.conf
if [ -e "$qconf" ]; then
  echo "qbittorrent-private: qBittorrent.conf exists, left as it is (change it in its web UI)"
else
  mkdir -p "$(dirname "$qconf")"
  pw=$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')
  hash=$(python3 -c 'import base64, hashlib, os, sys
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha512", sys.argv[1].encode(), salt, 100000, 64)
print(base64.b64encode(salt).decode() + ":" + base64.b64encode(dk).decode())' "$pw")
  sed -e "s|@USERNAME@|admin|" -e "s|@PBKDF2@|$hash|" "$here/deploy/qbittorrent-private.conf" > "$qconf"
  mkdir -p "$(dirname "$creds")"
  (umask 077; jq -n --arg p "$pw" '{url: "http://100.100.0.10:8095", username: "admin", password: $p}' > "$creds")
  echo "qbittorrent-private: qBittorrent.conf seeded; web UI login admin / the password in $creds"
fi

# ---- staged for root: templates, s6 scripts, SWAG ----
domain=$(grep -oP 'server_name\s+downloader\.\K[^;]+' "$APPDATA/swag/nginx/proxy-confs/qbittorrent.subdomain.conf" 2>/dev/null || true)
rm -rf "$stage_smb"
mkdir -p "$stage_smb"
cp "$here"/templates/*.xml "$stage_smb/"
mkdir -p "$stage_smb/app"
cp -r "$here/barch_qbrouter" "$stage_smb/app/"
find "$stage_smb/app" -name __pycache__ -prune -exec rm -rf {} +
cp -r "$here/deploy/custom-cont-init.d" "$here/deploy/custom-services.d" "$stage_smb/"
if [ -n "$domain" ]; then
  sed "s|downloader-private\.example\.com|downloader-private.$domain|" "$here/deploy/qbittorrent-private.subdomain.conf" \
    > "$stage_smb/qbittorrent-private.subdomain.conf"
  echo "staged in $stage_smb (SWAG: downloader-private.$domain)"
else
  echo "staged in $stage_smb (domain not found in qbittorrent.subdomain.conf: SWAG conf not staged)"
fi
host=downloader-private.${domain:-example.com}

# ---- qbittorrent-private mirrors the VPN client's queue, limits and categories (both reachable from here) ----
vpn_api=${VPN_API:-http://100.100.0.10:8080/api/v2}
priv_api=${PRIV_API:-http://100.100.0.10:8095/api/v2}
if vp=$(curl -sf -m 10 "$vpn_api/app/preferences") && curl -sf -m 10 "$priv_api/app/version" >/dev/null; then
  keys='{announce_to_all_trackers, auto_tmm_enabled, category_changed_tmm_enabled, save_path_changed_tmm_enabled,
         disk_queue_size, dont_count_slow_torrents, enable_piece_extent_affinity, max_active_downloads,
         max_active_torrents, max_active_uploads, max_connec, max_connec_per_torrent, max_ratio_act, max_uploads,
         max_uploads_per_torrent, queueing_enabled, reannounce_when_address_changed, up_limit, dl_limit,
         alt_up_limit, alt_dl_limit, slow_torrent_dl_rate_threshold, slow_torrent_ul_rate_threshold,
         slow_torrent_inactive_timer}'
  curl -sf -m 10 -X POST "$priv_api/app/setPreferences" --data-urlencode "json=$(jq -c "$keys" <<< "$vp")" >/dev/null
  cats=$(curl -sf -m 10 "$vpn_api/torrents/categories")
  have=$(curl -sf -m 10 "$priv_api/torrents/categories")
  for c in $(jq -r 'keys[]' <<< "$cats"); do
    ep=createCategory; jq -e --arg c "$c" 'has($c)' <<< "$have" >/dev/null && ep=editCategory
    curl -sf -m 10 -X POST "$priv_api/torrents/$ep" --data-urlencode "category=$c" \
      --data-urlencode "savePath=$(jq -r --arg c "$c" '.[$c].savePath // ""' <<< "$cats")" >/dev/null || true
  done
  echo "qbittorrent-private: queue, limits and categories copied from the VPN client"
else
  echo "qbittorrent-private: not reachable from here yet: start it, then run this again to copy the VPN client's queue/limits"
fi

if [ "$fresh" = 0 ]; then
  cat <<EOF

=== Update, in the Unraid terminal as root (paste all of it) ===
rm -rf /mnt/user/appdata/barch-qbrouter/app/barch_qbrouter
cp -r $stage_srv/app/barch_qbrouter /mnt/user/appdata/barch-qbrouter/app/
for f in custom-cont-init.d/50-qbrouter-packages custom-services.d/qbrouter; do
  install -D -m 755 -o root -g root $stage_srv/\$f /mnt/user/appdata/barch-qbrouter-init/\$f
done
c=/mnt/user/appdata/barch-qbrouter/config.json
grep -q '"private_backend"' \$c || sed -i 's/"default": "vpn",/"default": "vpn",\n  "private_backend": "private",/' \$c
chown -R 99:100 /mnt/user/appdata/barch-qbrouter
rm -rf $stage_srv
docker restart barch-qbrouter && sleep 20 && docker logs --tail 3 barch-qbrouter
EOF
  exit 0
fi

cat <<EOF

=== 1. Unraid terminal, as root (paste all of it) ===
mkdir -p /mnt/user/downloads/torrents/incomplete/private
for f in custom-cont-init.d/50-qbrouter-packages custom-services.d/qbrouter; do
  install -D -m 755 -o root -g root $stage_srv/\$f /mnt/user/appdata/barch-qbrouter-init/\$f
done
install -m 600 $stage_srv/qbittorrent-private.xml $tpl/my-qbittorrent-private.xml
install -m 600 $stage_srv/barch-qbrouter.xml      $tpl/my-barch-qbrouter.xml
install -m 644 -o 99 -g 100 $stage_srv/qbittorrent-private.subdomain.conf /mnt/user/appdata/swag/nginx/proxy-confs/
chown -R 99:100 /mnt/user/appdata/qbittorrent-private /mnt/user/appdata/barch-qbrouter /mnt/user/downloads/torrents/incomplete/private
chmod 600 /mnt/user/appdata/barch-qbrouter/secrets.json
rm -rf $stage_srv

=== 2. Unraid web UI: Docker > Add Container > Template: pick, change nothing, Apply ===
   qbittorrent-private   then check, in the Unraid terminal, the address it leaves from (the home WAN, never PIA's):
                           docker exec qbittorrent-private curl -s https://ifconfig.co
   barch-qbrouter        then: docker logs barch-qbrouter  (ends with "listening on 0.0.0.0:8080 ...")
                           docker exec barch-qbrouter wget -qO- http://127.0.0.1:8080/barch/status
                           (both backends "reachable": true)

=== 3. Domain ($host) ===
   Cloudflare: a record for downloader-private, the same kind as downloader's
   pfSense (omni): Services > DNS Resolver > Host Overrides: downloader-private -> 100.100.0.10, like downloader
   then on Unraid: docker exec swag nginx -t && docker exec swag nginx -s reload

=== 4. pfSense (omni): Firewall > NAT > Port Forward ===
   WAN, TCP/UDP, port 6882 -> 100.100.0.10 port 6882 (description: qbittorrent-private)

=== 5. Shelfmark: Settings > Downloads > qBittorrent URL = http://barch-qbrouter:8080, Test, Save ===

=== 6. Only now: SAPIbr in Prowlarr (API key; no tags at all) ===
   first grab: docker logs barch-qbrouter shows "add ... -> private (sapibr.com)", and it is in
   http://100.100.0.10:8095, not in the VPN qbittorrent
EOF
