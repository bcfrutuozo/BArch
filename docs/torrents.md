# Torrents

qBittorrent over time (`server/torrents`, its README) through the Torrents app.

**Torrents** (`quickshell/torrents/`, "Torrents" in the launcher, `barch torrents browse [overview|sources|torrents]`):
qBittorrent over time. The client only knows its totals as they are now, so a small service on the NAS
(`server/torrents`, container `barch-torrents`, read only) samples it every five minutes; the app draws what
it kept, in one range for the whole window (24 h, 7 d, 30 d, 90 d, 1 y, all); every chart spans that whole
period, with a dashed line where tracking began when it is younger than the range. **Overview**: the all-time
ratio and how far it moved in the range, upload and download in the range, the last day and week, how many
torrents reached the seeding goal (ratio 3), and the charts: ratio, speed, uploaded and downloaded per hour /
day / week / month, torrents, data in the client. **Sources**: where the traffic comes from, by indexer (the
one the torrent was grabbed from: by its hash in Lidarr's, Radarr's and Sonarr's history, else by title and
time in Prowlarr's, which covers Shelfmark's books too), category or tracker (the first
announce host; public torrents carry many, so it says less): torrents, upload and download in the range and
in total, lifetime ratio; a click shows that source's ratio and its upload and download over time.
**Torrents**: every torrent the service has seen, the ones the seed policy already removed included (their
numbers would be gone from qBittorrent), filtered by name or state and sorted by upload, ratio, size, age or
seeding time; a click shows its facts and history. `qs ipc call app torrent <hash>` opens one. Traffic a
torrent had before the service first saw it has no date: it counts in the totals, never in a day's bar.
The same three pages are a web page too, served by the service itself at `http://<nas>:8340/` (asks for
the `barch torrents` token once; works on the phone): it is what the **Seeding** card of the portal opens.
