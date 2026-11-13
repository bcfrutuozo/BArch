# NAS

The NAS and the firewalls as this desktop sees them, read only.

**Health** (`agent/nas.py`, `barch nas status`): the desktop asks Unraid's own API (GraphQL, the one
Homepage's Unraid widget uses) every five minutes, read only, and `barch-events` turns the answer
into the `nas.*` metrics, events and rules of Automation (the System Center's **NAS** page, `barch center nas`, shows the same snapshot): the NAS not answering (three misses in a
row, so a reboot of this machine or of the NAS's network says nothing), the array leaving STARTED, a
disk that is no longer OK or counts errors, a container down for more than 15 minutes (one Unraid
starts by itself that is not running, any that exited with an error, restarts in a loop or reports
unhealthy; a clean stop of the ones Nextcloud AIO manages is its own doing), Unraid's unread warnings
and alerts (SMART, temperature, parity), array or pool filling up, and the TLS certificates of the
Unraid interface, the reverse proxy, both firewalls and the mail server under ten days (checked
every six hours). Each is said once, not at every sample. `barch nas setup` writes
`~/.config/barch/nas.json` (mode 600) with the URL and the API key it finds in Homepage's config on
the appdata share; `certs` (the endpoints watched) and `ignore_containers` (regexes) are edited
there, the intervals and thresholds (`nas_every_s`, `nas_grace_s`, `cert_warn_days`) in `rules.json`.
Unraid's certificate chains to a Let's Encrypt root the system store does not carry yet, so
`agent/certs/root-yr-by-x1.crt` (its cross-signature by ISRG Root X1) is loaded next to the store.

**Firewalls** (`agent/pfsense.py`, `barch fw status|clients|blocked [site]`): both pfSense (omni and chaos)
through their REST API package (`~/.config/barch/pfsense.json`: URL, key and resolver address per site, written
by hand after `barch fw setup`, which says how to make a `barch` user with the seven read-only privileges and
its key on each firewall), every five minutes, read only: load and temperature, every gateway's latency and
loss, the enabled interfaces, the IPsec tunnel's child SAs, the DHCP leases and the firewall log. The DNSBL is
checked for real, not through the API: a DNS query for a domain the lists block (`dnsbl_probe`, doubleclick.net)
to each firewall's resolver, which has to answer the DNSBL virtual IP (`dnsbl_vip`, 100.99.0.1); chaos's
resolver answers over the tunnel. `barch-events` turns it into metrics (`fw.<site>.cpu.pct`, `gw.<name>.rtt`,
`ipsec.up`, `dnsbl`, `clients`, `blocked` and `blocked.<interface>`: connections the firewall blocked since the
last sample, read from the log) and events, each said once: down after three misses and back, a reboot, a
gateway or an interface down, the tunnel down, the DNSBL not blocking, and `fw.client`, a MAC never seen on
that site taking a lease (the first sample learns what is there and says nothing; `ignore_macs` skips
randomized ones). A key the API refuses is reported once and left alone for an hour: the API's login
protection bans an address after a few refused keys, so never probe with guessed ones.

**Shell:** **Super+Shift+T** opens foot with `ssh nas` (root at `100.100.0.10`, the `nas` host of
`~/.ssh/config`, which stays out of the repo; key-only, a shared connection kept for 10 min so the
next one opens at once; `SetEnv TERM=xterm-256color`, since Unraid has no `foot` terminfo and
with `TERM=foot` readline drops to a dumb line: paste, arrows and every TUI break). The key goes in once with `ssh-copy-id nas`; Unraid keeps root's
`.ssh` on the flash (`/boot/config/ssh/root`), so it survives reboots.

The NAS (NASfrutuozo) runs Unraid on an ASUS Maximus IX Code (Z270). Its on-board Aura RGB sits
behind the SMBus of the Nuvoton NCT6793D Super I/O, which only the out-of-tree `i2c-nct6793`
driver exposes (the `i2c-i801` of the chipset is not enough, and the old ich777 OpenRGB plugin
stops at Unraid 7.1; the "no patch needed with recent kernels" only covers the AMD `i2c-piix4`
part). `server/unraid/build-i2c-nct6793.sh`, run inside ich777's `Unraid-Kernel` container on
the NAS (it downloads the pre-compiled tree of the running kernel), builds it as a Slackware
package: copy the `.txz` to `/boot/extra/` (installed at every boot) and add
`modprobe -a i2c-dev i2c-i801 i2c-nct6793` to `/boot/config/go`; the new `/dev/i2c-N` ("SMBus
NCT6793D adapter") goes to the OpenRGB container. The package is per kernel: redo it after every
Unraid update. The header of the script has the exact commands.
