# BArch

Bruno's Arch Linux desktop: Hyprland (Lua config), a Quickshell bar that replaces most of a
desktop environment, one theme for everything (Dracula at night, Catppuccin Latte by day), and
the system pieces that make this machine boot, update and recover the way it does.

## Everyday use

```bash
cd ~/BArch && ./scripts/sync.sh "what changed"     # never with sudo; it asks where needed
```

Runs `scripts/check.sh` first (bash -n and shellcheck on every script, `luac -p` on the Lua
config, `scripts/qml-check.sh` on the QML (every qmldir complete, no broken links, the part of
qmllint that is reliable with Quickshell's types), jq on the JSON files, `systemd-analyze verify`
on the user units, every agent task has its timer listed, the unit tests, `hyprctl configerrors`; it stops on the first problem, `BARCH_NO_CHECK=1`
skips it), then refreshes the package lists and the system snapshot (`system/files`), refuses to
commit anything that matches `~/.config/barch/private.txt` (`scripts/private-scan.sh`: one regex per
line, kept on this machine: the domain, the public addresses, since the repo is public), commits
and pushes. Updates are done from the bar (**Update All**), not by hand: it shows unread Arch news first,
has Claude review the PKGBUILD changes of the AUR updates (and asks before going on if anything
looks suspicious), runs `paru -Syu` and then `kernel-update` when there is a new CachyOS kernel.

## What's inside

Each top-level folder is a [GNU Stow](https://www.gnu.org/software/stow/) package that mirrors
`$HOME`. The real files live here and their usual paths are symlinks, so editing
`~/.config/hypr/...` edits the repo. The list lives in `scripts/lib.sh` (`PACKAGES`).

| Folder | Goes to | What it is |
|---|---|---|
| `hypr/` | `~/.config/hypr` | Hyprland (Lua, split in `conf/`), hypridle, `scripts/lock.sh` (locks; starts and supervises the resident lock process); `settings.json` is what the Hyprland Settings app saved ([docs/apps.md](docs/apps.md#hyprland-settings)) |
| `quickshell/` | `~/.config/quickshell` | The bar and everything around it (below and [docs/bar.md](docs/bar.md)); `theme/palettes.json` + `theme/Theme.qml` are the central theme, `palette/` the palette editor, `hypr/` the Hyprland Settings app, `center/` the System Center, `backup/`, `packages/`, `mixer/`, `music/`, `player/` (the music player), `books/`, `video/`, `torrents/` and `clip/` (the video editor) the other apps, `voice/` the voice control daemon, `ui/` the controls they all share (linked into each) |
| `foot/` | `~/.config/foot`, `~/.config/xdg-terminals.list` | Terminal; also the one `xdg-terminal-exec` picks for `Terminal=true` apps (Thunar opening a `.txt` in nvim), else it picked cmux, which ignores `-e` |
| `ghostty/` | `~/.config/ghostty/config.ghostty` | Ghostty config as cmux reads it (it embeds libghostty): Ctrl+C copies a selection (^C without one), Ctrl+V pastes, Ctrl+Shift+C/V send the originals, like foot |
| `nvim/` | `~/.config/nvim` | Neovim for C#/Avalonia and C++ (LSP, debug, build/run/test) |
| `mpv/` | `~/.config/mpv` | Video player (HDR, NVDEC) |
| `uwsm/`, `environment/` | `~/.config/uwsm`, `~/.config/environment.d` | Session environment (Qt theme, cursor) |
| `systemd/` | `~/.config/systemd/user` | User services (cliphist, replay, NAS mount, voice control, BArch Drop) |
| `bin/` | `~/.local/bin` | `barch` (CLI: the command list and globals; each area's commands in `.local/lib/barch/<area>.sh`, sourced from the repo, not stowed; [docs/cli.md](docs/cli.md)), `kernel-update`, `theme-auto`, `apps-theme`, `papirus-accent`, `nas-mount`, `keyring-wait`, `gsr-replay-saved` (the notification after a replay or recording is saved) |
| `claude/` | `~/.claude/settings.json` | Claude Code settings: the hooks that take the safety snapshots ([docs/agent.md](docs/agent.md)) |
| `games/` | `~/Games/battle.net/run.sh`, `~/.config/gamemode.ini`, `~/.local/share/applications/steam.desktop` | Battle.net launcher (umu + Proton-GE), gamemode rules, Steam launcher without `GDK_SCALE` (Steam would scale twice) |
| `clip/` | `~/.local/share/applications/barch-clip.desktop` | "Open with → BArch Clip" on any video in Thunar (hidden from menus; the launcher has its own entry); `install.sh` pins mpv as the player, or GIO would pick this entry by name |
| `spotify/` | `~/.local/share/applications/spotify-launcher.desktop` | Spotify launcher without `GDK_SCALE` (it runs under Xwayland and already scales by `Xft.dpi`, so it scaled twice, like Steam) |
| `applio/` | `~/.local/share/applications/applio.desktop` | **Applio** in the launcher: [Applio](https://github.com/IAHispano/Applio) (RVC voice conversion) lives outside the repo in `~/Applications/Applio` (its own Python 3.12 venv made with `uv`, never its `run-install.sh`, which runs `pacman -Syu`); the entry runs `barch applio open` ([docs/apps.md](docs/apps.md#applio)) |
| `obs/` | `~/.local/share/applications/obs-stream.desktop`, `obs-guitarra.desktop` | OBS launchers: **OBS Stream** (profile "Stream YouTube", scenes "Jogo": screen + BRIO corner, mic, PC audio) and **OBS Guitarra** (BRIO 1080p60, the room through the fifine, HEVC); the profiles and scenes go in the backup, the recordings in `~/Videos/OBS` do not |
| `calendar/` | `~/.config/khal`, `~/.config/vdirsyncer/config` | iCloud calendar sync (the app password stays out of the repo) |
| `audio/` | `~/.config/pipewire`, `~/.config/wireplumber` | PipeWire rates and resampler, onboard output at 32-bit/192 kHz, Bluetooth output-only at AAC ([docs/bar.md](docs/bar.md)), fifine mic as input only |
| `backup/` | — | `barch backup`: what restic saves to the NAS (`include.txt`, `exclude.txt`), see [docs/backup.md](docs/backup.md) |
| `finance/` | — | `barch finance import`: C6 Bank statements into Firefly III (data stays in `~/.config/firefly`) |
| `agent/` | — | Scheduled agent tasks (`tasks/`), the reactive rules (`rules.json`) and their daemon (`events.py`), the NAS health collector (`nas.py`), the iPhone receiver (`drop.py`), the failure ignore list and the upstream watch list; used by `barch` |
| `server/` | NAS | `music/`: the music pipeline (its own container, `barch-music`), downloads to `/music` in the library's style with a review queue (`barch music`, see [docs/music.md](docs/music.md)) and the catalog of `/music` the Player reads (`catalog.py`); `unraid/`: the SMBus driver OpenRGB needs there, built per Unraid kernel (see [docs/nas.md](docs/nas.md)); `books/`: the book stack's Unraid templates (Shelfmark requests, Calibre-Web-Automated for ebooks, Audiobookshelf), its README; `video/`: what Radarr and Sonarr accept (2160p HEVC HDR, a 1080p profile for what never came out in 4K, Recyclarr) and the pipeline that muxes the PT-BR dub from another release into each movie and episode, subtitles shifted along (`barch video`, its README); `torrents/`: qBittorrent's counters sampled every five minutes into SQLite (its own container, `barch-torrents`), so ratio, upload and download have a history (`barch torrents`, its README) |
| `tools/` | — | Generators: wallpapers (`make_wallpapers.py`, sixteen scenes in the colors of each palette), Limine theme (`limine-theme.py`) |
| `docs/` | — | One page per area (below): what the README used to hold in full |
| `system/` | `/etc`, `/boot`, `/usr/local/bin` | Snapshot of system files (copied, never linked); list in `SYSTEM_FILES` |
| `packages/` | — | Explicitly installed packages (`pacman.txt`, `aur.txt`, `aur-ignore.txt`) |
| `scripts/` | — | `sync.sh` (save), `check.sh` (static checks; `qml-check.sh` for the QML), `collect-system.sh` / `apply-system.sh` (`system/`), `update-packages.sh`, `lib.sh` (`PACKAGES`, `SYSTEM_FILES`, services); `bootstrap.sh` adopts configs that already exist on a configured machine into the repo (`--dry-run` first) |

Folders that don't exist on a machine are simply skipped.

## The bar (Quickshell)

Press **Super+/** for the full, always up-to-date list of shortcuts (Hyprland and Neovim tabs).
The bar replaces most of a desktop environment; each piece is described in [docs/bar.md](docs/bar.md):
workspaces with app icons, Alt+Tab with live previews and the workspace overview, the launcher
(Super+Space: apps, windows, clipboard, projects, files, emoji, web, calculator, Claude, wallpapers),
window tools (minimize, pin, tabbed groups, zoom), the Control Center, the notification server with
history and DND, the lock screen, the Claude plan's usage, the Inbox of what waits for a decision,
system health, the volume OSD and the smaller widgets (system monitor, disks, VMs, AirPods, media).

Around it, apps with their own window and services, each with its page:

| Page | What |
|---|---|
| [docs/apps.md](docs/apps.md) | Hyprland Settings (every option of the installed version), System Center, Packages, Audio Mixer, Clip (video editor), BArch Drop (files from the iPhone), Applio |
| [docs/privacy.md](docs/privacy.md) | Anonymous Mode, the nftables firewall and kill switch, the PIA VPN |
| [docs/theme.md](docs/theme.md) | Palettes, the palette editor, what is generated from them, RGB lighting, the wallpapers |
| [docs/music.md](docs/music.md) | The music pipeline on the NAS and the Music app (review, covers, library, artists) |
| [docs/player.md](docs/player.md) | The Player: the NAS library played here through mpv, with Plex/Tautulli scrobbling |
| [docs/books.md](docs/books.md), [docs/video.md](docs/video.md), [docs/torrents.md](docs/torrents.md) | The book stack, Radarr/Sonarr with the PT-BR dub pipeline, qBittorrent statistics |
| [docs/voice.md](docs/voice.md) | Always-on voice control ("barch ..."), whisper.cpp, Piper, the Claude fallback |
| [docs/agent.md](docs/agent.md) | Claude on its own: failures, safety snapshots, scheduled tasks; the event bus, metrics and rules |
| [docs/nas.md](docs/nas.md) | NAS health through Unraid's API, the pfSense firewalls, the NAS's SMBus driver |
| [docs/backup.md](docs/backup.md) | restic to the NAS and the Backup Browser |
| [docs/finance.md](docs/finance.md) | C6 Bank statements into Firefly III |
| [docs/cli.md](docs/cli.md) | Every `barch` subcommand |
| [docs/machine.md](docs/machine.md) | True for this machine only: CPU core, kernel, boot, disk, monitors, games, NAS shares |

## barch CLI

`barch` is the stable command line for scripts (and agents): it asks the bar over Quickshell IPC,
so it does exactly what the Control Center does. `barch help` lists everything, [docs/cli.md](docs/cli.md)
too. Every command takes `--json`. Exit codes: `0` ok, `1` the bar refused, `2` usage, `3` bar not
reachable.

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
   ([docs/machine.md](docs/machine.md)), reboot. Fill in anything marked `REDACTED`.
4. Build the kernel: `kernel-update -f`.
5. Secrets and app state: with the NAS mounted and the restic password (Bitwarden) in
   `~/.config/barch/backup/password`, `barch backup restore latest ~/.ssh ~/.gnupg ~/.config/pia ...`
   (see [docs/backup.md](docs/backup.md)) and move the files into place.

`install.sh` and `apply-system.sh` detect virtual machines: there they skip NVIDIA, the CachyOS
kernel and every disk/boot file, so the repo can be tested in a KVM guest without breaking it.

## Not stored here

SSH/GPG keys, Secure Boot keys, Wi-Fi passwords, SMB credentials, the iCloud app password
(`~/.config/vdirsyncer/icloud-password`) and anything else secret. `collect-system.sh` skips
secret-looking files, redacts inline passwords and warns about suspicious lines. Most of these
are in the encrypted NAS backup instead (see [docs/backup.md](docs/backup.md)); the restic password itself is only in
Bitwarden and on this machine.
