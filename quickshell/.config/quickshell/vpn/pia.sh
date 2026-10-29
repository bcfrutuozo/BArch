#!/usr/bin/env bash
# pia.sh — Private Internet Access over WireGuard, through NetworkManager, without root.
#
#   pia.sh connect [REGION|auto]   register a fresh WireGuard key with PIA and bring the tunnel up
#                                  (default: the saved region, see `region`; auto = lowest latency)
#   pia.sh disconnect              tunnel down
#   pia.sh status                  JSON: state (unconfigured|disconnected|connecting|connected),
#                                  region, name, country, ip, since, preferred, error
#   pia.sh regions                 JSON list of regions (id, name, country, geo, pf, latency)
#   pia.sh region [ID|auto]        show or save the preferred region
#   pia.sh latency                 measure the latency to every region (what "auto" uses, cached 1 h)
#
# How it works (the same flow as PIA's own manual-connections scripts): a token from the PIA API
# (username + password, cached 23 h), a new X25519 key pair per connection, the public key
# registered on the chosen server (https://<server>:1337/addKey, PIA's CA next to this file), and
# the answer (server key, endpoint, our address, DNS) written into a NetworkManager WireGuard
# profile named "pia" that belongs to this user (connection.permissions), so nmcli can create,
# change and activate it with the session's polkit rights, no password. DNS is exclusive while
# connected (dns-priority -1) and IPv6 is routed into the tunnel, where PIA drops it, so neither
# leaks. The profile never autoconnects: PIA forgets the key after a while, every connection
# registers a new one.
#
# Files: ~/.config/pia/credentials (two lines: username, password; chmod 600; NOT in the repo),
#        ~/.local/state/barch/pia/ (token, server list, latencies, preferred region, current tunnel).
# Needs: curl, jq, nmcli (NetworkManager ≥ 1.42 for wireguard.peers), python3 with cryptography
#        (or wireguard-tools) for the key pair.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ca="$here/ca.rsa.4096.crt"
creds="${XDG_CONFIG_HOME:-$HOME/.config}/pia/credentials"
state="${XDG_STATE_HOME:-$HOME/.local/state}/barch/pia"
con=pia                                  # NetworkManager connection and interface name
servers_url=https://serverlist.piaservers.net/vpninfo/servers/v6
token_url=https://www.privateinternetaccess.com/api/client/v2/token
status_url=https://www.privateinternetaccess.com/api/client/status
lat_max=0.6                              # s: regions slower than this are left out of "auto"
umask 077
mkdir -p "$state"

log() { logger -t barch-pia -- "$*"; }
fail() {
  echo "pia: $*" >&2
  printf '%s' "$*" > "$state/error"
  echo disconnected > "$state/state"
  log "error: $*"
  exit 1
}

# ---------------------------------------------------------------- PIA API
servers() {   # the server list, cached for a day (the file is JSON on the first line + a signature)
  local f="$state/servers.json" body
  if [[ ! -s $f ]] || (( $(date +%s) - $(stat -c %Y "$f") > 86400 )); then
    if body=$(curl -sf --max-time 15 "$servers_url"); then
      jq -c . <<<"${body%%$'\n'*}" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    [[ -s $f ]] || fail "could not download the PIA server list"
  fi
  cat "$f"
}

region_json() {   # region_json <id> -> the region's record (with wg servers) or failure
  servers | jq -ce --arg id "$1" '.regions[] | select(.id == $id and .servers.wg != null)'
}

latency() {   # TCP connect time to each region's meta server, in parallel -> latency.json
  # bash -c: $0 = timeout, then xargs appends "<id> <ip>" as $1 $2; unreachable regions are skipped
  { servers | jq -r '.regions[] | select(.servers.wg != null) | "\(.id) \(.servers.meta[0].ip)"' \
      | xargs -P 48 -L 1 bash -c 't=$(curl -o /dev/null -s --connect-timeout "$0" -w "%{time_connect}" "http://$2:443") && echo "$1 $t"' "$lat_max" 2>/dev/null || true; } \
    | jq -Rn '[inputs | split(" ") | select(length == 2 and .[1] != "0.000000") | {key: .[0], value: (.[1] | tonumber)}] | from_entries' \
    > "$state/latency.json.tmp" && mv "$state/latency.json.tmp" "$state/latency.json"
}
latencies() { cat "$state/latency.json" 2>/dev/null || echo '{}'; }

best_region() {   # lowest latency among the regions PIA itself uses for "auto"
  local f="$state/latency.json"
  if [[ ! -s $f ]] || (( $(date +%s) - $(stat -c %Y "$f") > 3600 )); then latency; fi
  servers | jq -re --argjson lat "$(latencies)" \
    '[.regions[] | select(.servers.wg != null and .auto_region and ($lat[.id] != null)) | {id, l: $lat[.id]}] | min_by(.l) | .id' \
    || fail "no region answered the latency test (offline?)"
}

preferred() { cat "$state/region" 2>/dev/null || echo auto; }

token() {   # cached for 23 h; PIA tokens last 24 h
  local f="$state/token" user pass t
  if [[ -s $f ]] && (( $(date +%s) - $(stat -c %Y "$f") < 82800 )); then cat "$f"; return; fi
  [[ -r $creds ]] || fail "no credentials: put the PIA username and password, one per line, in $creds (chmod 600)"
  { read -r user; read -r pass; } < "$creds"
  t=$(curl -sf --max-time 15 --form "username=$user" --form "password=$pass" "$token_url" | jq -r '.token // empty') || t=""
  [[ -n $t ]] || fail "PIA did not give a token (wrong credentials in $creds, or no network)"
  printf '%s' "$t" > "$f"
  cat "$f"
}

keypair() {   # prints the private key, then the public key (base64, WireGuard format)
  if command -v wg >/dev/null; then
    local priv; priv=$(wg genkey); echo "$priv"; wg pubkey <<<"$priv"; return
  fi
  python3 -I - <<'PY'
import base64
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
k = X25519PrivateKey.generate()
print(base64.b64encode(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())).decode())
print(base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode())
PY
}

add_key() {   # add_key <cn> <ip> <token> <pubkey> -> PIA's JSON answer (status, server_key, ...)
  curl -sf --max-time 15 -G --connect-to "$1::$2:" --cacert "$ca" \
    --data-urlencode "pt=$3" --data-urlencode "pubkey=$4" "https://$1:1337/addKey"
}

# ---------------------------------------------------------------- NetworkManager
nm_active() { nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$con"; }
nm_exists() { nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$con"; }

# ---------------------------------------------------------------- commands
connect() {
  local want=${1:-} id rj name country cn ip tok priv pub resp server_key server_ip server_port peer_ip dns auto=false
  [[ -r $creds ]] || fail "no credentials: put the PIA username and password, one per line, in $creds (chmod 600)"
  [[ -n $want ]] || want=$(preferred)
  echo connecting > "$state/state"; rm -f "$state/error"; echo $$ > "$state/pid"
  if [[ $want == auto ]]; then auto=true; id=$(best_region); else id=$want; fi
  rj=$(region_json "$id") || fail "unknown region: $id (see: pia.sh regions)"
  name=$(jq -r .name <<<"$rj"); country=$(jq -r .country <<<"$rj")
  cn=$(jq -r '.servers.wg[0].cn' <<<"$rj"); ip=$(jq -r '.servers.wg[0].ip' <<<"$rj")
  jq -n --arg id "$id" --arg name "$name" --arg country "$country" --arg server "$cn" --argjson auto "$auto" \
    '{region: $id, name: $name, country: $country, server: $server, auto: $auto}' > "$state/current.json"
  log "connecting to $name ($cn, $ip)"

  tok=$(token)
  { read -r priv; read -r pub; } < <(keypair)
  resp=$(add_key "$cn" "$ip" "$tok" "$pub") || resp=""
  if [[ $(jq -r '.status // empty' <<<"$resp" 2>/dev/null) != OK ]]; then
    rm -f "$state/token"                   # expired or revoked token: once more with a fresh one
    tok=$(token)
    resp=$(add_key "$cn" "$ip" "$tok" "$pub") || fail "could not reach $name ($cn:1337) to register the key"
    [[ $(jq -r '.status // empty' <<<"$resp") == OK ]] || fail "PIA refused the key: $(jq -r '.message // .status // "no answer"' <<<"$resp")"
  fi
  server_key=$(jq -r .server_key <<<"$resp"); server_ip=$(jq -r .server_ip <<<"$resp")
  server_port=$(jq -r .server_port <<<"$resp"); peer_ip=$(jq -r .peer_ip <<<"$resp")
  dns=$(jq -r '.dns_servers[0] // "10.0.0.243"' <<<"$resp")

  # the profile: owned by this user (no root needed), never autoconnects (the key is per session)
  local props=(
    wireguard.private-key "$priv"
    wireguard.peers "$server_key endpoint=$server_ip:$server_port allowed-ips=0.0.0.0/0;::/0 persistent-keepalive=25"
    ipv4.method manual ipv4.addresses "$peer_ip/32" ipv4.dns "$dns" ipv4.dns-priority -1
    ipv6.method link-local connection.autoconnect no
  )
  if nm_exists; then
    nmcli connection modify "$con" "${props[@]}" >/dev/null || fail "NetworkManager refused to update the profile '$con'"
  else
    nmcli connection add type wireguard con-name "$con" ifname "$con" connection.permissions "user:$USER" "${props[@]}" >/dev/null \
      || fail "NetworkManager refused to create the profile '$con'"
  fi
  nm_active && nmcli connection down "$con" >/dev/null 2>&1
  nmcli --wait 25 connection up "$con" >/dev/null 2>&1 || fail "could not bring the tunnel up (nmcli connection up $con)"

  jq --arg since "$(date +%s)" '. + {since: ($since | tonumber)}' "$state/current.json" > "$state/current.json.tmp" && mv "$state/current.json.tmp" "$state/current.json"
  echo connected > "$state/state"
  log "connected to $name"
  # the public IP, in the background (it needs the tunnel)
  ( pip=$(curl -sf --max-time 6 "$status_url" | jq -r '.ip // empty') && [[ -n $pip ]] \
      && jq --arg ip "$pip" '. + {ip: $ip}' "$state/current.json" > "$state/current.json.tmp" && mv "$state/current.json.tmp" "$state/current.json" ) >/dev/null 2>&1 &
  disown
  echo "connected: $name"
}

disconnect() {
  nm_exists && nmcli connection down "$con" >/dev/null 2>&1 || true
  echo disconnected > "$state/state"; rm -f "$state/current.json" "$state/pid"
  log "disconnected"
  echo disconnected
}

status() {
  local st=disconnected cur='{}' err pid
  if nm_active; then
    st=connected; cur=$(cat "$state/current.json" 2>/dev/null || echo '{}')
  elif [[ $(cat "$state/state" 2>/dev/null) == connecting ]] && pid=$(cat "$state/pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null; then
    st=connecting; cur=$(cat "$state/current.json" 2>/dev/null || echo '{}')
  fi
  [[ -r $creds ]] || st=unconfigured
  err=$(cat "$state/error" 2>/dev/null || true)
  jq -n --arg state "$st" --arg error "$err" --arg preferred "$(preferred)" --argjson current "$cur" \
    '{state: $state, error: $error, preferred: $preferred} + $current'
}

regions() {   # for the menu: fastest first, unmeasured at the end
  servers | jq -c --argjson lat "$(latencies)" \
    '[.regions[] | select(.servers.wg != null)
      | {id, name, country, geo, pf: .port_forward, auto: .auto_region, latency: ($lat[.id] // null)}]
     | sort_by((.latency // 9), .name)'
}

region() {
  if [[ -z ${1:-} ]]; then preferred; return; fi
  [[ $1 == auto ]] || region_json "$1" >/dev/null || fail "unknown region: $1 (see: pia.sh regions)"
  printf '%s' "$1" > "$state/region"
  echo "$1"
}

case ${1:-} in
  connect) connect "${2:-}" ;;
  disconnect) disconnect ;;
  status) status ;;
  regions) regions ;;
  region) region "${2:-}" ;;
  latency) latency; latencies ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
