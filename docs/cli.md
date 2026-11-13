# barch CLI

Every subcommand; `barch help` prints the same with more detail.

`barch` is the stable command line for scripts (and agents). It only asks the bar over Quickshell
IPC, so it does exactly what the Control Center does; the bar has to be running.

```bash
barch notify "Backup" "Finished in 4 min" [--critical|--low] [--app NAME] [--action "Label=command"]
barch theme light|dark|auto|status   barch theme dark|light <palette>   barch theme palettes
barch theme edit [<palette>]       # the palette editor (own window), live preview on the whole desktop
barch theme from-image <image> [--id ID] [--label NAME] [--dark|--light]   # a palette from a picture → editor
barch theme delete|export <palette>
barch wallpaper list|status        barch wallpaper <scene> [--lock|--desktop]   # both by default
barch wallpaper render [<palette>|all]   # the scenes in a palette's colors (automatic when pinned)
barch hypr [edit] [<page>]         # Hyprland Settings (every option of the installed version, monitors, binds…)
barch hypr get|set|reset|list|status [<option>] [<value>]   # the same file from a shell (see apps.md)
barch center [<page>]              # System Center: the NAS, services, timers, failures, agent, snapshots, journal (barch center nas)
barch backup browse [<page>]       # Backup Browser: snapshots, files, restore into ~/Restore
barch packages [<page>]            # Packages: installed, orphans, updates, pacnew, repo lists, history
barch mixer [<page>]               # Audio Mixer: devices, per-app volume and routing, sample rate
barch clip [<file>]                # Clip: crop, turn, mirror and trim a video, preview it, save it (see apps.md)
barch clip info <file>             # size as displayed, fps, codec, HDR, rotation, audio
barch clip export <file> [--crop W:H:X:Y] [--rotate 90|180|270] [--flip h|v|hv] [--from T] [--to T] [-o OUT] [--replace]
barch hdr on|off|status            barch sdr <nits>|status
barch monitor side on|off|status   barch caffeine on|off|status
barch nightlight on|off|status     barch dnd on|off|status
barch anon on [region]|off|toggle|status   # Anonymous Mode: VPN + kill switch + Mullvad Browser as default + hostname out of DHCP
barch vpn on [region]|off|toggle|status|regions|region <id>|auto
barch health [--refresh]           # .pacnew, failed services, TPM, backup, cleanup
barch inbox [--refresh]            # what waits for a decision: music/video review, library, books, failures, health, agents
barch claude [--refresh]           # the Claude plan's usage: 5-hour session, week, Fable share, resets, plan, agents' spend
barch rgb [status]|apply|on|off|color <tone|#hex>|brightness <0-100>|flash [tone] [n]   # Corsair lighting (see theme.md)
barch drop [status]|setup|open     # BArch Drop: files and links from the iPhone (see apps.md); setup = QR + Shortcut
barch voice on|off|toggle|status   # always-on voice control (see voice.md); pause|resume keep the service
barch voice match "abre o terminal"  # which command a sentence hits, running nothing · test "..." runs it
barch voice wake "Bartch, liga o HDR"  # would it wake the daemon · misses: near misses of the wake word, to tune it
barch voice say "texto"            # speak · reload (commands.json) · log · setup [--install]
barch voice lang [<code>|list]     # the language it listens and answers in (pt, en, es, auto…)
barch backup init|run|check [--full]|status|list|restore [SNAPSHOT] <path>...   # restic to the NAS, verified weekly (see backup.md)
barch rules list|test <event> [k=v..]|fire <id>|enable|disable <id>   # agent/rules.json (see agent.md)
barch events status|log [n] [--filter x] [--since 7d]   # the daemon and what happened (windows, VPN, boots, costs…)
barch metrics list|series <metric> [--since 24h]|summary   # metrics.db: temperatures, load, boots, failures, Claude cost
barch nas status [--no-certs]|setup   # the NAS now, through Unraid's API: array, disks, pools, containers, Unraid's warnings, certificates
barch disk status                  # the local disks: SMART (temperature, wear, spare, media errors, self-test), btrfs counters, last scrub
barch fw status|clients|blocked [site] [n]|setup   # the pfSense firewalls through their REST API: gateways, IPsec, DNSBL, leases, blocks (see nas.md)
barch agent ask "why is X slow?"   # Claude in a terminal in ~/BArch (the launcher's "a ")
barch agent list|run|report|continue <task>   # scheduled tasks (see agent.md)
barch agent dismiss [<task>|all]   # a warn/alert report stops counting in the Center and the Inbox (it stays in the history)
barch failure <unit> [--system]    # what OnFailure= calls: log + notification (see agent.md)
barch failure list [<unit>] · dismiss|delete [<unit>|all]   # the saved logs: seen (kept, no longer counted) or removed
barch snapshot list                # safety snapshot pairs of the agent sessions
barch aur review                   # verdict on the pending AUR updates
barch finance import [--dry-run]   # C6 Bank statements → Firefly (see finance.md)
barch player [browse] [albums|artists|tracks|genres|queue|favorites|recent|lyrics|stats|viz|eq|settings]   # the Player (see player.md)
barch player play|pause|toggle|next|prev|stop|status · volume <0-100|±n> · seek <s|±s> · like · shuffle [on|off] · repeat [off|all|one]
barch player album|play-album|queue-album "<Artist/Album>" · playlist <name> · search "<text>" · catalog [status|refresh [--full]]
barch player eq [on|off|toggle|<preset>|band <1-10> <dB>|preamp <dB>]   # the equalizer; no argument: its state and the presets
barch player plex [status|sessions]   # what was told to Plex (Tautulli's source) and Plex's Now Playing
barch player show|hide|quit            # the window back · closed with the music on (the bar gets a button) · stop everything
barch music status|browse|list|show|resolve|retry|reject|scan   # the NAS music pipeline and its review queue (see music.md)
barch music accept-year [--dry-run] [--older-than DAYS]   # the review albums waiting only on a year-only date: all resolved as YYYY-01-01
barch music library [list|show|compare|tag|skip|retry] "<Artist/Album>" [<release>]   # the Library tab from a shell (see music.md)
barch music library reorder "<Artist/Album>" <release>   # the same songs in another order: files renumbered and renamed to MusicBrainz's, tagged
barch music library delete "<Artist/Album>" [<release>]  # the files out of /music (/music/.library-trash, 30 days); Lidarr searches the album again
barch music library fix "<Artist/Album>" ["hint"]   # Claude ties one library album to MusicBrainz (compare, then tag)
barch music artists [all] · show "<folder>" · find "<name>"   # the artist folders against Lidarr's artists (the Artists tab)
barch music artists link "<folder>" <mbid> · move "<folder>" "<into>" [--replace] · add <mbid> · remove <id> · skip "<folder>"
barch music agent-sweep [library|review|all] [--parallel N] [--limit N] · status · stop   # Claude over everything waiting, detached
barch music covers check [artist]|list|apply|undo|keep|pick|propose <Artist/Album>   # scans with a frame -> the clean artwork
barch music covers ask <Artist/Album> "keep the red frame"   # Claude adapts one or finds another, as a proposal
barch music cover <id> <file|URL> [label]   # the cover you found for an album waiting on it: checked, then the album runs
barch music cover-ask <id> ["hint"]   # Claude searches the web for it and runs the album (the music-cover rule does this alone)
barch music fix <id> ["hint"]         # Fix with Agent: Claude takes the album over (release, date, cover, merge) until it is in
barch music rescan <id>               # the download taken in again from scratch (a torrent split wrong by an older version)
barch music retitle "<Artist/Album>" "<title>"   # the ALBUM tag (as given) and the folder of an album in /music; Plex and Lidarr told
barch music mb-add <id>               # an edition MusicBrainz lacks: its release editor opens in the browser filled in from the download
barch music lidarr-artists|lidarr-albums <artist>|lidarr-search <ids>|lidarr-profile <name> ...|lidarr-list <Type> <name> field=value..
                                   # what Lidarr tracks, search albums, metadata profiles (studio albums only), import lists
barch music seeds [days] [--live]|check   # seeding until ratio 3 / 90 days (music and video), and what the removed ones seeded, per tracker
barch music lidarr-queue|lidarr-queue-remove <ids>|all|lidarr-commands|lidarr-cancel <id>   # what Lidarr is downloading and running
barch music lidarr-enforce         # the library's rule on every artist now: BArch profile, every album without a file monitored (hourly by itself)
barch music lidarr-artist-set all|<ids> --new-albums all|new|none [--monitored on|off]   # what happens to an album that shows up later
barch books browse [search|shelf|requests|rejected|downloads]   # the Books app (see books.md)
barch video browse [search|movies|series|downloads|dub]   # the Video app: add, checklist, releases, queue, dub
barch torrents browse [overview|sources|torrents]   # the Torrents app: qBittorrent's ratio, upload and download over time
barch torrents status|summary [range]|sources [indexer|category|tracker] [range]|top [range] [n]   # the same numbers in a shell (range: 24h, 7d, 30d, 1y, all)
barch torrents sample|restart|install   # read qBittorrent now · restart the service · copy it to the NAS (server/torrents)
barch books search <query> · shelf · want|unwant <id> · sync   # Hardcover through Shelfmark, Want to Read
barch books requests [status] · show|releases <id> [--query Q] [--source S] · fulfil <id> --pick N · accept <id> · reject|reopen <id>
barch books fix <id> ["hint"]         # Claude takes a request no source matched and downloads the right release
barch video status|list [state]|show <id>   # the PT-BR pipeline on the NAS (server/video): dub muxed into each movie and episode (s<id>x<season>)
barch video retry|skip|unskip <id> · use <id> <guid> · search <id> "query" · add <id> <url> · fix <id> ["hint"] · scan · digest · install
barch video foreign · audit [--foreign]   # files with audio beyond the original and PT-BR (the pipeline trims them)
barch applio [open|start|stop|status]   # Applio's web server in the background, a tray icon while it runs
barch mic toggle|start|stop|status   # record the microphone into ~/Recording (Super+R)
barch replay share [file] [--from 12 --to 40]
                                   # newest replay (or FILE) → <name>-share.mp4 for WhatsApp status:
                                   # H.264 ≤1080p30, HDR tone mapped to SDR, at most 60 s
```

Every command takes `--json`. Exit codes: `0` ok, `1` the bar refused, `2` usage, `3` bar not reachable.
On the QML side these are the `IpcHandler`s `control`, `theme`, `wallpaper`, `notifs`, `health`, `inbox`, `claude`, `vpn`, `anon` and `voice` (`qs ipc show`).
