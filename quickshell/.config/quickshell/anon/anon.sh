#!/usr/bin/env bash
# anon.sh — Anonymous Mode: the VPN plus what else on this machine would still give it away.
#
#   anon.sh on [REGION|auto]   mode on: Mullvad Browser becomes the default browser, no network
#                              profile sends the hostname over DHCP, then the VPN comes up
#                              (vpn/pia.sh connect). If the tunnel fails everything is rolled back.
#   anon.sh off                VPN down, the previous default browser back
#   anon.sh status             JSON: on, browser (current default), previous, mullvad (installed),
#                              webrtc (policy in place), dhcpHostname (some profile still sends it),
#                              missing (what the mode cannot cover right now), error
#
# What it covers: the public IP and DNS (the tunnel), browser fingerprint, User-Agent platform and
# WebRTC (Mullvad Browser: the Tor Browser protections without Tor, made for VPN use), the hostname
# on the local network (DHCP). The WebRTC policy of the Chromium browsers (Brave, Chromium) is
# static and lives in system/ (/etc/brave and /etc/chromium policies/managed): with the tunnel up
# they only expose the tunnel's address, never a LAN one. What it cannot cover: accounts you are
# logged into, apps that send the device name, and the trust in PIA itself.
# The VPN state is pia.sh's; this script only adds the browser and the DHCP bit around it.
#
# Files: ~/.local/state/barch/anon/ (state, browser.prev, error).
# Needs: xdg-settings (xdg-utils), nmcli, jq, and vpn/pia.sh next to this folder.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pia="$here/../vpn/pia.sh"
state="${XDG_STATE_HOME:-$HOME/.local/state}/barch/anon"
webrtc_policy=default_public_interface_only
umask 077
mkdir -p "$state"

log() { logger -t barch-anon -- "$*"; }
fail() {
  echo "anon: $*" >&2
  printf '%s' "$*" > "$state/error"
  log "error: $*"
  exit 1
}

is_on() { [[ $(cat "$state/state" 2>/dev/null) == on ]]; }

# ---------------------------------------------------------------- browser
default_browser() { xdg-settings get default-web-browser 2>/dev/null || true; }
mullvad_desktop() {   # the .desktop name of Mullvad Browser, empty if it is not installed
  local f
  f=$(grep -ls '^Exec=.*mullvad-browser' "${XDG_DATA_HOME:-$HOME/.local/share}"/applications/*.desktop \
        /usr/local/share/applications/*.desktop /usr/share/applications/*.desktop 2>/dev/null | head -1) || true
  [[ -n $f ]] && basename "$f"
}
browser_on() {   # Mullvad Browser as default, remembering what was there (only once)
  local md cur
  md=$(mullvad_desktop) || true
  [[ -n $md ]] || { log "Mullvad Browser is not installed: default browser left alone"; return 0; }
  cur=$(default_browser)
  if [[ $cur != "$md" ]]; then
    [[ -s $state/browser.prev ]] || printf '%s' "$cur" > "$state/browser.prev"
    xdg-settings set default-web-browser "$md" || fail "could not make $md the default browser (xdg-settings)"
    log "default browser: $md (was $cur)"
  fi
}
browser_off() {   # the previous default browser back, if the mode had changed it
  local prev cur
  prev=$(cat "$state/browser.prev" 2>/dev/null || true)
  rm -f "$state/browser.prev"
  [[ -n $prev ]] || return 0
  cur=$(default_browser)
  [[ $cur == "$(mullvad_desktop)" ]] || return 0      # changed by hand since: respect it
  xdg-settings set default-web-browser "$prev" || fail "could not restore $prev as the default browser"
  log "default browser: $prev"
}

# ---------------------------------------------------------------- network
lan_connections() {   # NetworkManager profiles that talk DHCP to the local network
  nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 == "802-3-ethernet" || $2 == "802-11-wireless" { print $1 }'
}
sends_hostname() {   # sends_hostname <profile>: 0 unless both IPv4 and IPv6 DHCP have it off (nmcli -g prints 0 = no, 1 = yes, -1 = default)
  local v
  v=$(nmcli -g ipv4.dhcp-send-hostname,ipv6.dhcp-send-hostname connection show "$1" 2>/dev/null | tr '\n' ' ')
  [[ $v != "0 0 " && $v != "no no " ]]
}
dhcp_hostname_sent() {   # 0 if some profile still sends the hostname over DHCP
  local c
  while IFS= read -r c; do sends_hostname "$c" && return 0; done < <(lan_connections)
  return 1
}
dhcp_hostname_off() {   # idempotent; the profiles are system ones, polkit lets the active user change them
  local c
  while IFS= read -r c; do
    sends_hostname "$c" || continue
    if nmcli connection modify "$c" ipv4.dhcp-send-hostname no ipv6.dhcp-send-hostname no 2>/dev/null; then
      log "DHCP hostname off: $c"
    else
      log "could not change '$c' (dhcp-send-hostname)"
    fi
  done < <(lan_connections)
}
webrtc_ok() {   # the Chromium browsers only use the default route's address for WebRTC
  cat /etc/brave/policies/managed/*.json /etc/chromium/policies/managed/*.json 2>/dev/null \
    | jq -es --arg p "$webrtc_policy" 'map(.WebRtcIPHandling // empty) | index($p) != null' >/dev/null 2>&1
}

# ---------------------------------------------------------------- commands
on() {
  echo on > "$state/state"; rm -f "$state/error"
  log "on"
  browser_on
  dhcp_hostname_off
  if ! bash "$pia" connect "${1:-}"; then     # pia.sh already said why on stderr
    browser_off; echo off > "$state/state"
    log "off again: the tunnel did not come up"
    exit 1
  fi
  echo "anonymous mode on"
}

off() {
  bash "$pia" disconnect >/dev/null || true
  browser_off
  echo off > "$state/state"; rm -f "$state/error"
  log "off"
  echo "anonymous mode off"
}

status() {
  local on=false md missing=() dhcp=false webrtc=false
  is_on && on=true
  md=$(mullvad_desktop) || true
  dhcp_hostname_sent && dhcp=true
  webrtc_ok && webrtc=true
  [[ -n $md ]] || missing+=("Mullvad Browser not installed")
  [[ $webrtc == true ]] || missing+=("WebRTC policy missing (system/files/etc/*/policies)")
  [[ $dhcp == false ]] || missing+=("a network profile still sends the hostname over DHCP")
  jq -n --argjson on "$on" --arg browser "$(default_browser)" --arg previous "$(cat "$state/browser.prev" 2>/dev/null || true)" \
    --argjson mullvad "$([[ -n $md ]] && echo true || echo false)" --argjson webrtc "$webrtc" --argjson dhcp "$dhcp" \
    --arg error "$(cat "$state/error" 2>/dev/null || true)" --args \
    '{on: $on, browser: $browser, previous: $previous, mullvad: $mullvad, webrtc: $webrtc, dhcpHostname: $dhcp,
      missing: $ARGS.positional, error: $error}' "${missing[@]}"
}

case ${1:-} in
  on) on "${2:-}" ;;
  off) off ;;
  status) status ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
