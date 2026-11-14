# qBittorrent router (barch-qbrouter)

**Public torrents go through the VPN, private ones (any private tracker) leave from the home address**, whatever
app grabbed them. Some private trackers ban VPNs and proxies outright (SAPIbr: "VPN e proxy são PROIBIDOS", a permanent
ban), and the NAS's qBittorrent (`qbittorrent`, binhex with PIA) sends everything through `tun0`, announce
included, with a kill switch that allows no exception. So those torrents need a second client that leaves
from the home address, `qbittorrent-private`. Shelfmark, the one that grabs books, takes a single
qBittorrent URL. This service is that URL: it answers qBittorrent's Web API and hands each torrent to the
client its trackers call for. Its own container (`barch-qbrouter`, on `frutuozoproxy`, no host port),
standard library Python.

```
Shelfmark ──> barch-qbrouter:8080 ──┬─> qbittorrent:8080          (VPN)     everything else
                                    └─> qbittorrent-private:8080  (no VPN)  trackers in "routes": sapibr.com
```

`./install.sh` copies it to the NAS and prepares everything else: `qbittorrent-private`'s `qBittorrent.conf`
before its first start (`deploy/qbittorrent-private.conf`: save paths, port 6882, DHT/PeX/LSD off, the same
whitelist as `qbittorrent`, SWAG trusted as reverse proxy so the whitelist sees real addresses, a new
password kept in `~/.config/barch/qbittorrent-private.json`), the two Unraid templates (`templates/`) and the
SWAG proxy-conf for `downloader-private.<domain>` (Authelia; the API only from the LAN and Docker). It then
prints the root commands, the two containers to Apply from their templates, the DNS records, the pfSense
port forward (6882) and the Shelfmark change. Web UI: `http://<nas>:8095` or the subdomain.

## Rules

- **torrents/add**: the trackers come from the torrent itself (the `.torrent`'s announce and
  announce-list, a magnet's `tr=`). A `.torrent` URL (Prowlarr's link) is fetched here, following
  redirects, and sent on as a file or as the magnet it redirected to, so a client never fetches it
  itself (the VPN client cannot resolve Docker names anyway). The first route whose hosts match a tracker
  (the domain or any subdomain) picks the client. Then, with `private_backend` set (`"private"`), a
  `.torrent` carrying the BEP 27 private flag goes there: every private tracker sets it, so a tracker added
  to Prowlarr later needs no change here. Its tracker hosts are learned (`data/hosts.json`), so a magnet of
  the same tracker follows; a host ever seen in a public torrent is never learned (and is forgotten if it
  shows up in one later), so an open tracker left in a private torrent cannot pull public magnets off the
  VPN. Anything else goes to `default`. **What cannot be known is
  refused** with qBittorrent's own `Fails.` (a URL that does not answer, HTML instead of a torrent): a
  guess could put a banned tracker on the VPN.
- **By hash** (`files`, `properties`, `delete`, `setCategory`, ...): the client holding the hash, from
  `data/hashes.json` (written at add time and from every listing), else asked of the non-default clients
  (a 5 s cache), else the default. `torrents/info` without hashes is the union of both (sort, limit and
  offset applied after merging); if either client fails, the whole answer fails (502), since half a list
  would read as torrents gone missing.
- **Categories and tags** are created and removed on every client, so `books`/`audiobooks` exist wherever
  a torrent lands. Everything else (`app/*`, `transfer/*`, `sync/*`) is the default client's.
- **Login**: any login is accepted (it is reachable only on the Docker network, where `qbittorrent`
  already whitelists everyone). It reaches the clients without credentials (both whitelist
  172.18.0.0/16), or with the ones in `secrets.json` when a client answers 403.
- **Guard**: every `guard_s` (60) it lists the default client and **stops** any torrent whose trackers
  belong to another client's route, that qBittorrent marks private, or whose tracker was learned as
  private, whoever added it (Radarr, a pipeline, by hand), with a `GUARD:` line
  in the log. It cannot undo the first announce, which happens the moment a torrent is added; it keeps a
  mistake from seeding for days through the VPN.

Logs carry tracker hosts only, never a URL with a passkey or Prowlarr's `apikey`.

## The two clients alike

`qbittorrent-private` has the VPN client's queue and limits (500 downloads, 80 uploads, 1000 active, slow
torrents not counted, 2000 connections, unlimited upload slots, automatic torrent management, 2.5 MiB/s
upload each, so 5 MiB/s together) and the same categories with the same save paths. `install.sh` copies
them from the VPN client every run (both are reachable from the desktop without login); change them in the
VPN client and run it again. Only what must differ differs: the port, the network interface, DHT/PeX/LSD,
the incomplete folder and the web UI.

## Files on the NAS

`appdata/barch-qbrouter/`: `app/barch_qbrouter` (replaced by `install.sh`), `config.json` (the routes;
created once from `deploy/config.example.json`, edited there afterwards), `secrets.json` (Prowlarr's key,
sent only to the hosts in `fetch.api_key_hosts`, and optional client logins), `data/hashes.json`.

A new tracker that bans VPNs: add its domain to the `private` route's `hosts` in `config.json` and
`docker restart barch-qbrouter`. Which client a torrent would go to, without sending anything:

```bash
PYTHONPATH=/config/app python3 -m barch_qbrouter which --config /config/config.json <file.torrent | magnet>
```

`GET /barch/status` (inside the container: `wget -qO- 127.0.0.1:8080/barch/status`): both clients'
reachability and version, the routes, how many hashes are mapped, the last guard run and what it stopped.

## Its clients

- **Shelfmark**: `QBITTORRENT_URL=http://barch-qbrouter:8080` (Settings > Download Clients).
- **Prowlarr**: its download client "qBittorrent" (host `barch-qbrouter`, port 8080), used only for grabs made
  in Prowlarr's own search page.
- **Radarr, Sonarr, Lidarr**: their "qBittorrent" download client, host `barch-qbrouter` (2026-11-14). Their
  queues read both clients (`torrents/info` is merged); the paths match, both mount the same `/data`.
- **The video pipeline** (`barch-video`, `qbittorrent.url` in its `config.json`): it adds dub donors found
  through Prowlarr, private trackers' included. One client is enough: the router picks per torrent, so no indexer needs its
  own download client (a forgotten per-indexer setting would land on the VPN).

## What it does not cover

- The music pipeline's seed check and the torrent statistics (`barch-torrents`) talk to `qbittorrent`
  directly, on purpose for the first: it deletes at ratio 3 after 72 h, or sooner when the disk runs low,
  which would be a hit-and-run on a private tracker. So torrents in `qbittorrent-private` are never removed
  automatically (they seed until removed by hand: watch the downloads disk) and are not in the Torrents app.
- SAPIbr has nothing for Radarr/Sonarr (books and courses only) but lists a TV category, so in Prowlarr it
  carries the sync profile "Somente Shelfmark (nunca nos *arr)" (RSS and searches off): it reaches them
  disabled, while Prowlarr's own search, Shelfmark's, ignores sync profiles. A private tracker with films or
  series keeps the Standard profile: Radarr/Sonarr go through the router like everything else.

Tests: `python3 -m unittest discover -s tests` (`scripts/check.sh` runs them).
