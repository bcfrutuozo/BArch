# BArch

Bruno's Arch Linux desktop: Hyprland (Lua config), a Quickshell bar that replaces most of a
desktop environment, one theme for everything (Dracula at night, Catppuccin Latte by day), and
the system pieces that make this machine boot, update and recover the way it does.

## Everyday use

```bash
cd ~/BArch && ./scripts/sync.sh "what changed"     # never with sudo; it asks where needed
```

Runs `scripts/check.sh` first (bash -n and shellcheck on every script, `luac -p` on the Lua
config, jq on the JSON files, `systemd-analyze verify` on the user units, every agent task has
its timer listed, `hyprctl configerrors`; it stops on the first problem, `BARCH_NO_CHECK=1`
skips it), then refreshes the package lists and the system snapshot (`system/files`), commits
and pushes. Updates are done from the bar (**Update All**), not by hand: it shows unread Arch news first,
has Claude review the PKGBUILD changes of the AUR updates (and asks before going on if anything
looks suspicious), runs `paru -Syu` and then `kernel-update` when there is a new CachyOS kernel.

## What's inside

Each top-level folder is a [GNU Stow](https://www.gnu.org/software/stow/) package that mirrors
`$HOME`. The real files live here and their usual paths are symlinks, so editing
`~/.config/hypr/...` edits the repo. The list lives in `scripts/lib.sh` (`PACKAGES`).

| Folder | Goes to | What it is |
|---|---|---|
| `hypr/` | `~/.config/hypr` | Hyprland (Lua, split in `conf/`), hypridle, `scripts/lock.sh` (locks; starts and supervises the resident lock process); `settings.json` is what the Hyprland Settings app saved (below) |
| `quickshell/` | `~/.config/quickshell` | The bar and everything around it (see below); `theme/palettes.json` + `theme/Theme.qml` are the central theme, `palette/` the palette editor, `hypr/` the Hyprland Settings app, `center/` the System Center, `backup/`, `packages/`, `mixer/` and `music/` the other apps, `voice/` the voice control daemon, `ui/` the controls they all share (linked into each) |
| `foot/` | `~/.config/foot` | Terminal |
| `nvim/` | `~/.config/nvim` | Neovim for C#/Avalonia and C++ (LSP, debug, build/run/test) |
| `mpv/` | `~/.config/mpv` | Video player (HDR, NVDEC) |
| `uwsm/`, `environment/` | `~/.config/uwsm`, `~/.config/environment.d` | Session environment (Qt theme, cursor) |
| `systemd/` | `~/.config/systemd/user` | User services (cliphist, replay, NAS mount, voice control) |
| `bin/` | `~/.local/bin` | `barch` (CLI, below), `kernel-update`, `theme-auto`, `apps-theme`, `papirus-accent`, `nas-mount`, `keyring-wait`, `gsr-replay-saved` (the notification after a replay or recording is saved) |
| `claude/` | `~/.claude/settings.json` | Claude Code settings: the hooks that take the safety snapshots (see Agent) |
| `games/` | `~/Games/battle.net/run.sh`, `~/.config/gamemode.ini`, `~/.local/share/applications/steam.desktop` | Battle.net launcher (umu + Proton-GE), gamemode rules, Steam launcher without `GDK_SCALE` (Steam would scale twice) |
| `calendar/` | `~/.config/khal`, `~/.config/vdirsyncer/config` | iCloud calendar sync (the app password stays out of the repo) |
| `audio/` | `~/.config/pipewire`, `~/.config/wireplumber` | PipeWire rates and resampler, onboard output at 32-bit/192 kHz, Bluetooth output-only at AAC (below), fifine mic as input only |
| `backup/` | — | `barch backup`: what restic saves to the NAS (`include.txt`, `exclude.txt`), see Backup |
| `finance/` | — | `barch finance import`: C6 Bank statements into Firefly III (data stays in `~/.config/firefly`) |
| `agent/` | — | Scheduled agent tasks (`tasks/`), the reactive rules (`rules.json`) and their daemon (`events.py`), the failure ignore list and the upstream watch list; used by `barch` |
| `server/` | NAS | `music/`: the music pipeline (beets container), downloads to `/music` in the library's style with a review queue (`barch music`, see Music); `unraid/`: the SMBus driver OpenRGB needs there, built per Unraid kernel (see NAS) |
| `tools/` | — | Generators: wallpapers (`make_wallpapers.py`, sixteen scenes in the colors of each palette), Limine theme (`limine-theme.py`) |
| `system/` | `/etc`, `/boot`, `/usr/local/bin` | Snapshot of system files (copied, never linked); list in `SYSTEM_FILES` |
| `packages/` | — | Explicitly installed packages (`pacman.txt`, `aur.txt`, `aur-ignore.txt`) |
| `scripts/` | — | `sync.sh` (save), `check.sh` (static checks), `collect-system.sh` / `apply-system.sh` (`system/`), `update-packages.sh`, `lib.sh` (`PACKAGES`, `SYSTEM_FILES`, services); `bootstrap.sh` adopts configs that already exist on a configured machine into the repo (`--dry-run` first) |

Folders that don't exist on a machine are simply skipped.

## The bar (Quickshell)

Press **Super+/** for the full, always up-to-date list of shortcuts (Hyprland and Neovim tabs).
The main pieces:

- **Workspaces** with the icons of the apps on each one; **Alt+Tab** with live previews (releasing
  Alt swaps the chosen window into the current one's place; Space only focuses); **Super+Tab** or the
  top-right corner of the main monitor opens the workspace overview (drag windows between workspaces).
- **Launcher** (Super+Space): apps, `w` windows, `c` clipboard with image thumbnails (Super+V),
  `p` git projects, `/` files, `:` emoji, `?` web, `=` calculator, `>` run, `a` Claude (Super+A;
  asks in a new session in `~/BArch`, Shift+Enter continues the last one), `b` wallpapers (below);
  OCR, color picker, QR.
- **Window tools:** minimize (Super+M, comes back to its own workspace), always on top
  (Super+Shift+P), right-click menu on any window preview, swap/resize with Super+Shift/Ctrl+arrows.
  Alt+Tab and Super+Tab reach the remote machine when Parsec's immersive mode is on
  (`hypr/scripts/passthrough.sh`: an X11 window holding the keyboard gets the shortcut instead of
  Hyprland, since Xwayland's grab never reaches the compositor).
- **Control Center:** Light / Dark / Auto, Display (HDR, SDR brightness, side monitor on/off,
  Themes, Wallpaper), Bluetooth, Caffeine, Night Light, Do Not Disturb, Anonymous Mode and VPN Region (below), Game HDR,
  Game HUD (MangoHud), Screenshot, screen Recording (full screen or region).
- **Anonymous Mode** (`quickshell/anon/`): one tile for the VPN plus what would still give the machine
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
- **Firewall** (`system/files/etc/nftables.conf`, `nftables.service`): nothing in, everything out,
  the policy of Omarchy's UFW setup, in nftables. Incoming: loopback, answers to what this machine
  started, ping and the ICMPv6 that IPv6 needs, DHCP answers, libvirt guests and Docker containers
  talking to the host; the rest is dropped. Forward: guests and containers out; a published
  container port is reachable from the local networks only, never from the internet (what
  ufw-docker gives Omarchy). Only its own table (`inet barch`) is managed, so libvirt's and Docker's
  tables and the kill switch survive a reload. No SSH or LocalSend rules (sshd is off here,
  LocalSend is not installed); mDNS discovery (Chromecast) and Steam's local transfers are not
  opened either. `sudo nft list table inet barch` shows it with counters.
- **VPN** (`quickshell/vpn/`, what Anonymous Mode uses; `barch vpn` drives it alone): Private
  Internet Access over WireGuard, without root. `pia.sh` gets a token from the PIA API, registers a
  fresh key pair on the chosen server and writes the answer into
  a NetworkManager profile owned by the user (`connection.permissions`), so `nmcli` brings it up
  with the session's polkit rights. Region "Auto" is the lowest latency measured at that moment;
  the VPN Region tile lists them all with a filter, fastest first. DNS is exclusive and IPv6 is
  routed into the tunnel (dropped there) while connected. A shield with the country shows in the
  bar while connected (click: IP, time, Change region, Disconnect). Credentials go in `~/.config/pia/credentials`
  (username and password, one per line, `chmod 600`), never in the repo.
- **Wallpapers** on every monitor (a background layer, no hyprpaper), drawn by
  `tools/make_wallpapers.py` in the colors of every palette of the theme: it reads the palettes
  from `theme/palettes.json` and derives sky, light, water, trees and so on from their ten tones, so
  a dark palette renders the night (moon, stars) and a light one the day (sun). Sixteen scenes
  (Mountains, Waves, Dunes, Forest, City, Aurora, Lake, Hills, Clouds, Mesa, Retro, Polygons, Mesh,
  Nebula, Bokeh, Contours), each in `~/Pictures/Wallpapers/<palette>/<scene>/` as `primary.png`
  (main monitor), `secondary.png` (portrait), the small pre-blurred `*-lock.png` copies for the lock
  screen and a `thumb.png`. The bar shows the folder of the palette in use, crossfading when the
  mode or the pinned palette changes; a palette without a folder yet uses Dracula or Latte
  meanwhile and gets rendered in the background the first time it is pinned (about a minute,
  with a notification; `barch wallpaper render [palette|all]` does it by hand). The launcher's `b `
  mode (also the Wallpaper tile in the Control Center) lists the scenes with thumbnails and marks
  the ones in use; Enter asks where to apply it (desktop and lock screen, desktop only, lock
  screen only), Shift+Enter applies it to both. The choice lives in
  `~/.local/state/quickshell/wallpaper.json` (`barch wallpaper`), which the lock screen watches,
  so the two can differ. `make_wallpapers.py ~/Pictures/Wallpapers [-p palette]... [scene...]`
  regenerates them (a new scene is a function in `SCENES`; a new palette in `palettes.json` is
  enough, and a palette saved in the editor renders its set by itself).
- **Hyprland Settings** (`quickshell/hypr/`, its own Quickshell window: "Hyprland Settings" in the
  launcher, `barch hypr [page]`): every config option of the Hyprland version installed, read from
  `hyprctl descriptions` (name, description, default, current value, range, enum) and typed with
  the Lua stubs Hyprland ships (`/usr/share/hypr/stubs/hl.meta.lua`), so nothing is hardcoded
  and a new release shows its new options by itself. Sections in a sidebar, search across all of
  them, and each option gets the control its type asks for: switch, slider + field, enum,
  color (hex + hue/saturation/lightness/alpha popup), gradient (stops + angle), gaps (one or four
  values), vec2, text with the choices the description lists. Every row says where the value
  comes from (`conf/look.lua:9`), what Hyprland's default is, whether the bar's theme owns it
  (border colors, rounding, background: change those in the palette editor) and has a reset.
  More pages: **Monitors** (every field of `hl.monitor` per output, with the modes the output
  reports), **Key binds** (everything `hyprctl binds` knows; add binds that run a command or a
  Lua dispatcher, with flags and the `Group|Name` description of the shortcut sheet; turn a
  bind of the files off with `hl.unbind`), **Animations** (the tree with enabled/speed/curve/style,
  the bezier curves drawn, new beziers and springs), **Rules** (window, layer and workspace: the
  files' ones read-only with their line, the app's ones editable as match + properties),
  **Devices** (`hl.device` per input device), **Startup** (commands at session start, environment,
  gestures), **Idle & lock** (`hypridle.conf`: lock, sleep and inhibit commands, the listeners
  with their timeouts, presets for lock / screen off / suspend; edited in place, comments kept,
  hypridle restarted), **Night light** (`hyprsunset.conf`: the profiles by time of day, no filter /
  temperature / gamma, hyprsunset restarted) and **Files** (the Lua files, config errors, the
  app's own file).
  The hand-written Lua is never edited: what you change goes to `hypr/.config/hypr/settings.json`
  (saved with the repo) and `conf/settings.lua`, required by `hyprland.lua`, applies it on top of
  the files, so a reload or a fresh install keeps it; a reset removes the entry and the files'
  value is back. Options, monitors, animations and devices apply live (`hyprctl eval` into
  `BArch.settings.apply`, since the Lua config has no `hyprctl keyword`); binds, rules and
  gestures reload Hyprland; environment waits for the next start. `barch hypr get|set|reset|list|status`
  does the same from a shell (`barch hypr set general:gaps_out 10`, `barch hypr reset all`), and
  the app follows the file while open.
- **System Center** (`quickshell/center/`, own window: "System Center" in the launcher, `barch center [page]`):
  the agent infrastructure and systemd in one place. **Overview** (the bar's health check with a
  Check now, failed units, failures in the last day, the latest report of every agent task, the
  next timers), **Services** (user and system units with state and enabled state, journal, start /
  stop / restart / reset-failed / enable / disable; system units go through polkit, so the bar's
  agent asks the password), **Timers** (both scopes, next and last run, run the service now),
  **Failures** (the logs `barch failure` saved, grouped by unit: view, Investigate with Claude,
  delete; the ignore list `agent/failure-ignore` editable), **Agent** (ask Claude, each task with
  its timer, last result, Run now, the report in a side panel, Continue the session, history of
  reports), **Automation** (the rules of `agent/rules.json` with a switch each, Run now, when
  each fired last, and the event log of `barch-events`, see Automation below), **History**
  (the machine over time from `metrics.db`: boot time, failures per week, what Claude cost,
  temperatures, load, GPU power, network latency, disk, any metric, in 1 h to 30 d ranges),
  **Snapshots** (the pre/post pairs of the Claude sessions: Status and Undo open a
  terminal with the `sudo snapper` command, copy it, resume that session) and **Journal** (this
  boot, by priority, unit and regex). Nothing is reimplemented: it runs `systemctl`, `journalctl`
  and `barch --json …` and refreshes every 30 s.
- **Backup Browser** (`quickshell/backup/`, "Backup Browser" in the launcher, `barch backup browse`):
  the restic repository on the NAS. Status of the last run (files, data added, snapshot, next
  timer), every snapshot with its summary (size on demand), and **Browse & restore**: the files
  of a snapshot as a tree listed on demand (`restic ls` per folder), a search (`restic find`),
  tick files or folders and Restore puts them under `~/Restore/<snapshot>-<time>/` with their full
  paths, never in place; Run backup now, check and unlock open a terminal. Same repository,
  password file and cache as `barch backup`; it never deletes anything.
- **Packages** (`quickshell/packages/`, "Packages" in the launcher, `barch packages`): what pacman
  knows. **Installed**: explicit, AUR, orphans or everything, with description, size, install date,
  details and file list on the right; remove (`pkexec pacman -Rns`, with the list of what would go
  first; polkit asks the password), mark as explicit / dependency, install through paru in a
  terminal. **Updates & lists**: pending updates (checkupdates and paru -Qua; Update All is the
  bar's flow), `.pacnew` files (pacdiff in a terminal) and whether `packages/pacman.txt` and
  `aur.txt` match what is explicitly installed, with a button that regenerates them (the
  removal does it by itself). **History**: the pacman log, newest first, by action and name.
- **Music** (`quickshell/music/`, "Music" in the launcher, `barch music browse [review|albums|lidarr]`): the
  music pipeline on the NAS (see Music) through its API. **Review**: the queue, and for each album what
  the pipeline found (the download, the problems, the MusicBrainz candidates with why they fit, the
  merge plan for an album already in the library, the proposed files, the log, the cover) and the
  inputs of `barch music resolve` as a form: Use a candidate or a release found with the
  MusicBrainz search right there, date (or the year-only last resort), genre, album, artist folder,
  the cover (a URL, or **Upload…** an image found online: checked, kept with the job and shown at
  once; **Find cover** sends Claude to search the web for it, `barch music cover-ask <id>`, which
  the `music-cover` rule already does by itself for every album that waits only for a cover),
  a title per track, keep the download's order, replace the album, the tracks to swap
  for the download's (the merge's suggestions are switches); the equivalent command is shown under
  it, Resolve queues the album again, Retry and Reject next to it. **Fix with Agent** (`barch music
  fix <id> ["hint"]`, prompt `quickshell/music/job-fix.md`) hands the album to Claude: it gets the
  whole job, researches MusicBrainz, Wikipedia, Discogs and the web, decides what you would
  (release, date, genre, cover, the merge, a folder of its own for a same-title album) with the same
  `resolve` and `cover` commands, waits for the run and goes on with the next problem until the album
  is in, never rejecting and never replacing your audio on its own; the answer says what it found and,
  if something is left, the one decision that is yours. **Albums**: every job by state,
  Undo for a delivered one. **Covers**: the covers already in the library, one artist at a time
  (picked from the list of `/music`, filtered as you type, then Check; nothing is shown before that):
  the ones that are a scan of the sleeve with a frame next to the clean artwork of the same album,
  Replace (cover.jpg, the picture embedded in every track and Plex's poster), Keep mine, Undo; every
  candidate found is shown too (a click makes it the proposal), and when none is right, a sentence
  about what is wrong goes to **Ask Claude** (`barch music covers ask`, prompt in
  `quickshell/music/cover-ask.md`): it looks at the images, adapts one with ImageMagick or searches
  the web for another, and adds it as the proposal (Replace is still yours).
  **Lidarr & scan**: scan now, FLAC only, monitor / search album ids.
- **Audio Mixer** (`quickshell/mixer/`, "Audio Mixer" in the launcher, `barch mixer`): PipeWire through
  `Quickshell.Services.Pipewire`. **Devices**: outputs and inputs with volume, mute, a peak
  meter, their format (`s32le 2ch 192000Hz`) and the default. **Apps**: every stream playing or
  recording with its own volume and a combo that moves it to another device (`pactl
  move-sink-input` with the object serial, which WirePlumber remembers for that app).
  **Settings**: the graph rate and a forced sample rate or quantum (`pw-metadata` settings,
  live, until PipeWire restarts; the permanent values stay in `audio/`), the Bluetooth codec and
  profile of a connected headset, pavucontrol / qpwgraph if installed.
- **Voice control** (`quickshell/voice/`, `barch voice`, tile **Voice** in the Control Center): the
  microphone is always open, like in a car, and nothing happens until a sentence starts with
  "barch" (see Voice below). A microphone shows in the bar while the service runs: dim while it
  only listens, pulsing in the accent color after "barch" alone (it chimes and waits for the
  sentence), steady while it understands or asks Claude, green while it speaks, red when
  whisper.cpp or the microphone is missing; what it understood shows next to it for a few
  seconds. Click pauses and resumes the listening, right-click shows the last sentence and answer
  and the **language** it listens in (a list with a filter: every language whisper knows, see Voice).
- **Polkit agent** (`Quickshell.Services.Polkit`, no hyprpolkitagent): the password dialog apps get
  when they ask for privileges (`pkexec`, GNOME Disks, …), in the bar's theme.
- **Own notification server** with history, DND, sounds and app actions; privacy indicator
  (mic, camera, screen sharing); ShadowPlay-style replay (off at login,
  Super+Alt+R turns it on, Alt+F10 saves); weather with rain alerts;
  iCloud agenda in the clock's calendar; quick notes (Super+N); session restore at login.
- **Lock screen** (`quickshell/lock/`, Super+L, idle and login): blurred wallpaper per monitor, clock,
  date and weather, notifications that arrived while away, music playing; follows the theme live
  through `~/.local/state/quickshell/theme.json` and shows the scene chosen for it in
  `wallpaper.json`. It is its own Quickshell process, so it does not
  fall with the bar, and it stays resident: `scripts/lock.sh` starts it at login and every lock
  request (hypridle, Super+L) is just `ipc call lock lock`, so the screen is up as soon as each
  monitor draws a frame instead of after a Quickshell start. The wallpapers it shows are small,
  pre-blurred copies (`<palette>/<scene>/primary-lock.png`, `secondary-lock.png`, made by
  `make_wallpapers.py`), and everything fades in together. It is the only locker: if the
  process dies while locked, `lock.sh` starts it again and locks it again (Hyprland allows a new
  lock to take over), slowing down to one try every 10 s after three quick failures. If it was
  Hyprland that died, `start-hyprland` brings it back in safe mode with the session locked and
  no lock client is accepted (safe mode ignores the config); `lock.sh` logs that and stops: log
  in on a tty and run `uwsm stop`;
  **Super+Ctrl+Alt+L** kills and relaunches it by hand (works while locked, for a red/black or
  frozen screen; while unlocked it is how an edit under `lock/` is applied, since the resident
  process does not watch its files). `qs -p ~/.config/quickshell/lock ipc call lock state` shows
  what it thinks.
  PAM: `/etc/pam.d/barch-lock` (in `system/`; the plain `login` stack until it is installed). It also
  unlocks the GNOME keyring (`pam_gnome_keyring`): with autologin nothing else does, so apps that
  need a secret at startup are held until then with `keyring-wait` (Nextcloud: drop-in in `systemd/`)
  instead of asking for the keyring password at every login.
  To look at it without locking: `lock/preview.sh` (a normal window with its own Shell ID).
- **System health:** `.pacnew` files, failed services, TPM fallback warning, the daily backup (failed
  or more than two days old) and a monthly cleanup. **Automation** (`barch-events`, see below):
  metrics history, the event log and the rules of `agent/rules.json` (disk full, VPN dropped,
  game opened, monitor plugged…), shown in the System Center.
- **Bluetooth audio** (`audio/`): headsets are output only, AAC first (then SBC-XQ, SBC); the
  headset profile (HFP/HSP, 16 kHz mono) is out of the roles and the automatic switch to it is off,
  so an app opening the microphone (Discord, a call) never degrades the music: the fifine is the
  microphone. The connected device shows its codec in the Bluetooth tile and in the bar's device list.
- **Updates:** pending packages, unread Arch news (also enforced by a pacman hook) and the kernel.
- **Smaller widgets:** media player in the clock island (MPRIS, shows only while something plays);
  system monitor (CPU, GPU, RAM bars; click for temperatures, VRAM, GPU power; right-click btop);
  disks (turns yellow/red as one fills; click a mount to open it); virtual machines (libvirt: start,
  console, pause, reboot, shut down); AirPods (`pods/`, from [omarchy-pods](https://github.com/thisisgm/omarchy-pods): battery,
  listening mode; its daemon `librepods`/`librepods-ctl` is built into `~/.local` by `install.sh`
  at the commit pinned there, `PODS_COMMIT`).

## barch CLI

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
barch hypr get|set|reset|list|status [<option>] [<value>]   # the same file from a shell (see The bar)
barch center [<page>]              # System Center: services, timers, failures, agent, snapshots, journal
barch backup browse [<page>]       # Backup Browser: snapshots, files, restore into ~/Restore
barch packages [<page>]            # Packages: installed, orphans, updates, pacnew, repo lists, history
barch mixer [<page>]               # Audio Mixer: devices, per-app volume and routing, sample rate
barch hdr on|off|status            barch sdr <nits>|status
barch monitor side on|off|status   barch caffeine on|off|status
barch nightlight on|off|status     barch dnd on|off|status
barch anon on [region]|off|toggle|status   # Anonymous Mode: VPN + kill switch + Mullvad Browser as default + hostname out of DHCP
barch vpn on [region]|off|toggle|status|regions|region <id>|auto
barch health [--refresh]           # .pacnew, failed services, TPM, backup, cleanup
barch voice on|off|toggle|status   # always-on voice control (see Voice); pause|resume keep the service
barch voice match "abre o terminal"  # which command a sentence hits, running nothing · test "..." runs it
barch voice say "texto"            # speak · reload (commands.json) · log · setup [--install]
barch voice lang [<code>|list]     # the language it listens and answers in (pt, en, es, auto…)
barch backup init|run|status|list|restore [SNAPSHOT] <path>...   # restic to the NAS (see Backup)
barch rules list|test <event> [k=v..]|fire <id>|enable|disable <id>   # agent/rules.json (see Automation)
barch events status|log [n] [--filter x] [--since 7d]   # the daemon and what happened (windows, VPN, boots, costs…)
barch metrics list|series <metric> [--since 24h]|summary   # metrics.db: temperatures, load, boots, failures, Claude cost
barch agent ask "why is X slow?"   # Claude in a terminal in ~/BArch (the launcher's "a ")
barch agent list|run|report|continue <task>   # scheduled tasks (see Agent)
barch failure <unit> [--system]    # what OnFailure= calls: log + notification (see Agent)
barch snapshot list                # safety snapshot pairs of the agent sessions
barch aur review                   # verdict on the pending AUR updates
barch finance import [--dry-run]   # C6 Bank statements → Firefly (see Finance)
barch music status|browse|list|show|resolve|retry|reject|scan   # the NAS music pipeline and its review queue (see Music)
barch music covers check [artist]|list|apply|undo|keep|pick|propose <Artist/Album>   # scans with a frame -> the clean artwork
barch music covers ask <Artist/Album> "keep the red frame"   # Claude adapts one or finds another, as a proposal
barch music cover <id> <file|URL> [label]   # the cover you found for an album waiting on it: checked, then the album runs
barch music cover-ask <id> ["hint"]   # Claude searches the web for it and runs the album (the music-cover rule does this alone)
barch music fix <id> ["hint"]         # Fix with Agent: Claude takes the album over (release, date, cover, merge) until it is in
barch music rescan <id>               # the download taken in again from scratch (a torrent split wrong by an older version)
barch music lidarr-artists|lidarr-albums <artist>|lidarr-search <ids>|lidarr-profile <name> ...|lidarr-list <Type> <name> field=value..
                                   # what Lidarr tracks, search albums, metadata profiles (studio albums only), import lists
barch music lidarr-queue|lidarr-queue-remove <ids>|all|lidarr-commands|lidarr-cancel <id>   # what Lidarr is downloading and running
barch music lidarr-enforce         # the library's rule on every artist now: BArch profile, every album without a file monitored (hourly by itself)
barch music lidarr-artist-set all|<ids> --new-albums all|new|none [--monitored on|off]   # what happens to an album that shows up later
barch replay share [file] [--from 12 --to 40]
                                   # newest replay (or FILE) → <name>-share.mp4 for WhatsApp status:
                                   # H.264 ≤1080p30, HDR tone mapped to SDR, at most 60 s
```

Every command takes `--json`. Exit codes: `0` ok, `1` the bar refused, `2` usage, `3` bar not reachable.
On the QML side these are the `IpcHandler`s `control`, `theme`, `wallpaper`, `notifs`, `health`, `vpn`, `anon` and `voice` (`qs ipc show`).

## Agent

Claude Code works on this machine on its own, read-only unless you are in the session:

- **Failure → agent.** Every service that fails (system or user, through an `OnFailure=` drop-in
  in `service.d/`) is handed to `barch failure`: it saves the status and the journal of the failed
  run to `~/.local/state/barch/failures/` and notifies with **Investigate** (opens Claude in a
  terminal, already reading the log) and **Show log**. Every failure's log is kept, but a unit
  notifies at most once every 30 min; repeats inside that window are counted and the next
  notification says so ("failed (4× since 21:16)"). `agent/failure-ignore` skips units (apps
  launched by uwsm, barch's own). When it was Hyprland that died (uwsm restarts it in place),
  the user services that only lost their compositor (portals, cliphist, hyprsunset) are not
  reported one by one: their logs are saved and, 30 s later, one notification says "Hyprland
  crashed at 10:58" with the list, and its log (`failures/hyprland-<stamp>.log`: coredumps,
  crash report, journal of the session unit) is what **Investigate** opens. `vdirsyncer` skips
  its run quietly while iCloud cannot be resolved (VPN switching, link down) instead of failing.
- **Safety snapshot.** Every Claude session started in `~/BArch` takes a snapper pre snapshot of
  `/` when it starts and a post one when it ends (hooks in `claude/.claude/settings.json` →
  `barch-agent-snapshot@.service`, which polkit lets you start without a password). The agent is
  told the number. The pre is kept out of snapper's number cleanup until its post exists (a day
  at most, for sessions that never end cleanly). `barch snapshot list` shows the pairs; `sudo snapper -c root status pre..post`
  shows what a session changed outside the repo and `undochange` reverts it. `/home` is not in the
  snapshot (the repo has git); sessions in other folders take none.
- **Scheduled tasks.** `agent/tasks/<task>.md` (prompt + allowed tools) and an optional
  `<task>.sh` that collects the facts, run by `barch-agent@<task>.timer` with `claude -p` in
  `dontAsk` mode: only the listed read-only tools work, and edits are denied. The report goes to
  `~/.local/state/barch/reports/` and a notification with **Open report** and **Continue** (resume
  the session to talk about it).

| Task | When | What |
|---|---|---|
| `aur-review` | every 6 h, and in Update All | Reads the PKGBUILD diff of each pending AUR update (source moved, new install script, downloads run at build time, obfuscation, new committer); heuristic flags plus Claude's verdict, cached per AUR commit |
| `kernel-check` | first login with a new kernel | NVIDIA module built and loaded, NTSYNC, BORE, new kernel errors vs. the previous boot |
| `morning` | weekdays 08:00 | Agenda, updates and Arch news, health, overnight failures, disk |
| `weekly-review` | Sundays 18:00 | Recurring journal errors, failures, snapshots, unsaved BArch changes |
| `upstream-watch` | Mondays 09:30 | Hyprland, Quickshell, gamescope and NVIDIA release notes against this config and `agent/watchlist.md` |
| `barch-audit` | monthly | README/CLAUDE.md vs code, unused scripts, package lists, `user-services.txt`, `SYSTEM_FILES` |

```bash
barch agent list                       # tasks, last result, next run
barch agent run morning                # run one now
barch agent report kernel-check        # last report
barch aur review                       # what Update All shows before paru -Syu
```

Each run uses Claude like a conversation would (a task costs roughly what a short session does).

## Automation

`barch-events.service` (`agent/events.py`) is the desktop's event bus, its memory and its reflexes,
without any AI:

- **Metrics**, every 30 s into `~/.local/state/barch/metrics.db` (SQLite; raw samples for a week,
  hourly averages for a year): CPU and GPU temperature, load and power, every hwmon sensor
  (`temp.<name>`), RAM and zram, the disks (`disk.root.pct`, `disk.home.pct`, free GB), ping and
  VPN latency, whether the VPN is up, AirPods battery per side, the health check's issue count,
  and the boot time of every boot (`systemd-analyze`, once per boot).
- **Events**, stored and matched as they happen: Hyprland's socket2 (`window.open`,
  `window.close` with class and title, `window.fullscreen`, `window.urgent`, `monitor.added`,
  `monitor.removed`), `vpn.up`, `vpn.down` (the tunnel dropped) and `vpn.off` (turned off: Disconnect, Anonymous Mode off, a voice command; `pia.sh disconnect` leaves the time in `stopped`), both with the tunnel that went away and whether the kill switch is holding the traffic, `anon.on`/`anon.off`, `net.up`/`net.down` (default
  route), `pods.connected`/`pods.disconnected`, `session.locked`/`unlocked`, `failure` (a new
  log from `barch failure`), `boot`, `claude.cost` (every agent task run and voice fallback writes
  a line to `~/.local/state/barch/claude-cost.log`), `music.review` (an album of the NAS music
  pipeline landed in the review queue, polled every 2 min: id, name, problem, `cover_only`), `startup`.
- **Rules** in `agent/rules.json`: `when` is an event name plus regexes on its fields
  (`{"event": "window.open", "class": "^steam_app_"}`) or a metric with `above`/`below` and a
  `clear` value for hysteresis (`{"metric": "disk.root.pct", "above": 90, "clear": 85}` fires once
  when crossed and re-arms below 85); `do` is a list of shell commands with `{field}` placeholders
  (shell-quoted; the fields also come as `EVENT_*` variables), `notify` a notification, `say` a
  sentence through `barch voice say`, `ask` a notification with a **Run** button instead of acting,
  `cooldown` how long before it may fire again, `critical` and `enabled`. The daemon reloads the
  file when it changes. It ships with: disk above 90 %, CPU above 90 °C, GPU above 85 °C, VPN
  dropped (spoken), network down and back, AirPods below 20 % per side, monitor connected or
  removed, a boot over 60 s, a Claude call over a dollar and an album of the music pipeline waiting
  only for a cover (`music.review` with `cover_only`: Claude searches the web for it, `barch music
  cover-ask`, in a transient unit so the daemon never waits); two disabled ones keep caffeine on
  while a game window is open (Bruno wants notifications while playing, so no DND there).

```bash
barch rules list                              # every rule, enabled or not, when it fired last
barch rules test window.open class=steam_app_1 # which rules would fire (nothing runs)
barch rules test metric disk.root.pct 95
barch rules fire game-opened                  # run a rule's actions now (the Run button)
barch rules disable monitor-added             # flips "enabled" in rules.json
barch events log 30 --filter vpn              # what happened; --since 7d
barch metrics summary                         # boot, failures per week, Claude cost, temperatures now
barch metrics series gpu.temp --since 7d
```

The System Center shows the same: **Automation** (rules with a switch each, Run, the event log)
and **History** (the charts). Rules are plain commands, so a rule can also run a scheduled agent
task (`barch agent run …`) or open Claude on something (`barch agent ask "…"`).

## Finance

`barch finance import` consolidates C6 Bank statements into Firefly III
(`https://firefly.frutuozo.com.br`). Drop the files in `~/.config/firefly/learning/` and run it:

- the checking account CSV export, the closed card invoices (PDF) and, for the invoice that is
  still open (the app does not export it), screenshots of it with the last two entries of each
  repeated at the top of the next. Claude reads the screenshots; the overlap is merged and each
  card has to add up to the subtotal on screen, or nothing goes in.
- every line is classified with `~/.config/firefly/dictionary.json`, learned from the Firefly
  history (descriptions, accounts, categories, IOF as a split, the additional card of Beatriz as one
  entry per invoice, investments left out). Unknown lines are asked in the terminal and learned;
  names whose description changes per purchase (Amazon, Mercado Livre…) are always asked, with
  the last one pre-filled.
- lines already consolidated are skipped (a ledger of lines seen, plus the same amount on the same
  account a few days around in Firefly), so repeating a file is harmless. The plan is shown before
  anything is written; afterwards the files move to `~/.config/firefly/processed/<date>/`.
- `Rendimentos (C6 Bank)` and `Rendimentos (C6 Global Invest)` stay manual (internet banking).

Token, `config.json` (URL, PDF password), dictionary and files never enter the repo; the ledger and
the import logs (IDs of everything written) are in `~/.local/state/barch/finance/`.

## Music

`server/music` (details in its README) runs inside the beets container on the NAS and turns every
finished Lidarr download (and any folder dropped in `/data/music-inbox`) into an album of
`/music` exactly like the hand-made ones: lossless only, CUE images split per track, the
MusicBrainz release found by track count and lengths, only the library's tags (artist: the album's on
every track, even one MusicBrainz credits to someone else, extra names going to the title; `Various Artists`
albums keep each track's own and get `ALBUMARTIST`; album, title, numbers, the original date to the day (MusicBrainz, Wikidata, every Wikipedia; YYYY-01-01 only when it exists nowhere and Bruno says so), a genre on every track, two MusicBrainz ids), titles in Bruno's style (his
title-case dictionary, one trailing `[feat. A; B - Bonus - Live]` in a fixed order), a cover of at
least 500 px (1000 px when any source has it) embedded and as `cover.jpg`, the label's clean
artwork before a scan of the sleeve (a store's image counts only with the same artist and album
and when it is visibly the same picture as the scan or the Cover Art Archive's; a scan that still
wins has its frame trimmed), file names with the
library's replacements. Then Lidarr rescans and stops looking for the album, Plex scans, the
torrent is deleted. An album that is already there is completed (the missing tracks only) and
fixed by the library's rules, never replaced, with an undo log; a track of Bruno's that looks wrong
is only swapped with his ok. Anything it cannot do completely (no match, a year-only date, no
cover) waits in a review queue with the reason and the candidates:
`barch music list`, `barch music show <id>`, `barch music resolve <id> --release …|--date …|--cover …`,
all of it in the **Music** app (`barch music browse`), or from the phone: the pipeline serves the same
review queue and resolve form as a page at `http://<nas>:8338/` (asks for the `barch music` token once). On the Lidarr side it enforces the library's rule every
hour: every artist on the `BArch` metadata profile (every distinct album: studio, EP, live, compilation; official only),
new albums monitored, every album without a file monitored once; an album already in the library is completed, and
another album with the same title (the eight "Greatest Hits" of Deep Purple) gets its own folder from the review.

## NAS

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

## Backup

The repo holds the configuration; `barch backup` holds the rest: secrets, per-app state and
personal files, encrypted with [restic](https://restic.net) on the NAS
(`/mnt/nasfrutuozo/organization/desktops/bcfrutuozo/restic`; another path or a restic URL goes in
`~/.config/barch/backup.conf` as `BACKUP_REPO=`). What goes in is `backup/include.txt` (SSH and
GPG keys, PIA, the vdirsyncer password, the keyring, Firefly data and the finance ledger, browser
profiles, Parsec, Steam user data, Claude's project memory, the VM definitions dumped by
`virsh`, Documents, Pictures, Videos); `exclude.txt` drops caches and sockets. The restic
password lives in `~/.config/barch/backup/password` and nowhere in the repo: `barch backup init`
generates it, prints it once, and it belongs in Bitwarden too, because a reinstalled machine
needs it before anything can be restored.

`barch-backup.timer` runs it daily at 13:00 (`Persistent`, so a machine that was off catches
up), keeping 14 daily, 8 weekly and 12 monthly snapshots (pruned on Sundays). The health widget
turns yellow when the last run failed or is more than two days old, and a failed run also goes
through `barch failure` like any other service. `barch backup restore latest ~/.ssh` puts the
files under `~/Restore/<snapshot>/` with their full paths, never in place.

What only root can read goes in through `barch-backup-root.timer` (system unit, daily at 12:30,
script `/usr/local/bin/barch-backup-root`, both in `system/`): the NetworkManager profiles (Wi-Fi
passwords), the SMB credentials, the Secure Boot keys (`/var/lib/sbctl`), the SSH host keys,
root's own keys and a `cryptsetup luksHeaderBackup` of the root disk, written as `system.tar`
and `luks-header-<device>.img` into `~/.local/state/barch/backup/root/` (owned by you, mode
600), which the 13:00 run then encrypts with the rest. Restore them with
`barch backup restore latest .local/state/barch/backup/root` and untar as root.

Not covered: the VM disk images.

## Voice

`barch-voice.service` (`quickshell/voice/voice.py`) keeps the fifine open through PipeWire (its own
node, `barch-voice`, which the privacy indicator ignores) and cuts the audio into sentences with an
energy VAD. Everything runs on this machine: the first two seconds of every sentence go through
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`whisper-server`, kept warm, on the GPU
through `ggml-cuda`) only to see whether it starts with **"barch"**; everything else in the room is
dropped right there. A sentence that does start with it is transcribed whole and goes through
`commands.json`, a table of intents in Portuguese (regexes over the sentence normalized to lower
case without accents, fillers like "por favor" removed) that reach `barch`, `hyprctl dispatch`,
`uwsm app`, `wpctl`, `playerctl` and the bar's IPC without any AI: themes and palettes, wallpapers,
HDR and SDR brightness, side monitor, caffeine, night light, Do Not Disturb, Anonymous Mode and VPN
(with the region: "entra no modo anônimo na alemanha"), windows (close, fullscreen, float, minimize,
pin, swap, focus), workspaces (go, move, next, scratchpad), volume and media, apps ("abre o spotify",
by the name in its `.desktop`, plus the aliases in `app_aliases`: navegador, terminal, arquivos,
mixer, pacotes…), projects ("abre o claude no fragmenta" opens a terminal in `~/Source/Fragmenta`
running `claude`; also a plain terminal, Neovim or the folder of any repo under `~/Source`,
`~/Projects` and `~/BArch`), the bar (launcher, clipboard, notes, shortcuts, overview), lock, suspend,
reboot and shutdown (the last three ask "Confirma?" and wait for a "sim"), the time, the date,
the agenda, updates, disk, what is playing, reminders ("me lembra em dez minutos de tirar o bolo"
through `systemd-run`), and "para de escutar" (pause). "barch" alone chimes and waits up to eight
seconds for the sentence, as in a car.

What the table does not know goes to **Claude** (`claude -p`, `dontAsk`, the tools limited to `barch`,
`hyprctl`, `uwsm app`, `qs ipc`, `wpctl`, `playerctl`, `foot`, `xdg-open`, `systemctl --user` and
reading; `voice/fallback.md` is the prompt, `claude_model` in `config.json` the model, Sonnet by
default), which acts and answers with one spoken sentence; "pergunta ao claude …" forces it. Those
sentences are logged in `~/.local/state/barch/voice/unmatched.log`, which is where new intents come
from. It keeps a short memory, so it works like a conversation: after every answer the microphone
stays open for a few seconds (`followup_s`, 8 by default; the bar's mic pulses slowly) and the next
sentence needs no "barch", but in that window only sentences the table knows are acted on, so talk
in the room is dropped instead of reaching Claude (a follow-up to a Claude answer does reach him,
with the previous exchanges as context: "como está o tempo" … "e amanhã?"). "Ele", "ela", "essa
janela", "isso" are the window it opened or acted on last ("abre o spotify" … "coloca ele no
workspace dois" … "fecha ele"; the window of an app just launched is found by watching for the
new client), and windows can be named ("fecha o spotify", "volta pro brave", "cadê o terminal":
class, alias or a word of the title). "Mais", "menos", "de novo" repeat the last command a step
further or in the other direction (volume, SDR brightness, tracks, workspaces: `adjust`,
`inverse` and `direction` in `commands.json`); the same answer twice in a row becomes a chime. When
the fallback is about to do something he may regret (close or kill something, suspend, leave
Anonymous Mode, change Hyprland options, delete files) Claude does not act: it answers with
`confirm`, the daemon says it with "Confirma?" and only a "sim" in the follow-up window sends the
request back, confirmed. Answers are spoken with [Piper](https://github.com/OHF-Voice/piper1-gpl) (`pt_BR-faber-medium`,
downloaded once into `~/.local/share/piper`); commands that need no answer only get a short chime
(`confirm_sound` in `config.json`), the ones that do (anonymous mode, VPN, the time, errors) a
sentence. While the session is locked every sentence is ignored.

**Other languages.** The microphone's panel in the bar (right-click) has a **Language** list with
a filter, the same as `barch voice lang <code>`: Portuguese, Automatic, and every other language
whisper knows (`voice/languages.json`: whisper's hundred, each with the Piper voice that speaks
it, null for the ones Piper has no voice for). The choice is kept in
`~/.local/state/barch/voice/language` and goes to whisper with every sentence. Only Portuguese
has the command table: in any other language the sentence goes, as whisper wrote it, to Claude,
who acts and answers in that language (`language` in the context of `fallback.md`, the
"Confirm?" question written by him too), read by that language's voice, downloaded with
`piper.download_voices` the first time the language is picked (a few seconds; a language
without a voice answers in a notification). The wake word stays "barch": in a language whisper
does not write in Latin letters the start of the sentence is transcribed in English to find it.
**Automatic** transcribes the start in Portuguese, takes the language whisper detects there and
transcribes the whole sentence in it: Portuguese uses the table, anything else goes to Claude
(a short command can be detected as the wrong language, which is why it is not the default).
`tts_voices` in `config.json` (`{"en": "en_US-lessac-high"}`) picks another voice for a language. Nothing is done while the daemon
itself speaks, so it does not hear itself.

```bash
barch voice setup --install        # whisper-cpp, ggml-cuda, the model (AUR), piper-tts (AUR), the pt_BR voice
barch voice match "liga o hdr"     # hdr (exec): barch hdr on        — tests commands.json, runs nothing
barch voice test "que horas são"   # runs it for real, as if heard (no "barch" needed)
barch voice say "Pronto."          # the voice
barch voice status · log · pause · resume · reload
BARCH_VOICE_DEBUG=1 python3 quickshell/.config/quickshell/voice/voice.py   # in a terminal: every utterance and what whisper heard
```

Packages: `whisper-cpp` and `ggml-cuda` (extra), `whisper.cpp-model-large-v3-turbo-q5_0` and
`piper-tts` (AUR); another ggml model works with `whisper_model` in `config.json`. Thresholds of the
VAD (`vad_min_rms`, `vad_floor_mult`, `vad_end_ms`), the wake variants whisper tends to write
("bartch", "bark", "barque"…), the microphone (`mic_target`, empty = default source) and the Claude
fallback (`claude: false` turns it off) are in `config.json`. `whisper_prompt` must stay a bare
"Barch.": whisper writes the prompt back word for word when it hears only noise, so a prompt
with example commands in it runs them (that is how a keyboard click once closed a window); what
it writes to silence ("Obrigado", the prompt, subtitle credits) is dropped before matching. A new
command is an entry in `commands.json`: `patterns` (what is said, normalized), a `kind` (`exec`, `spawn`, `hypr`, `app`,
`project`, `palette`, `scene`, `region`, `confirm`, `say`, `remind`, `claude`…) and what to run, with
`{group}` placeholders from the pattern's named groups (`n_` prefix: a number, in words or digits);
`barch voice reload` picks it up. The state the bar shows is `~/.local/state/barch/voice/state.json`;
every sentence handled is appended to `history.log` there.

## Theme

`quickshell/.config/quickshell/theme/palettes.json` holds the palettes and `theme/Theme.qml`
derives everything from them. A palette is ten tones (`crust`, `base`, `surface`, `overlay`,
`subtext`, `text`, `accent`, `green`, `yellow`, `red`, the Catppuccin names) plus a label and,
optionally, sixteen official terminal colors (`ansi`); without them the terminal colors are
derived (`palette/palette.js`, shared with the editor). It ships with forty, each with the
official colors of its theme: twenty-six dark (OLED, Dracula, Catppuccin Mocha / Macchiato /
Frappé, Tokyo Night and Storm, Nord, Gruvbox, Solarized, Rosé Pine and Moon, Everforest,
Kanagawa and Dragon, One Dark, Ayu Dark and Mirage, GitHub Dark, Monokai Pro, Flexoki, Night
Owl, Palenight, Oxocarbon, Horizon, Nightfox) and fourteen light (Catppuccin Latte, Nord Light,
Snow, Paper, Solarized Light, Rosé Pine Dawn, Everforest Light, One Light, Ayu Light, GitHub
Light, Flexoki Light, Gruvbox Light, Tokyo Night Day, Dayfox). A tone that failed the editor's
contrast checks with its official value was moved in lightness just enough to pass (mostly
accents and yellows of the light ones). Whether a palette is dark comes from its `base`. One
of each side is pinned: the dark one is what Dark mode shows, the light one what Light mode
shows. The **Themes** tile in the Control Center lists them in the two groups with their colors;
a click pins it (`barch theme dark nord`, `barch theme light snow`, `barch theme palettes`; saved
in `~/.local/state/quickshell/flavors.json`).

**Palette editor** (`quickshell/palette/`, its own Quickshell window: **Edit palettes…** in the
Themes tile, `barch theme edit [palette]`, or "Palette Editor" in the launcher): the ten tones
with hex fields and hue / saturation / lightness sliders, contrast checks (text, subtext and
accent on base, crust on accent, the three state colors), a sample (bar island, buttons, the
sixteen terminal colors, a focused border) and the window itself painted with the draft. Every
change goes to the bar as `theme preview`, so the bar, the Hyprland borders, GTK and the lock
show the draft live (a light draft is shown even in Dark mode); **Save** writes it through the
bar (`theme save`, the bar is the only writer of `palettes.json`), pins it on its side and
renders its wallpapers in the background; **Close** puts everything back. **From an image…**
(also `barch theme from-image photo.jpg --id praia`) runs `tools/palette_from_image.py`: the
picture's dominant colors become the background ramp, the most present saturated color the
accent, the nearest hues the green / yellow / red, each pushed to the minimum contrast, and the
result opens in the editor unsaved. Delete refuses a pinned palette. Custom palettes live in the
same `palettes.json`, so they are saved with the repo.

From the pinned pair it generates the colors for
foot, Neovim, the lock screen, the Hyprland borders, GTK 3 (`BArch-dark/light` themes over adw-gtk3),
GTK 4/libadwaita, qt6ct, fontconfig and MangoHud. Changing the pinned palette of the mode in use
repaints the bar, the borders, the lock and the open GTK apps at once; terminals, Neovim and Qt
apps already open keep their colors until reopened. `theme-auto` switches the Hyprland theme,
the apps (`apps-theme`: GTK theme, Papirus icons, cursor); the wallpapers are drawn in the colors
of the palette in use (see Wallpapers). Generated files inside the repo are git-ignored.

## Fresh install

1. Install Arch with the layout of this machine: **[INSTALL.md](INSTALL.md)**, step by step (GPT +
   LUKS2, btrfs subvolumes, snapper, the systemd initramfs, UKIs with Limine, Secure Boot with
   sbctl, the TPM unlock), including which files of `system/` must not be applied to other
   hardware. Its steps 10–14 overlap with the ones below.
2. Then:

```bash
sudo pacman -S --needed git github-cli openssh
gh auth login                                    # SSH, upload a new key (in a test VM: -p https -w)
git clone git@github.com:bcfrutuozo/BArch.git ~/BArch
cd ~/BArch
./install.sh                    # packages (+ paru), configs, wallpapers, AirPods daemon, user services
./scripts/apply-system.sh       # system files one by one, with a diff and a prompt; services
```

3. After `apply-system.sh`: rebuild the boot images (`sudo limine-update`), re-enroll the TPM
   (below), reboot. Fill in anything marked `REDACTED`.
4. Build the kernel: `kernel-update -f`.
5. Secrets and app state: with the NAS mounted and the restic password (Bitwarden) in
   `~/.config/barch/backup/password`, `barch backup restore latest ~/.ssh ~/.gnupg ~/.config/pia ...`
   (see Backup) and move the files into place.

`install.sh` and `apply-system.sh` detect virtual machines: there they skip NVIDIA, the CachyOS
kernel and every disk/boot file, so the repo can be tested in a KVM guest without breaking it.

## Machine-specific notes

True for this machine only; review before using the repo elsewhere.

- **CPU core 7 disabled** with an ACPI MADT override loaded from the initramfs
  (`system/files/etc/initcpio/`, see `mkinitcpio.conf`). The core crashes the system.
- **Kernel:** `linux-cachyos` built with BORE by `~/.local/bin/kernel-update` from
  `~/.cache/paru/clone/linux-cachyos` (re-downloaded if missing). It is in `IgnorePkg` in
  `pacman.conf`, so `paru -Syu` never builds the stock one. The BORE patch is fetched fresh at
  every build; when a stable release breaks it before CachyOS catches up (7.3.1 did), a fixup
  in `bin/.local/share/kernel-update/*.patch` is applied after `prepare()`, skipped once it is
  upstream (listed in `agent/watchlist.md` so `upstream-watch` says when to drop it).
- **Boot:** Limine + UKIs generated by `limine-mkinitcpio-hook` (`/boot/EFI/Linux/<machine-id>_*.efi`),
  signed with sbctl; snapshot entries from snapper. Limine theme via `tools/limine-theme.py`.
- **Disk:** LUKS2 unlocked by the TPM bound to PCR 7. After firmware, dbx or Secure Boot changes
  the disk asks for the password; the bar warns and offers:
  `sudo systemd-cryptenroll /dev/nvme0n1p2 --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7`
- **No realtime for Hyprland** (`HYPRLAND_NO_RT=1` in `uwsm/.config/uwsm/env`): Hyprland 0.57
  asks rtkit for SCHED_RR with a 200 ms `RLIMIT_RTTIME`, and the NVIDIA modeset path (`dpms off`
  with the session locked, resume) exceeds it without blocking, so the kernel killed the
  compositor with no trace, six times on 2026-10-31. Drop the variable once a release carries
  hyprwm/Hyprland#16737 (`agent/watchlist.md`).
- **Monitors:** AW3225QF on `HDMI-A-2` (4K 240 Hz, 10-bit, HDR, scale 2, the bar lives here);
  P2723QE on `HDMI-A-1`, portrait, to the left. Values in `hypr/.config/hypr/conf/monitors.lua`
  (`BArch.monitors`); the bar changes HDR/SDR brightness through `BArch.set_monitor(...)`.
  After a resume the driver can refuse every mode above 60 Hz on the AW without logging anything;
  `hypr/scripts/hdr-kick.sh` (run by hypridle after sleep) checks the refresh rate it got and, when it
  is low, disables and re-enables the output, which renegotiates the link. It notifies if even that fails
  or the output does not come back; one resume gets one kick (hypridle calls it twice, the second is dropped).
  Waking from DPMS the HDMI 2.1 link training (FRL) often fails (`HDMI FRL link training failed` in the
  kernel log) and the driver falls back to 60 Hz: then it goes straight to the reconnect.
  Restoring that link after a suspend fails too, and left the AW black even after a reconnect, so
  hypridle turns the AW off before the machine sleeps (`hdr-kick.sh sleep`) and on again only once
  the GPU and the side monitor are back (`hdr-kick.sh resume`): a fresh connect, as if plugged in later.
  It stays on HDMI 2.1: over DisplayPort, DSC froze the machine on resume.
- **Games:** Battle.net in its own prefix at `~/Games/battle.net` (games on drive `G:`).
  WoW has no native HDR; gamescope's inverse tone mapping didn't work nested in Hyprland
  (gamescope 3.17, Hyprland 0.56) — use the SDR brightness slider instead.
- **NAS shares** are `x-systemd.automount` entries in `fstab`; `nas-mount.service` mounts them in the
  background after login (waits up to 60 s for the NAS, then leaves them to mount on first access).
  The entries pin the NAS address (`ip=100.100.0.10`): its name also resolves to an IPv6 address
  where SMB is not listening, and the first mount of every boot went there and was refused
  (`CIFS: VFS: Error connecting to socket`, ten times in the kernel log) before the retry
  succeeded. Credentials are **not** in this repo.

## Not stored here

SSH/GPG keys, Secure Boot keys, Wi-Fi passwords, SMB credentials, the iCloud app password
(`~/.config/vdirsyncer/icloud-password`) and anything else secret. `collect-system.sh` skips
secret-looking files, redacts inline passwords and warns about suspicious lines. Most of these
are in the encrypted NAS backup instead (see Backup); the restic password itself is only in
Bitwarden and on this machine.
