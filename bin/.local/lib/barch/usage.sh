# shellcheck shell=bash
# barch: the help text (barch help).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

usage() {
  cat <<EOF
Usage: $PROG [--json] <command> [args]

Desktop (through the bar):
  notify <title> [body] [--critical|--low] [--app NAME] [--action LABEL=COMMAND]...
                              notification through the bar's own server; each --action is a
                              button that runs COMMAND (sh -c)
  theme light|dark|auto|status
                              appearance (Auto follows the theme-auto schedule)
  theme dark <palette>, theme light <palette>, theme palettes
                              the palette pinned to each mode (everything generated follows it)
  theme edit [<palette>]      the palette editor (quickshell/palette): ten tones with live
                              preview on the whole desktop; Save pins it and renders its wallpapers
  theme from-image <image> [--id ID] [--label NAME] [--dark|--light]
                              a palette from the image's colors, opened in the editor
  theme delete <palette>      remove it from theme/palettes.json (not while pinned)
  theme export <palette>      its JSON (theme/palettes.json entry)
  wallpaper list|status       the scenes in ~/Pictures/Wallpapers, which is on the desktop and the lock
  wallpaper <scene> [--lock|--desktop]
                              use a scene (both by default; a lock-only choice stays until changed)
  wallpaper render [<palette>|all]
                              draw the scenes in a palette's colors (the bar does it on its own the
                              first time a palette is pinned); default: the palette in use
  hypr [edit] [<page>]        Hyprland Settings (quickshell/hypr): every option of the installed
                              version, monitors, binds, animations, rules, devices, startup; page:
                              a section (general, decoration, input…) or monitors|binds|animations|
                              rules|devices|startup|files
  hypr get <option>           an option: current value, default, what the app saved
  hypr set <option> <value>   save it in hypr/settings.json and apply it live (value as JSON:
                              10, true, "dwindle", {"colors":["rgba(ff0000ff)"],"angle":45})
  hypr reset <option>|all     forget it (the files' value is back after the reload this does)
  hypr list|status            what the app saved · version, option count, config errors
  backup browse [<page>]      BArch Backup (quickshell/backup): status, snapshots, browse a snapshot
                              and restore into ~/Restore; page: status|snapshots|browse
  packages [<page>]           BArch Packages (quickshell/packages): installed (explicit, AUR, orphans),
                              updates, .pacnew, the repo lists, pacman history; page: installed|updates|history
  mixer [<page>]              BArch Mixer (quickshell/mixer): PipeWire devices, per-app volume and
                              routing, sample rate, Bluetooth codec; page: devices|apps|settings
  clip [<file>]               BArch Clip (quickshell/clip): a video editor like the iPhone's: cut the
                              borders away (crop), turn, mirror, trim, Preview, Save (a new file
                              next to the original, or over it with the original in the trash)
  clip info <file>            what clip.py sees: size as displayed, fps, codec, HDR, rotation, audio
  clip export <file> [--crop W:H:X:Y] [--rotate 90|180|270] [--flip h|v|hv] [--from T] [--to T]
                     [-o OUT] [--replace]   the same edit without the window (crop measured on the
                              frame as displayed, after the rotation and the flips); NVENC, HDR10 kept
  center [<page>]             BArch Center (quickshell/center): the NAS (page nas), the firewalls (firewalls), services and timers (user and
                              system), the failures saved by `barch failure`, the agent tasks
                              and reports, the safety snapshots, health, journal; page: overview|
                              services|timers|failures|agent|snapshots|journal
  hdr on|off|status           HDR on the main monitor
  sdr <nits>|status           SDR brightness inside HDR
  monitor side on|off|status  side monitor (DPMS)
  caffeine on|off|status      keep the screen from idling, locking and suspending
  nightlight on|off|status    night light (hyprsunset)
  dnd on|off|status           Do Not Disturb
  anon on [region]|off|toggle|status
                              Anonymous Mode (the Control Center tile): the VPN with a kill
                              switch, Mullvad Browser as the default browser and the hostname
                              out of DHCP; status also lists what the mode cannot cover
  vpn on [region]|off|toggle|status
                              the VPN alone: PIA over WireGuard (what Anonymous Mode uses)
  vpn regions                 regions, fastest first; vpn region <id>|auto picks the one to use
  health [--refresh]          system health summary (.pacnew, failed services, TPM, cleanup)
  inbox [--refresh]           what waits for a decision: music and video review, library albums to tie,
                              book requests, failures of the day, health issues, agent reports (the bar's
                              tray icon with the total; quickshell/inbox)
  claude [--refresh]          the Claude plan's usage as /usage shows it: 5-hour session, week, the top model's
                              share (Fable), resets, plan (Max 5x), and what this machine's agents spent today
  voice on|off|toggle|status  always-on voice control (quickshell/voice, barch-voice.service):
                              say "barch" and the command, in Portuguese
  voice pause|resume          keep the service but ignore the microphone / listen again
  voice lang [<code>|list]    the language it listens and answers in (pt, en, es, auto… every
                              language whisper knows; only Portuguese has the command table,
                              the rest goes to Claude; the Piper voice is downloaded when picked)
  voice say <text>            speak TEXT (piper)
  voice match <text>          which command TEXT would run, running nothing (to test commands.json)
  voice wake <text>           would TEXT (as whisper might write it) wake the daemon, and with what left
  voice misses [n]            first words that came close to "barch" without waking it (to tune the
                              spellings in config.json)
  voice test <text>           run TEXT as if it had been heard (no wake word; it does act)
  voice reload                reload commands.json and the app/project lists
  voice log                   the daemon's journal
  voice setup [--install]     what is missing (whisper.cpp, model, piper, voice); --install asks paru
  music status|list [state]   the music pipeline on the NAS (server/music): downloads -> /music
  music browse [<page>]       BArch Music (quickshell/music): the review queue with the resolve inputs
                              as a form, every album handled (undo), Lidarr [review|albums|covers|lidarr]
  music show <id>             one album: problems, MusicBrainz candidates, the proposed tags
  music accept-year [--dry-run] [--older-than DAYS]
                              the review albums whose only problem is a year-only date (nothing on earth has
                              the day): resolve them all with --date-year-only; --dry-run lists them
  music resolve <id> [--release MBID|URL] [--cover URL|file] [--date YYYY-MM-DD] [--genre G]
        [--album A] [--artist A] [--title D.TT=Title]... [--replace-tracks 1.15,2.03] [--replace]
        [--date-year-only]    (only when no source on earth has the day: the date becomes YYYY-01-01)
        [--keep-order]        (an edition MusicBrainz lacks, e.g. an LP: same songs, the download's order)
                              decide and run it again (an album already in /music is completed
                              and fixed by the library's rules; --replace-tracks swaps the audio of
                              those tracks, --replace the whole album)
  music retry|reject|undo <id>   run again / give up / put back what it changed in /music
  music reject <id> --delete  give up and delete the download once every album of it is done or rejected
  music cover <id> <file|URL> [label]   the cover you found for an album waiting on it: checked, kept
                              with the job and the album runs again with it (= --cover + resolve)
  music cover-ask <id> ["hint"]   Claude searches the web for the album's front cover and runs the
                              album with it (what the music-cover rule does by itself)
  music fix <id> ["hint"]     Fix with Agent: Claude takes the album over (release, date, genre, cover,
                              the merge), resolves it, waits for the run and goes on until it is in
  music scan                  look for finished torrents and inbox folders now
  music mb-add <id>|"<A/B>"   an edition MusicBrainz lacks (a job, or a library album the Library tab could not tie): the release editor opens in the browser filled in
                              from the download (tracks, lengths); you check and submit, logged in there
  music library [list]        the library albums the MusicBrainz sweep could not tie (the Library tab)
  music library show|compare|tag|skip|retry "<Artist/Album>" [<release>]   one of them: the entry, the
                              files against a release track by track, tag it with that release, skip, judge again
  music library reorder "<Artist/Album>" <release>   the same songs in another order: files renumbered and renamed
                              to MusicBrainz's order (titles and audio untouched, undo log), then tagged
  music library delete "<Artist/Album>" [<release>]   the files you have out of /music (/music/.library-trash, 30 days);
                              Lidarr monitors and searches the album again
  music library fix "<Artist/Album>" ["hint"]   Claude finds the release (lengths, catalogue, the web) and tags it
  music artists [list|all]    the artist folders of /music against Lidarr's artists, the ones to decide (all: every one)
  music artists show "<folder>"|find "<name>"   MusicBrainz artists for a folder (credited by its albums first) or a name
  music artists link "<folder>" <artist mbid|URL>   the folder becomes that Lidarr artist (a wrong one removed, files kept)
  music artists move "<folder>" "<into>" [--replace]   its album folders into the folder of the artist they are credited
                              to (--replace: a same-name album there goes to /music/.library-trash and this one takes its place)
  music artists add <mbid|URL> · remove <lidarr id> · skip|unskip "<folder>"   track an artist not in /music yet;
                              drop a Lidarr artist that maps no file; leave a folder without one
  music agent-sweep [library|review|all] [--parallel N] [--limit N]   Claude over every album waiting
                              (Library tab: library fix; Review: music fix), detached; status|stop
  music retitle <Artist/Album> <title>   fix the ALBUM tag (as given) and the folder of an album in /music
  music rescan <id>           take that job's download in again from scratch, as the albums are found
                              now (a torrent split per disc folder by an older version); old jobs superseded
  music covers [list]         the library's covers that were checked: a scan with a frame, a cleaner one
  music covers check [<artist>]   look for scans with a frame (and the clean artwork) in /music
  music covers apply|undo|keep <Artist/Album>   replace cover.jpg + embedded art + Plex poster / undo / keep it
  music covers pick <Artist/Album> <n>         candidate n (as listed in the app) becomes the proposal
  music covers propose <Artist/Album> <file|URL> [label]   a new image as the proposal (still needs apply)
  music covers ask <Artist/Album> "what is wrong"   Claude looks at the candidates, adapts one or finds
                              another and proposes it (Bruno still decides with apply)
  music restart               restart the pipeline in the container (new code after install)
  books browse [page]         the Books app: search Hardcover, Want to Read, requests, downloads
  books search <query>        Hardcover books (★ = on Want to Read) · shelf: Want to Read and what
                              Shelfmark did with each · want|unwant <id> · sync (Hardcover Sync now)
  books requests [status]     Shelfmark's requests (pending by default, "all"; rejected: what you said no to,
                              fulfil takes one back) · show <id>
  books releases <id> [--query Q] [--source S]   releases for a request · fulfil <id> --pick N
  books accept <id> [--query Q]   download the best release carrying the title (no author check)
  books reject|reopen|cancel <id> · downloads · install
  books fix <id> ["hint"]     Claude takes a request no source matched and downloads the right release
  video browse [page]         the Video app: search and add, movies and series with the checklist of each
                              file, releases by hand, downloads, the PT-BR dub (search|movies|series|downloads|dub)
  video status|list [state]   the video pipeline on the NAS (server/video): the PT-BR dub muxed into
                              each 4K file Radarr grabs (states: search, waiting, downloading,
                              aligning, review, done, skipped)
  video show <id>             one movie (m<id>) or season (s<series>x<season>): candidates, alignment, history
  video retry|skip|unskip <id>   search again from scratch / leave alone / take back
  video use <id> <guid>       try this candidate next (from video show)
  video search <id> "query"   Prowlarr with your own query; what fits the job joins its candidates
  video add <id> <url> ["title"]   a magnet or torrent URL found elsewhere, tried next
  video fix <id> ["hint"]     Fix with Agent: Claude finds the donor (Brazilian title, packs, another cut) and runs it
  video foreign               files with audio beyond the original and PT-BR, and what the trim does about them
  video scan|digest [days]|restart   run now / the week / restart after install
  video audit [--json|--foreign]   the library against the rule (HEVC, 2160p, HDR, bitrate, audio, subtitles)
  video install               copy Recyclarr's rules and the pipeline to the NAS (server/video/install.sh)
  player [browse] [page]      the Player (quickshell/player): the /music library played here, in the bar's theme
                              (albums|artists|tracks|genres|queue|favorites|recent|lyrics|stats|viz|eq|settings)
  player play|pause|toggle|next|prev|stop   transport · status: what plays (--json for the whole state)
  player volume <0-100|±n>|seek <s|±s>|like|shuffle [on|off]|repeat [off|all|one]
  player album|play-album|queue-album "<Artist/Album>"   open, play, or queue an album · playlist <name>
  player search "<text>"      the window on a search · catalog refresh [--full]: the NAS reads /music again
  player eq [on|off|toggle|<preset>|band <1-10> <dB>|preamp <dB>]   the equalizer (no argument: its state and the presets)
  player plex [status|sessions]   what the pipeline told Plex about the player (Tautulli reads it), Plex's Now Playing
  player show|hide|quit       the window back · closed with the music on (the bar gets a button) · stop everything
  torrents browse [page]      the Torrents app: qBittorrent over time (overview|sources|torrents)
  torrents status             the statistics service on the NAS (server/torrents): samples, last one, errors
  torrents summary [range]    ratio, upload and download: all time, in the range (24h, 7d, 30d, 12w, 1y, all), now
  torrents sources [indexer|category|tracker] [range]   where the traffic comes from, with each one's ratio
  torrents top [range] [n]    the torrents that uploaded the most in the range
  torrents sample|restart     read qBittorrent now / restart the service
  torrents install            copy the service to the NAS (server/torrents/install.sh)
  music lidarr-flac-only      every Lidarr quality profile: FLAC and FLAC 24bit only
  music lidarr-monitor <ids> on|off   monitor or not these Lidarr album ids
  music lidarr-search <ids>   monitor these Lidarr albums and search the indexers now
  music lidarr-artists [q]    the artists Lidarr tracks · lidarr-albums <artist|id>: their albums with type, id and
                              why each counts as official (studio, wikidata, wikipedia) or "unofficial"
  music lidarr-artist-set all|<ids> [--monitored on|off] [--new-albums all|none|new]
                              artist settings: whether an album that shows up later gets monitored (and downloaded)
  music lidarr-enforce        every artist on the BArch profile, every official album without a file monitored (the pipeline does it hourly)
  music adopt "<Artist/Album>" <release>   a hand-made album of /music, now on MusicBrainz: merged into itself with that
                              release (MusicBrainz ids and the library's rules on its files, audio never replaced)
  music lidarr-add <mbid> <folder>   track an artist /music already has, at its own folder, with the library's profiles
                              (one Lidarr's metadata server does not know yet waits: lidarr-pending, tried hourly)
  music lidarr-commands       Lidarr's running and recent commands · lidarr-cancel <id> stops one (a RefreshArtist in flight undoes monitor changes)
  music digest [days]         the week of the pipeline in one message (Telegram gets it on Sundays at 18:00)
  music seeds [days] [--live]  the torrents kept seeding until their goal (ratio 2 after 72 h, or 30 days) and the
                              seed history of the ones removed (per tracker); --live adds every torrent in qBittorrent
  music seeds check           the hourly seed check now (deletes what reached its ratio or its time)
  music lidarr-stalled [h]    downloads with no progress for 48 h (or h): the hourly check blocklists them and searches another
  music lidarr-queue          what Lidarr grabbed and is downloading · lidarr-queue-remove <ids>|all [--keep]: drop them (blocklisted)
  music lidarr-release-profiles   what Lidarr never grabs (box sets, discographies, complete collections: kept by the hourly check)
  music lidarr-profiles       the metadata profiles · lidarr-profile <name> --primary Album,EP --secondary Live
                              --statuses Official [--apply all|<artist ids>]: create/update one (and assign it)
  music lidarr-lists          the import lists · lidarr-list <Type> <name> field=value.. [--monitor none|specificAlbum|entireArtist]
                              e.g. lidarr-list LastFmUser "Last.fm" userId=bruno count=50
  music install               copy server/music to the NAS (server/music/install.sh)

Automation (agent/rules.json + agent/events.py, barch-events.service):
  rules list                  the rules, enabled or not, when each fired last
  rules test <event> [k=v..]  which rules an event would hit (nothing runs); rules test metric <name> <value>
  rules fire <id> [k=v..]     run a rule's actions now (what the "Run" button of an ask rule does)
  rules enable|disable <id>   flip a rule in rules.json (the daemon reloads it)
  events status|log [n] [--filter text] [--since 24h]
                              the daemon, the last events (windows, monitors, VPN, network, lock,
                              failures, boots, Claude cost, rules fired)
  metrics list                every metric with its last value
  metrics series <metric> [--since 24h|7d|30d] [--points N]
                              a time series (raw for a week, hourly averages for a year)
  metrics summary             boot time, failures per week, Claude cost, temperatures now
  nas status [--no-certs]     the NAS now, through Unraid's API (agent/nas.py): array, disks, pools,
                              containers down or with an update, Unraid's unread warnings, days left
                              on the certificates; barch-events samples the same (nas.* rules)
  nas setup                   write ~/.config/barch/nas.json (URL and API key from Homepage's Unraid widget)
  disk status                 the local disks (agent/disk.py): SMART of each (temperature, wear, spare, media
                              errors, self-test), the btrfs error counters and the last scrub, from the hourly
                              dump of barch-disk-health (root, system/); barch-events samples the same
                              (smart.* and btrfs.* metrics, disk.* and btrfs.* rules); exit 1 with problems
  fw status [site]            the pfSense firewalls (omni, chaos) through their REST API (agent/pfsense.py):
                              load, gateways, interfaces, IPsec tunnel, DNSBL alive, blocked connections;
                              barch-events samples the same (fw.* rules: down, reboot, gateway, tunnel, new device)
  fw clients [site]           the DHCP leases by interface, who is online · fw blocked [site] [n]: the last blocks
  fw setup                    how to make the read-only API users and keys, and what ~/.config/barch/pfsense.json holds
  rgb [status]|apply|on|off   the Corsair keyboard and mouse in the theme's color (agent/rgb.py, ckb-next;
                              barch-rgb.service repaints on theme changes and after a resume)
  rgb color <tone|#hex>       a palette tone (accent, green, red...) or a fixed color
  rgb brightness <0-100>      rgb flash [tone|#hex] [times]   blink, then back (for rules)
  drop [status]               BArch Drop (agent/drop.py, barch-drop.service): files and links from the iPhone over
                              the LAN into ~/Downloads/iPhone (text to the clipboard); the last ones received
  drop setup                  the page link (QR code) and the share sheet Shortcut, with the URL and token
  drop open                   the folder they land in

Agent:
  agent list                  scheduled tasks, last result and next run
  agent run <task> [--quiet]  run a task now (read-only; --quiet: no notification)
  agent report <task>         print the last report of a task
  agent dismiss [<task>|all]  the last report (warn, alert) stops asking for attention in the
                              Center and the Inbox; the report stays
  agent continue <session>    open a task's session in Claude to talk about it
  agent ask [text] [--continue]
                              open Claude in a terminal in the repo, starting with TEXT if given
                              (--continue: resume the last session there; the launcher's "a ")
  agent investigate <log>     open Claude on a saved failure log (the "Investigate" button)
  aur review                  review the PKGBUILD changes of pending AUR updates, print the
                              verdicts (exit 4 if something needs a look)
  snapshot list               safety snapshots taken around Claude sessions in ~/BArch
  snapshot hook               Claude Code SessionStart/SessionEnd hook (reads JSON on stdin)
  failure <unit> [--system]   OnFailure handler: save the log and notify (used by systemd);
                              a Hyprland crash groups its casualties into one notification
  failure list [<unit>]       the saved failure logs, newest first
  failure dismiss|delete [<unit>|all]
                              dismiss: the logs stay but stop counting in the Center and the
                              Inbox; delete: the logs are removed

Backup (restic, encrypted, to the NAS; list: backup/include.txt in the repo):
  backup init                 create the repository and the password (printed once: keep it in
                              Bitwarden; without it the backup cannot be read)
  backup run [--prune]        back up now (barch-backup.timer does it daily at 13:00; old
                              snapshots are pruned on Sundays, or with --prune, and a tenth of the
                              data is read back and verified: the whole repository every ten weeks)
  backup check [--full|--read-data <subset>]
                              verify the repository now: structure, and the data (10% by default,
                              --full reads everything; restic's n/t, x% or a size)
  backup status               last run and the timer's next run
  backup list                 snapshots
  backup restore [SNAPSHOT] <path>... [--target DIR]
                              restore paths (absolute, as they were) from SNAPSHOT (default
                              latest) into DIR (default ~/Restore/<snapshot>, never in place)

Media:
  replay share [file] [--from T] [--to T]
                              the replay (default: the newest in ~/Videos/Replays) as an MP4 for
                              WhatsApp status and the like: H.264, ≤1080p30, HDR tone mapped to
                              SDR, at most 60 s; T is seconds, M:SS or H:MM:SS. Writes
                              <name>-share.mp4 next to it
  applio [open|start|stop|status]
                              Applio (RVC voice conversion, ~/Applications/Applio) as a
                              background web server on :6969: open starts it and opens the
                              browser; an icon in the bar's tray while it runs; stop ends it
  mic toggle|start|stop|status
                              record the microphone (Super+R): 48 kHz mono 24-bit WAV in
                              ~/Recording, a red mic and the time in the bar while it runs

Finance:
  finance import [--dry-run] [--keep] [--yes] [--dir DIR] [--seed]
                              consolidate the C6 Bank files in ~/.config/firefly/learning (CSV,
                              invoice PDFs, screenshots of the open invoice) into Firefly: asks
                              what it does not know, skips what is already there, then moves the
                              files to processed/ (--seed: mark the inbox as done, import nothing)

  help                        this text

  --json   machine-readable output (desktop commands, agent list/run, aur review, snapshot list,
           replay share, rules/events/metrics)

Exit codes: 0 ok, 1 refused or failed, 2 usage error, 3 the bar is not reachable,
4 (aur review) something needs a look before updating.
EOF
}
