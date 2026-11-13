# Torrent statistics (qBittorrent over time)

qBittorrent only knows its totals as they are now, and nothing of a torrent once it is deleted (the
seed policy of the music pipeline deletes every one at ratio 3 or 90 days). This service writes the
numbers down so they can be drawn: its own container on the NAS (`barch-torrents`), read only, standard
library Python and one SQLite file.

`./install.sh` (`barch torrents install`) copies it to the NAS and prints the container's settings.

## What it keeps

Every five minutes, on the clock (`poll_s`), one call to `/sync/maindata`:

- **`samples`**: the client's all-time upload and download (so the ratio qBittorrent shows, over time),
  speeds, how many torrents (seeding, downloading), their size, free space, peers.
- **`torrents`**: one row per torrent ever seen: name, category, size, dates, its last counters and its
  lifetime totals. A torrent that was already there when tracking began keeps its counters of that moment
  as `base_*`: traffic of an unknown date, counted in the totals and never in a day's bar. A torrent
  removed from the client keeps its row (`removed_at`), so a source's upload stays true afterwards; one
  added again starts from zero and adds to the same row.
- **`traffic`**: what each torrent uploaded and downloaded per hour (the difference between two samples).
  Hours older than `keep_hours_days` (60) are merged into one row per day.

Two labels are added once per torrent:

- **tracker**: the site of its first announce URL (`bt2.t-ru.org` → `t-ru.org`). Only the host is ever
  stored: a private tracker's URL carries the passkey. On a public torrent with twenty open trackers this
  says little, which is why there is also the
- **indexer**: where it was grabbed from. First by its hash from Lidarr's, Radarr's and Sonarr's history
  (`history/since`, `downloadId` = the info hash), for the ones whose API key is there. What is left goes
  to **Prowlarr's** history, which every grab passes through (Shelfmark's books too) but which has no hash:
  a torrent is tied to a grab by the same title (as words; the nearest in time when grabbed twice), or by
  the moment, since the client gets the torrent the second it is grabbed (within 5 s, or within 2 min when
  the words overlap; two indexers equally near is no answer). Measured on the 124 torrents of 2026-11-05:
  122 found, and the same answer as Radarr and Sonarr on all 13 they knew. Prowlarr's key alone covers
  everything; `secrets-arr.json` is written by `install.sh` (Prowlarr's from its `config.xml` on the share,
  Radarr's and Sonarr's from `~/.config/barch/video.json`, Lidarr's from `.lidarr.key` in
  `~/.config/barch/torrents.json` if you put it there). A torrent that came from somewhere else
  (Shelfmark's direct sources) has none. Prowlarr forgets its history after a while, so the match is made
  when the torrent is first seen.

`goal_ratio` (3, the seed policy's) is only what the overview counts torrents against.

## API

Port 8340, header `X-Barch-Token` (compared in constant time; the service refuses to start without a token, so the API is never open); `range` is `24h`, `7d`, `30d`, `12w`, `1y` or `all`. The list is in
the docstring of `barch_torrents/service.py`: `status`, `overview`, `samples`, `history` (per hour, day,
week or month by the range; of everything, one category/indexer/tracker or one torrent, with the lifetime
ratio at each bucket's end), `groups`, `torrents`, and `POST sample|restart`. The Torrents app
(`quickshell/torrents`), `barch torrents` and the page below are its clients.

## The page

`http://<nas>:8340/` is the Torrents app in a browser (`barch_torrents/web.html`, one static file the
service hands to anyone; it asks for the token of `~/.config/barch/torrents.json` once and keeps it in
that browser, and every number still comes from the API with it): the same Overview, Sources and
Torrents pages over one range, the same charts, the list on top of the history on a phone.
`#sources`, `#torrents` and `#torrents/<hash>` open a page or one torrent. A change to the app's pages
or to `ui/Chart.qml` / `Bars.qml` is repeated there by hand. The portal's **Seeding** card opens it and
shows the container's state (`server: nas`, `container: barch-torrents`) and `/api/overview`.

## Files on the NAS

    appdata/barch-torrents/app/barch_torrents   the code (replaced by install.sh)
    appdata/barch-torrents/config.json          settings (deploy/config.example.json)
    appdata/barch-torrents/secrets.json         the API token (600, the container's)
    appdata/barch-torrents/secrets-arr.json     Prowlarr's and the *arr keys (rewritten by install.sh)
    appdata/barch-torrents/data/torrents.db     the history: back it up, nothing else can rebuild it
    appdata/barch-torrents-init/                the s6 scripts (root's, read only in the container)

Tests: `python3 -m unittest discover -s tests` (`scripts/check.sh` runs them).
