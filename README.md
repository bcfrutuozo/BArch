# BArch

Bruno's Arch Linux desktop: Hyprland (Lua config), a Quickshell bar that replaces most of a
desktop environment, one theme for everything (Dracula at night, Catppuccin Latte by day), and
the system pieces that make this machine boot, update and recover the way it does.

## Everyday use

```bash
cd ~/BArch && ./scripts/sync.sh "what changed"     # never with sudo; it asks where needed
```

Refreshes the package lists and the system snapshot (`system/files`), commits and pushes.
Updates are done from the bar (**Update All**), not by hand: it shows unread Arch news first,
runs `paru -Syu` and then `kernel-update` when there is a new CachyOS kernel.

## What's inside

Each top-level folder is a [GNU Stow](https://www.gnu.org/software/stow/) package that mirrors
`$HOME`. The real files live here and their usual paths are symlinks, so editing
`~/.config/hypr/...` edits the repo. The list lives in `scripts/lib.sh` (`PACKAGES`).

| Folder | Goes to | What it is |
|---|---|---|
| `hypr/` | `~/.config/hypr` | Hyprland (Lua, split in `conf/`), hyprlock, hypridle, hyprpaper |
| `quickshell/` | `~/.config/quickshell` | The bar and everything around it (see below); `theme/Theme.qml` is the central theme |
| `foot/` | `~/.config/foot` | Terminal |
| `nvim/` | `~/.config/nvim` | Neovim for C#/Avalonia and C++ (LSP, debug, build/run/test) |
| `mpv/` | `~/.config/mpv` | Video player (HDR, NVDEC) |
| `uwsm/`, `environment/` | `~/.config/uwsm`, `~/.config/environment.d` | Session environment (Qt theme, cursor) |
| `systemd/` | `~/.config/systemd/user` | User services (cliphist, replay) |
| `bin/` | `~/.local/bin` | `barch` (CLI, below), `kernel-update`, `theme-auto`, `wallpaper-mode`, `apps-theme`, `papirus-accent` |
| `games/` | `~/Games/battle.net/run.sh`, `~/.config/gamemode.ini` | Battle.net launcher (umu + Proton-GE) and gamemode rules |
| `calendar/` | `~/.config/khal`, `~/.config/vdirsyncer/config` | iCloud calendar sync (the app password stays out of the repo) |
| `tools/` | — | Generators: wallpapers (`make_wallpapers.py`), Limine theme (`limine-theme.py`) |
| `system/` | `/etc`, `/boot`, `/usr/local/bin` | Snapshot of system files (copied, never linked); list in `SYSTEM_FILES` |
| `packages/` | — | Explicitly installed packages (`pacman.txt`, `aur.txt`, `aur-ignore.txt`) |

Folders that don't exist on a machine are simply skipped.

## The bar (Quickshell)

Press **Super+/** for the full, always up-to-date list of shortcuts (Hyprland and Neovim tabs).
The main pieces:

- **Workspaces** with the icons of the apps on each one; **Alt+Tab** with live previews (releasing
  Alt swaps the chosen window into the current one's place; Space only focuses); **Super+Tab** or the
  top-right corner of the main monitor opens the workspace overview (drag windows between workspaces).
- **Launcher** (Super+Space): apps, `w` windows, `c` clipboard with image thumbnails (Super+V),
  `p` git projects, `/` files, `:` emoji, `?` web, `=` calculator, `>` run; OCR, color picker, QR.
- **Window tools:** minimize (Super+M, comes back to its own workspace), always on top
  (Super+Shift+P), right-click menu on any window preview, swap/resize with Super+Shift/Ctrl+arrows.
- **Control Center:** Light / Dark / Auto, Display (HDR, SDR brightness, side monitor on/off),
  Bluetooth, Caffeine, Night Light, Do Not Disturb, Game HDR, Game HUD (MangoHud), Screenshot,
  screen Recording (full screen or region).
- **Own notification server** with history, DND, sounds and app actions; privacy indicator
  (mic, camera, screen sharing); ShadowPlay-style replay (Alt+F10); weather with rain alerts;
  iCloud agenda in the clock's calendar; quick notes (Super+N); session restore at login.
- **System health:** `.pacnew` files, failed services, TPM fallback warning and a monthly cleanup.
- **Updates:** pending packages, unread Arch news (also enforced by a pacman hook) and the kernel.

## barch CLI

`barch` is the stable command line for scripts (and agents). It only asks the bar over Quickshell
IPC, so it does exactly what the Control Center does; the bar has to be running.

```bash
barch notify "Backup" "Finished in 4 min" [--critical|--low] [--app NAME]   # through the bar's server
barch theme light|dark|auto|status
barch hdr on|off|status            barch sdr <nits>|status
barch monitor side on|off|status   barch caffeine on|off|status
barch nightlight on|off|status     barch dnd on|off|status
barch health [--refresh]           # .pacnew, failed services, TPM, cleanup
```

Every command takes `--json`. Exit codes: `0` ok, `1` the bar refused, `2` usage, `3` bar not reachable.
On the QML side these are the `IpcHandler`s `control`, `theme`, `notifs` and `health` (`qs ipc show`).

## Theme

`quickshell/.config/quickshell/theme/Theme.qml` is the single source. It generates the colors for
foot, Neovim, hyprlock, the Hyprland borders, GTK 3 (`BArch-dark/light` themes over adw-gtk3),
GTK 4/libadwaita, qt6ct, fontconfig and MangoHud. `theme-auto` switches the Hyprland theme,
the wallpapers (`wallpaper-mode`) and the apps (`apps-theme`: GTK theme, Papirus icons, cursor).
Generated files inside the repo are git-ignored.

## Fresh install

1. Install Arch with the layout described in the project notes (LUKS2 + btrfs subvolumes, Limine,
   UKI, Secure Boot with sbctl).
2. Then:

```bash
sudo pacman -S --needed git github-cli openssh
gh auth login                                    # SSH, upload a new key (in a test VM: -p https -w)
git clone git@github.com:bcfrutuozo/BArch.git ~/BArch
cd ~/BArch
./install.sh                    # packages (+ paru), configs, wallpapers, user services
./scripts/apply-system.sh       # system files one by one, with a diff and a prompt; services
```

3. After `apply-system.sh`: rebuild the boot images (`sudo limine-update`), re-enroll the TPM
   (below), reboot. Fill in anything marked `REDACTED`.
4. Build the kernel: `kernel-update -f`.

`install.sh` and `apply-system.sh` detect virtual machines: there they skip NVIDIA, the CachyOS
kernel and every disk/boot file, so the repo can be tested in a KVM guest without breaking it.

## Machine-specific notes

True for this machine only; review before using the repo elsewhere.

- **CPU core 7 disabled** with an ACPI MADT override loaded from the initramfs
  (`system/files/etc/initcpio/`, see `mkinitcpio.conf`). The core crashes the system.
- **Kernel:** `linux-cachyos` built with BORE by `~/.local/bin/kernel-update` from
  `~/.cache/paru/clone/linux-cachyos` (re-downloaded if missing). It is in `IgnorePkg` in
  `pacman.conf`, so `paru -Syu` never builds the stock one.
- **Boot:** Limine + UKIs generated by `limine-mkinitcpio-hook` (`/boot/EFI/Linux/<machine-id>_*.efi`),
  signed with sbctl; snapshot entries from snapper. Limine theme via `tools/limine-theme.py`.
- **Disk:** LUKS2 unlocked by the TPM bound to PCR 7. After firmware, dbx or Secure Boot changes
  the disk asks for the password; the bar warns and offers:
  `sudo systemd-cryptenroll /dev/nvme0n1p2 --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7`
- **Monitors:** AW3225QF on `HDMI-A-2` (4K 240 Hz, 10-bit, HDR, scale 2, the bar lives here);
  P2723QE on `HDMI-A-1`, portrait, to the left. Values in `hypr/.config/hypr/conf/monitors.lua`
  (`BArch.monitors`); the bar changes HDR/SDR brightness through `BArch.set_monitor(...)`.
- **Games:** Battle.net in its own prefix at `~/Games/battle.net` (games on drive `G:`).
  WoW has no native HDR; gamescope's inverse tone mapping didn't work nested in Hyprland
  (gamescope 3.17, Hyprland 0.56) — use the SDR brightness slider instead.
- **NAS shares** are mounted at boot; credentials are **not** in this repo.

## Not stored here

SSH/GPG keys, Secure Boot keys, Wi-Fi passwords, SMB credentials, the iCloud app password
(`~/.config/vdirsyncer/icloud-password`) and anything else secret. `collect-system.sh` skips
secret-looking files, redacts inline passwords and warns about suspicious lines.
