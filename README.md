# BArch

Bruno's Arch Linux desktop: Hyprland, a Quickshell bar, one theme for everything,
and the system tweaks that make this machine boot and behave the way it does.

## What's inside

| Folder | Goes to | What it is |
|---|---|---|
| `hypr/` | `~/.config/hypr` | Hyprland (Lua config), hyprlock, hypridle, hyprpaper |
| `quickshell/` | `~/.config/quickshell` | The bar, launcher, notifications, control center and the central theme (`theme/Theme.qml`) |
| `foot/` | `~/.config/foot` | Terminal |
| `nvim/` | `~/.config/nvim` | Neovim (C#/Avalonia and C++) |
| `mpv/` | `~/.config/mpv` | Video player (HDR, NVDEC) |
| `uwsm/`, `environment/` | `~/.config/uwsm`, `~/.config/environment.d` | Session environment (Qt theme, cursor) |
| `systemd/` | `~/.config/systemd/user` | User services (cliphist, replay) |
| `bin/` | `~/.local/bin` | Personal scripts: `kernel-update`, `theme-auto`, `wallpaper-mode`, `apps-theme`, `papirus-accent` |
| `tools/` | — | Generators: wallpapers (`make_wallpapers.py`) and the Limine theme (`limine-theme.py`) |
| `system/` | `/etc`, `/boot`, `/usr/local/bin` | Snapshot of system files (copied, never linked) |
| `packages/` | — | Explicitly installed packages (`pacman.txt`, `aur.txt`) |

Each top-level folder is a [GNU Stow](https://www.gnu.org/software/stow/) package that mirrors
`$HOME`. The real files live here; their usual paths are symlinks to them, so editing
`~/.config/hypr/...` edits the repo.

## Everyday use

```bash
./scripts/sync.sh "what changed"
```

Refreshes the package lists and the system snapshot, then commits and pushes.

## Fresh install

```bash
git clone git@github.com:<you>/BArch.git ~/BArch
cd ~/BArch
./install.sh                 # packages, configs, user services
./scripts/apply-system.sh    # system files, one by one, with a diff and a prompt
```

## Theme

Everything follows `quickshell/.config/quickshell/theme/Theme.qml` (Dracula at night, Catppuccin Latte by day):

- Light / Dark / Auto from the control center; Auto switches at the hours set in `theme-auto`;
- the bar generates the colors for foot, Neovim, hyprlock, Hyprland borders, GTK 3/4, qt6ct and
  fontconfig; files generated inside the repo are git-ignored;
- `theme-auto` switches the Hyprland theme, wallpapers (`wallpaper-mode`) and apps (`apps-theme`).

## Machine-specific notes

These are true for this machine only; review them before using the repo elsewhere.

- **CPU core 7 disabled** via an ACPI MADT override loaded from the initramfs
  (`system/files/etc/initcpio/`, see `mkinitcpio.conf`). The core crashes the system.
- **Custom kernel**: `linux-cachyos` built with BORE by `~/.local/bin/kernel-update`;
  it's listed in `packages/aur-ignore.txt` so `install.sh` doesn't build the stock one.
- **Monitors**: the bar is pinned to `HDMI-A-2` (AW3225QF, OLED, scale 2); the second
  monitor (P2723QE) is portrait.
- **Disk**: LUKS + btrfs subvolumes, UKI, Secure Boot, Limine.
- **NAS shares** are mounted at boot; their credentials are **not** in this repo
  (passwords in `fstab` are replaced with `REDACTED`).

## Not stored here

SSH/GPG keys, Secure Boot keys, Wi-Fi passwords, SMB credentials and anything else secret.
`collect-system.sh` skips secret-looking files and warns about suspicious lines.
