#!/usr/bin/env bash
# One-time switch of a running machine from NetworkManager to systemd-networkd + iwd +
# systemd-resolved (docs/network.md), and back. Run as root: sudo ./scripts/network-switch.sh apply
#
#   apply    installs the network files of system/ (networkd, iwd, resolved, wait-online, barch-net
#            with its unit and polkit rule), copies the Wi-Fi passwords of NetworkManager's profiles
#            into /var/lib/iwd, stops and disables NetworkManager, points /etc/resolv.conf at
#            resolved's stub and starts resolved, iwd and networkd. The network drops for a few
#            seconds; run it from a terminal you can still use without it (a TTY is safest).
#   revert   networkd, iwd and resolved off, the old /etc/resolv.conf back, NetworkManager on again.
#            The files stay (unused while networkd is off), so apply can run again.
#
# A fresh install does not need this: INSTALL.md installs iwd instead of NetworkManager and
# apply-system.sh puts the same files in place.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $EUID == 0 ]] || die "run as root: sudo $0 ${1:-apply|revert}"
src="$REPO/system/files"
files=(
  /etc/systemd/network/20-wired.network
  /etc/systemd/network/25-wireless.network
  /etc/iwd/main.conf
  /etc/systemd/resolved.conf.d/barch.conf
  /etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf
  /etc/systemd/system/barch-net@.service
  /etc/polkit-1/rules.d/50-barch-net.rules
  /usr/local/bin/barch-net
)

iwd_name() {   # iwd's file name for an SSID: the SSID itself when it is plain, else = + hex
  if [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; then echo "$1"; else printf '=%s' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"; fi
}

migrate_wifi() {   # NetworkManager's Wi-Fi profiles -> /var/lib/iwd/<name>.psk|.open
  command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager || { warn "NetworkManager not running: no Wi-Fi profiles to copy"; return 0; }
  install -d -m 700 /var/lib/iwd
  local con ssid mgmt psk name
  while IFS=: read -r type con; do         # TYPE first: the rest of the line is the name, colons and all
    [[ $type == 802-11-wireless ]] || continue
    con=${con//\\:/:}                      # nmcli -t escapes ":" inside values as "\:"
    ssid=$(nmcli -g 802-11-wireless.ssid connection show "$con")
    mgmt=$(nmcli -g 802-11-wireless-security.key-mgmt connection show "$con" 2>/dev/null || true)
    name=$(iwd_name "$ssid")
    case $mgmt in
      wpa-psk|sae)
        psk=$(nmcli -s -g 802-11-wireless-security.psk connection show "$con")
        [[ -n $psk ]] || { warn "$ssid: no password stored, skipped"; continue; }
        (umask 077; printf '[Security]\nPassphrase=%s\n' "$psk" > "/var/lib/iwd/$name.psk")
        ok "Wi-Fi $ssid -> /var/lib/iwd/$name.psk" ;;
      "")
        (umask 077; printf '[Settings]\nAutoConnect=true\n' > "/var/lib/iwd/$name.open")
        ok "Wi-Fi $ssid (open) -> /var/lib/iwd/$name.open" ;;
      *) warn "$ssid: $mgmt is not copied (enterprise or WEP): join it again with iwctl" ;;
    esac
  done < <(nmcli -t -f TYPE,NAME connection show)
}

case ${1:-} in
  apply)
    pacman -Q iwd >/dev/null 2>&1 || die "iwd is not installed: pacman -S iwd first"
    step "Files"
    for f in "${files[@]}"; do
      m=$(awk -v f="$f" '$2 == f { print $1; exit }' "$REPO/system/modes.txt")
      install -D -m "${m:-644}" "$src$f" "$f" && ok "$f"
    done
    systemctl daemon-reload
    step "Wi-Fi passwords"
    migrate_wifi
    step "NetworkManager off"
    systemctl disable --now NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service 2>/dev/null || true
    systemctl stop wpa_supplicant.service 2>/dev/null || true       # NM's helper, holding the Wi-Fi card
    ok "stopped and disabled"
    step "resolved, iwd, networkd"
    if [[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then cp -a /etc/resolv.conf /etc/resolv.conf.networkmanager; fi
    systemctl enable --now systemd-resolved.service
    ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    # resolved read the old resolv.conf when it started and keeps its servers as "global" ones, used
    # next to every link (and next to the VPN): a restart after the link drops them
    systemctl restart systemd-resolved.service
    systemctl enable --now iwd.service systemd-networkd.service
    networkctl reload                     # a second run: networkd already up, with the files just installed
    systemctl enable --now systemd-networkd-wait-online.service || warn "wait-online failed (see below)"
    if /usr/lib/systemd/systemd-networkd-wait-online --any --operational-state=routable --timeout=40; then
      ok "online"
    else
      warn "no link routable after 40 s: networkctl, journalctl -u systemd-networkd -u iwd (revert: $0 revert)"
    fi
    networkctl list --no-pager || true
    resolvectl status --no-pager | grep -E "^Link|Current DNS|DNS Servers|DNS Domain" || true
    getent hosts archlinux.org >/dev/null && ok "DNS answers" || warn "DNS does not answer yet"
    ;;
  revert)
    step "networkd, iwd, resolved off"
    systemctl disable --now systemd-networkd-wait-online.service systemd-networkd.service systemd-networkd.socket \
      systemd-networkd-varlink.socket systemd-networkd-resolve-hook.socket iwd.service 2>/dev/null || true
    if [[ -L /etc/resolv.conf ]]; then
      rm -f /etc/resolv.conf
      [[ -e /etc/resolv.conf.networkmanager ]] && mv /etc/resolv.conf.networkmanager /etc/resolv.conf
    fi
    systemctl disable --now systemd-resolved.service 2>/dev/null || true
    step "NetworkManager on"
    systemctl enable --now NetworkManager.service NetworkManager-wait-online.service
    nm-online -t 40 >/dev/null 2>&1 && ok "online" || warn "NetworkManager is not online yet (nmcli device)"
    ;;
  *) echo "usage: sudo $0 apply|revert" >&2; exit 2 ;;
esac
