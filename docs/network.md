# Network

systemd-networkd for addresses and routes, iwd for Wi-Fi, systemd-resolved for DNS,
systemd-timesyncd for the clock. NetworkManager is gone (2026-11-25): the pieces of the
desktop that used it (the bar's Wi-Fi and cable widgets, the PIA VPN, Anonymous Mode) talk to
these instead.

## The links

`/etc/systemd/network/` (in `system/`):

- `20-wired.network`: every `en*` port. DHCP (IPv4 and IPv6) from the pfSense, router
  advertisements, stable-privacy addresses, route metric 100.
- `25-wireless.network`: Wi-Fi, the same with metric 600, so the cable wins while both are up,
  and the address kept through a 3 s carrier loss when roaming.

- `30-virbr0.netdev`/`.network`: the VMs' bridge, 192.168.122.1/24 as libvirt had it. networkd
  creates it and serves it: DHCP (`DHCPServer=`, guests get .100–.199), NAT (`IPMasquerade=ipv4`,
  which also turns IPv4 forwarding on); systemd-resolved answers their DNS on 192.168.122.1
  (`DNSStubListenerExtra=`), with the host's servers (the tunnel's while the VPN is up). libvirt's
  network "default" only points at the bridge (`system/libvirt/default.xml`, `<forward
  mode='bridge'/>`, loaded by `apply-system.sh`), so no dnsmasq is installed. Guests are reached by
  address, not by name (dnsmasq registered their names; networkd's DHCP server does not).
  `networkctl status virbr0` lists the leases.

`systemd-networkd-wait-online` waits for **any** link to be routable (a drop-in; the links keep
the default `RequiredForOnline=yes`, with `no` it would have nothing to wait for), so the board's second Ethernet port without a cable does not hold up
`network-online.target` (the NAS mounts, Docker). Nothing else is matched: Docker's bridges
and veths, and the VMs' tap devices (vnet*) stay theirs.

iwd only joins the network (`/etc/iwd/main.conf`: `EnableNetworkConfiguration=false`); the
passwords of the networks it knows are in `/var/lib/iwd/<SSID>.psk` (root, mode 600), which
`barch-backup-root` puts in the encrypted backup and `collect-system.sh` never copies.
`iwctl` is the command line (`iwctl station wlan0 get-networks`, `connect <SSID>`).

## DNS and the clock

`/etc/resolv.conf` is resolved's stub (`/run/systemd/resolve/stub-resolv.conf`, 127.0.0.53); the
servers come per link from DHCP (the pfSense). `resolved.conf.d/barch.conf` turns off the
fallback to Cloudflare/Google/Quad9 (a lookup with no server fails rather than leaving through
someone else) and LLMNR/mDNS. `resolvectl status` shows which link answers what.

The clock: systemd-timesyncd takes the NTP server DHCP announces (`UseNTP=yes`); the pfSense
answers NTP (stratum 2, from NTP.br) and its DHCP server must list it (**Services → DHCP Server →
NTP servers**: the LAN address of the pfSense). Without that, timesyncd falls back to the Arch
pool. `timedatectl show-timesync --all | grep -E "LinkNTP|ServerName"` shows which one it uses.

## Root helper: barch-net

networkd only reads configuration root writes, so the VPN and Anonymous Mode go through
`/usr/local/bin/barch-net`, started as `barch-net@<op>_<user>.service`; polkit
(`50-barch-net.rules`) lets a wheel user start only the instances that name that same user, without
a password. Everything it writes is in `/run`, gone at boot:

| op | What |
|---|---|
| `vpn-key` | a new WireGuard key pair: private key `/run/barch-net/pia.key` (root:systemd-network 0640), public key `pia.pub` |
| `vpn-up` | the tunnel `pia` from `$XDG_RUNTIME_DIR/barch-net/vpn.json` (written by `pia.sh`, every field validated): `50-pia.netdev`/`.network` in `/run/systemd/network`, the full tunnel as `wg-quick` does it (table 51820, fwmark, `suppress_prefixlength 0`; rules at 32764/32765, before main's 32766, or nothing enters the tunnel; `pia.sh` refuses "connected" until `ip route get` goes through `pia`), DNS `~.` on the tunnel and drop-ins that take DNS away from the LAN links until `vpn-down` |
| `vpn-down` | all of that removed, the key forgotten |
| `hostname-off` / `hostname-on` | drop-ins that keep the hostname out of DHCP requests (Anonymous Mode) |

The same rule lets that user run `networkctl up/down` (the cable widget's Turn off/on).

## Moving a machine over

A fresh install has it from the start (INSTALL.md installs `iwd`, not NetworkManager;
`apply-system.sh` puts the files in place and enables the services). A running machine with
NetworkManager switches once with `sudo ./scripts/network-switch.sh apply`, best from a TTY: it
installs the files, copies the Wi-Fi passwords of NetworkManager's profiles into `/var/lib/iwd`,
turns NetworkManager off and resolved, iwd and networkd on. `revert` goes back to
NetworkManager (the files stay, unused). Afterwards: `sudo pacman -Rns networkmanager` once
everything works.

## Checking

```bash
networkctl                      # links and their state (routable = online)
networkctl status enp42s0       # one link: addresses, gateway, DNS, NTP from DHCP
resolvectl status               # which DNS server for which link; with the VPN up, only pia
iwctl station wlan0 show        # the Wi-Fi link
ip rule; ip route show table 51820   # the VPN's routing (while connected)
```
