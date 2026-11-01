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
| `hypr/` | `~/.config/hypr` | Hyprland (Lua, split in `conf/`), hypridle, `scripts/lock.sh` (locks; starts and supervises the resident lock process) |
| `quickshell/` | `~/.config/quickshell` | The bar and everything around it (see below); `theme/palettes.json` + `theme/Theme.qml` are the central theme, `palette/` the palette editor |
| `foot/` | `~/.config/foot` | Terminal |
| `nvim/` | `~/.config/nvim` | Neovim for C#/Avalonia and C++ (LSP, debug, build/run/test) |
| `mpv/` | `~/.config/mpv` | Video player (HDR, NVDEC) |
| `uwsm/`, `environment/` | `~/.config/uwsm`, `~/.config/environment.d` | Session environment (Qt theme, cursor) |
| `systemd/` | `~/.config/systemd/user` | User services (cliphist, replay, NAS mount) |
| `bin/` | `~/.local/bin` | `barch` (CLI, below), `kernel-update`, `theme-auto`, `apps-theme`, `papirus-accent`, `nas-mount`, `keyring-wait`, `gsr-replay-saved` (the notification after a replay or recording is saved) |
| `claude/` | `~/.claude/settings.json` | Claude Code settings: the hooks that take the safety snapshots (see Agent) |
| `games/` | `~/Games/battle.net/run.sh`, `~/.config/gamemode.ini`, `~/.local/share/applications/steam.desktop` | Battle.net launcher (umu + Proton-GE), gamemode rules, Steam launcher without `GDK_SCALE` (Steam would scale twice) |
| `calendar/` | `~/.config/khal`, `~/.config/vdirsyncer/config` | iCloud calendar sync (the app password stays out of the repo) |
| `audio/` | `~/.config/pipewire`, `~/.config/wireplumber` | PipeWire rates and resampler, onboard output at 32-bit/192 kHz, Bluetooth output-only at AAC (below), fifine mic as input only |
| `backup/` | — | `barch backup`: what restic saves to the NAS (`include.txt`, `exclude.txt`), see Backup |
| `finance/` | — | `barch finance import`: C6 Bank statements into Firefly III (data stays in `~/.config/firefly`) |
| `agent/` | — | Scheduled agent tasks (`tasks/`), the failure ignore list and the upstream watch list; used by `barch` |
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
  or more than two days old) and a monthly cleanup.
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
barch hdr on|off|status            barch sdr <nits>|status
barch monitor side on|off|status   barch caffeine on|off|status
barch nightlight on|off|status     barch dnd on|off|status
barch anon on [region]|off|toggle|status   # Anonymous Mode: VPN + kill switch + Mullvad Browser as default + hostname out of DHCP
barch vpn on [region]|off|toggle|status|regions|region <id>|auto
barch health [--refresh]           # .pacnew, failed services, TPM, backup, cleanup
barch backup init|run|status|list|restore [SNAPSHOT] <path>...   # restic to the NAS (see Backup)
barch agent ask "why is X slow?"   # Claude in a terminal in ~/BArch (the launcher's "a ")
barch agent list|run|report|continue <task>   # scheduled tasks (see Agent)
barch failure <unit> [--system]    # what OnFailure= calls: log + notification (see Agent)
barch snapshot list                # safety snapshot pairs of the agent sessions
barch aur review                   # verdict on the pending AUR updates
barch finance import [--dry-run]   # C6 Bank statements → Firefly (see Finance)
barch replay share [file] [--from 12 --to 40]
                                   # newest replay (or FILE) → <name>-share.mp4 for WhatsApp status:
                                   # H.264 ≤1080p30, HDR tone mapped to SDR, at most 60 s
```

Every command takes `--json`. Exit codes: `0` ok, `1` the bar refused, `2` usage, `3` bar not reachable.
On the QML side these are the `IpcHandler`s `control`, `theme`, `wallpaper`, `notifs`, `health`, `vpn` and `anon` (`qs ipc show`).

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

1. Install Arch with the layout described in the project notes (LUKS2 + btrfs subvolumes, Limine,
   UKI, Secure Boot with sbctl).
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
  is low, disables and re-enables the output, which renegotiates the link. It notifies if even that fails.
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
