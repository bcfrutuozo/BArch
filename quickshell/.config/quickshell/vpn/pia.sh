#!/usr/bin/env bash
# pia.sh — Private Internet Access over WireGuard, through systemd-networkd.
#
#   pia.sh connect [REGION|auto]   register a fresh WireGuard key with PIA and bring the tunnel up
#                                  (default: the saved region, see `region`; auto = lowest latency)
#   pia.sh disconnect              tunnel down
#   pia.sh status                  JSON: state (unconfigured|disconnected|connecting|connected),
#                                  region, name, country, ip, since, preferred, error, stopped
#                                  (when `disconnect` last ran: a tunnel that goes away after it
#                                  was turned off, not one that dropped; barch-events tells them apart)
#   pia.sh regions                 JSON list of regions (id, name, country, geo, pf, latency)
#   pia.sh region [ID|auto]        show or save the preferred region
#   pia.sh latency                 measure the latency to every region (what "auto" uses, cached 1 h)
#
# How it works (the same flow as PIA's own manual-connections scripts): a token from the PIA API
# (username + password, cached 23 h), a new X25519 key pair per connection, the public key
# registered on the chosen server (https://<server>:1337/addKey, PIA's CA next to this file), and
# the answer (server key, endpoint, our address, DNS) handed to /usr/local/bin/barch-net, the root
# helper that writes the tunnel "pia" for systemd-networkd into /run (barch-net@<op>_$USER.service,
# which polkit lets this user start without a password). The private key is made by that helper and
# never leaves root and networkd; this script only sees the public one. DNS is exclusive while
# connected (the tunnel takes "~.", the LAN links lose their DNS) and IPv6 is routed into the
# tunnel, where PIA drops it, so neither leaks. Nothing autoconnects or survives a boot: PIA
# forgets the key after a while, every connection registers a new one. While Anonymous Mode's kill switch is armed (anon/anon.sh, table
# inet barch-killswitch), a region change re-arms it for the new server before the tunnel moves,
# so the new handshake is let through; the API calls before that go through the current tunnel.
#
# Files: ~/.config/pia/credentials (two lines: username, password; chmod 600; NOT in the repo),
#        ~/.local/state/barch/pia/ (token, server list, latencies, preferred region, current tunnel).
# Needs: curl, jq, systemctl, and barch-net with its unit and polkit rule (system/files).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ca="$here/ca.rsa.4096.crt"
creds="${XDG_CONFIG_HOME:-$HOME/.config}/pia/credentials"
state="${XDG_STATE_HOME:-$HOME/.local/state}/barch/pia"
con=pia                                  # the WireGuard interface barch-net creates
request="${XDG_RUNTIME_DIR:-/run/user/$UID}/barch-net/vpn.json"   # what barch-net vpn-up reads
pubkey=/run/barch-net/pia.pub            # written by barch-net vpn-key
servers_url=https://serverlist.piaservers.net/vpninfo/servers/v6
token_url=https://www.privateinternetaccess.com/api/client/v2/token
status_url=https://www.privateinternetaccess.com/api/client/status
lat_max=0.6                              # s: regions slower than this are left out of "auto"
ks_state=/run/barch-killswitch/state.json  # written by /usr/local/bin/barch-killswitch (root)
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

net_helper() {   # net_helper <op>: barch-net@<op>_$USER.service (root, see /usr/local/bin/barch-net)
  systemctl start --no-ask-password "barch-net@${1}_$USER.service"
}

add_key() {   # add_key <cn> <ip> <token> <pubkey> -> PIA's JSON answer (status, server_key, ...)
  curl -sf --max-time 15 -G --connect-to "$1::$2:" --cacert "$ca" \
    --data-urlencode "pt=$3" --data-urlencode "pubkey=$4" "https://$1:1337/addKey"
}

# ---------------------------------------------------------------- kill switch (Anonymous Mode)
ks_armed() { jq -e '.armed == true' "$ks_state" >/dev/null 2>&1; }
ks_rearm() {   # ks_rearm <server ip> <port>: let the new endpoint through before the tunnel moves
  if systemctl start --no-ask-password "barch-killswitch@on_${1}_${2}.service" >/dev/null 2>&1; then
    log "kill switch re-armed for $1:$2"
  else
    log "could not re-arm the kill switch for $1:$2"
  fi
}

# ---------------------------------------------------------------- the tunnel
# the link exists and is administratively up: `networkctl down pia` (or a dying tunnel) leaves the
# link in place, and "connected" then would hide the orange "kill switch holding" shield
tunnel_up() { local f; f=$(cat "/sys/class/net/$con/flags" 2>/dev/null) && (( f & 1 )); }

# ---------------------------------------------------------------- commands
connect() {
  local want=${1:-} id rj name country cn ip tok pub resp server_key server_ip server_port peer_ip dns auto=false
  [[ -r $creds ]] || fail "no credentials: put the PIA username and password, one per line, in $creds (chmod 600)"
  [[ -n $want ]] || want=$(preferred)
  # already up in that region (Anonymous Mode turned on over a running VPN, `barch vpn on` twice):
  # keep the tunnel. Registering a new key means calling the server's own API (port 1337) from
  # inside its tunnel, which never answers, and the fresh token asked for after that failed too
  # (2026-11-02 15:06: Anonymous Mode off again, "PIA did not give a token")
  if tunnel_up && [[ -s $state/current.json ]] \
    && jq -e --arg w "$want" '(.region == $w) or ($w == "auto" and .auto == true)' "$state/current.json" >/dev/null 2>&1; then
    rm -f "$state/error"
    log "already connected to $(jq -r .name "$state/current.json"); keeping the tunnel"
    echo "connected: $(jq -r .name "$state/current.json")"
    return 0
  fi
  echo connecting > "$state/state"; rm -f "$state/error"; echo $$ > "$state/pid"
  if [[ $want == auto ]]; then auto=true; id=$(best_region); else id=$want; fi
  rj=$(region_json "$id") || fail "unknown region: $id (see: pia.sh regions)"
  name=$(jq -r .name <<<"$rj"); country=$(jq -r .country <<<"$rj")
  cn=$(jq -r '.servers.wg[0].cn' <<<"$rj"); ip=$(jq -r '.servers.wg[0].ip' <<<"$rj")
  jq -n --arg id "$id" --arg name "$name" --arg country "$country" --arg server "$cn" --argjson auto "$auto" \
    '{region: $id, name: $name, country: $country, server: $server, auto: $auto}' > "$state/current.json"
  log "connecting to $name ($cn, $ip)"

  tok=$(token)
  net_helper vpn-key || fail "could not make a WireGuard key (barch-net@vpn-key_$USER.service)"
  pub=$(cat "$pubkey" 2>/dev/null) || fail "no public key in $pubkey"
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

  # the request barch-net vpn-up reads (it validates every field before writing anything)
  mkdir -p "$(dirname "$request")"
  jq -n --arg k "$server_key" --arg ip "$server_ip" --argjson port "$server_port" --arg peer "$peer_ip" --arg dns "$dns" \
    '{server_key: $k, server_ip: $ip, server_port: $port, peer_ip: $peer, dns: $dns}' > "$request"
  jq --arg sip "$server_ip" --argjson sport "$server_port" '. + {server_ip: $sip, server_port: $sport}' "$state/current.json" > "$state/current.json.tmp" && mv "$state/current.json.tmp" "$state/current.json"
  ks_armed && ks_rearm "$server_ip" "$server_port"
  net_helper vpn-up || fail "could not bring the tunnel up (journalctl -u 'barch-net@vpn-up_$USER')"
  rm -f "$request"
  # "connected" only once traffic really takes the tunnel: networkd applies the rules a moment later
  for _ in {1..20}; do
    [[ $(ip -o route get 1.1.1.1 2>/dev/null) == *" dev pia "* ]] && break
    sleep 0.25
  done
  if [[ $(ip -o route get 1.1.1.1 2>/dev/null) != *" dev pia "* ]]; then
    net_helper vpn-down >/dev/null 2>&1 || true
    fail "the tunnel came up but traffic does not go through it (ip rule; ip route get 1.1.1.1)"
  fi

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
  net_helper vpn-down >/dev/null 2>&1 || log "barch-net vpn-down failed (journalctl -u 'barch-net@vpn-down_$USER')"
  echo disconnected > "$state/state"; rm -f "$state/current.json" "$state/pid"
  date +%s > "$state/stopped"
  log "disconnected"
  echo disconnected
}

status() {
  local st=disconnected cur='{}' err pid
  if tunnel_up; then
    st=connected; cur=$(cat "$state/current.json" 2>/dev/null || echo '{}')
  elif [[ $(cat "$state/state" 2>/dev/null) == connecting ]] && pid=$(cat "$state/pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null; then
    st=connecting; cur=$(cat "$state/current.json" 2>/dev/null || echo '{}')
  fi
  [[ -r $creds ]] || st=unconfigured
  err=$(cat "$state/error" 2>/dev/null || true)
  jq -n --arg state "$st" --arg error "$err" --arg preferred "$(preferred)" --argjson current "$cur" \
    --argjson stopped "$(cat "$state/stopped" 2>/dev/null || echo 0)" \
    '{state: $state, error: $error, preferred: $preferred, stopped: $stopped} + $current'
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
