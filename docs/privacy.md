# Anonymous Mode, firewall and VPN

What keeps this machine from giving itself away: the Anonymous Mode tile, the nftables firewall and the PIA VPN.

## Anonymous Mode

**Anonymous Mode** (`quickshell/anon/`): one tile for the VPN plus what would still give the machine
away. On: Mullvad Browser (the Tor Browser protections without Tor: one User-Agent for everyone,
Windows platform, letterboxed window, canvas blocked, WebRTC off, UTC) becomes the default browser
so links from other apps open there, every Ethernet and Wi-Fi profile stops sending the hostname
over DHCP, the VPN comes up and the **kill switch** is armed: `/usr/local/bin/barch-killswitch`
(root, through `barch-killswitch@.service`, which polkit lets wheel users start) adds an nftables
table whose output and forward chains only let through the tunnel itself (UDP to the PIA server),
anything inside the tunnel, the directly connected networks (LAN, libvirt, Docker) and their
broadcast/multicast/link-local traffic; everything else is rejected, so a dropped tunnel means
no traffic, not exposed traffic, for VMs and containers too. A region change re-arms it for the
new server before the tunnel moves. Off removes the table, disconnects and brings the previous
browser back; the mode never survives a logout or boot (`/run` is empty, the session mark is
gone), so the switch cannot lock a fresh session out. The WebRTC policy of the Chromium
browsers (Brave, Chromium: `WebRtcIPHandling` in `/etc/brave` and `/etc/chromium`
`policies/managed`, in `system/`) is static: they only ever expose the address of the default
route, which is the tunnel's while connected. The tile and `barch anon status` say what the mode
cannot cover right now (Mullvad Browser missing, kill switch not installed or not armed, policy
missing); with the tunnel down the bar's shield turns orange ("kill switch holding") or red
("traffic exposed", no kill switch). Not covered by design: accounts you are logged into, apps
that send the device name, the trust in PIA itself. Hostname stays `DSKbcfrutuozo` (changing it
live is fragile).

## Firewall

**Firewall** (`system/files/etc/nftables.conf`, `nftables.service`): nothing in, everything out,
the policy of Omarchy's UFW setup, in nftables. Incoming: loopback, answers to what this machine
started, ping and the ICMPv6 that IPv6 needs, DHCP answers, libvirt guests and Docker containers
talking to the host; the rest is dropped. Forward: guests and containers out; a published
container port is reachable from the local networks only, never from the internet (what
ufw-docker gives Omarchy). One port is open, from this LAN only: TCP 8350, BArch Drop. Only its own table (`inet barch`) is managed, so libvirt's and Docker's
tables and the kill switch survive a reload. No SSH or LocalSend rules (sshd is off here,
LocalSend is not installed); mDNS discovery (Chromecast) and Steam's local transfers are not
opened either. `sudo nft list table inet barch` shows it with counters.

## VPN

**VPN** (`quickshell/vpn/`, what Anonymous Mode uses; `barch vpn` drives it alone): Private
Internet Access over WireGuard, without root. `pia.sh` gets a token from the PIA API, registers a
fresh key pair on the chosen server and writes the answer into
a NetworkManager profile owned by the user (`connection.permissions`), so `nmcli` brings it up
with the session's polkit rights. Region "Auto" is the lowest latency measured at that moment;
the VPN Region tile lists them all with a filter, fastest first. DNS is exclusive and IPv6 is
routed into the tunnel (dropped there) while connected. A shield with the country shows in the
bar while connected (click: IP, time, Change region, Disconnect). Credentials go in `~/.config/pia/credentials`
(username and password, one per line, `chmod 600`), never in the repo.
