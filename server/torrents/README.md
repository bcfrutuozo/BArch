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
- **indexer**: the one Lidarr, Radarr or Sonarr grabbed it from, read from their history
  (`history/since`, `downloadId` = the info hash). Needs their API keys (`secrets-arr.json`, written by
  `install.sh`: Radarr's and Sonarr's from `~/.config/barch/video.json`, Lidarr's from `.lidarr.key` in
  `~/.config/barch/torrents.json`); a torrent no *arr grabbed (Shelfmark's books) has none.

`goal_ratio` (3, the seed policy's) is only what the overview counts torrents against.

## API

Port 8340, header `X-Barch-Token`; `range` is `24h`, `7d`, `30d`, `12w`, `1y` or `all`. The list is in
the docstring of `barch_torrents/service.py`: `status`, `overview`, `samples`, `history` (per hour, day,
week or month by the range; of everything, one category/indexer/tracker or one torrent, with the lifetime
ratio at each bucket's end), `groups`, `torrents`, and `POST sample|restart`. The Torrents app
(`quickshell/torrents`) and `barch torrents` are its two clients.

## Files on the NAS

    appdata/barch-torrents/app/barch_torrents   the code (replaced by install.sh)
    appdata/barch-torrents/config.json          settings (deploy/config.example.json)
    appdata/barch-torrents/secrets.json         the API token (600, the container's)
    appdata/barch-torrents/secrets-arr.json     the *arr keys (rewritten by install.sh)
    appdata/barch-torrents/data/torrents.db     the history: back it up, nothing else can rebuild it
    appdata/barch-torrents-init/                the s6 scripts (root's, read only in the container)

Tests: `python3 -m unittest discover -s tests` (`scripts/check.sh` runs them).
