#!/usr/bin/env bash
# Shared settings and helpers for the BArch scripts.

# Repository root (the folder that contains scripts/)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stow packages: each one is a folder in the repo that mirrors $HOME.
# name -> paths (relative to $HOME, separated by spaces) that belong to it
declare -A PACKAGES=(
  [claude]=".claude/settings.json"
  [hypr]=".config/hypr"
  [quickshell]=".config/quickshell"
  [foot]=".config/foot"
  [nvim]=".config/nvim"
  [mpv]=".config/mpv"
  [uwsm]=".config/uwsm"
  [environment]=".config/environment.d"
  [systemd]=".config/systemd/user"
  [games]="Games/battle.net/run.sh .config/gamemode.ini .local/share/applications/steam.desktop"
  [bin]=".local/bin/kernel-update .local/bin/theme-auto .local/bin/apps-theme .local/bin/papirus-accent .local/bin/barch .local/bin/nas-mount .local/bin/keyring-wait"
  [calendar]=".config/khal .config/vdirsyncer/config"
)

# User services to enable on a fresh install
USER_SERVICES=(cliphist.service)

# System services and timers to enable on a fresh install (apply-system.sh asks first)
SYSTEM_SERVICES=(earlyoom.service smartd.service paccache.timer btrfs-scrub@-.timer setvtrgb.service)

# System files copied into system/files/ (never symlinked).
# Globs are allowed. Anything missing is skipped, and so are symlinks.
SYSTEM_FILES=(
  /etc/kernel/cmdline
  /etc/mkinitcpio.conf
  "/etc/mkinitcpio.conf.d/*"
  "/etc/mkinitcpio.d/*.preset"
  "/etc/initcpio/**"
  /etc/default/limine
  /boot/limine.conf
  /boot/limine/limine.conf
  /boot/limine/wallpaper.png
  /boot/EFI/limine/limine.conf
  /etc/plymouth/plymouthd.conf
  "/usr/share/plymouth/themes/barch/*"
  /etc/crypttab
  /etc/fstab
  /etc/pacman.conf
  /etc/makepkg.conf
  /etc/locale.gen
  /etc/locale.conf
  /etc/vconsole.conf
  /etc/vtrgb-dracula
  /etc/hostname
  /etc/bluetooth/main.conf
  /etc/default/earlyoom
  /etc/smartd.conf
  "/etc/brave/policies/managed/*"
  "/etc/chromium/policies/managed/*"
  /usr/local/bin/desktop-notify
  /usr/local/bin/smartd-alert
  /usr/local/bin/btrfs-scrub-report
  /usr/local/bin/archnews
  /usr/local/bin/barch-agent-snapshot
  /usr/local/bin/barch-failure-relay
  /etc/polkit-1/rules.d/50-barch-agent-snapshot.rules
  /etc/pam.d/barch-lock
  "/etc/pacman.d/hooks/*"
  "/etc/modprobe.d/*"
  "/etc/sysctl.d/*"
  "/etc/udev/rules.d/*"
  "/etc/systemd/system/*.service"
  "/etc/systemd/system/*.timer"
  "/etc/systemd/system/*.service.d/*"
  "/etc/systemd/system/service.d/*"
  "/etc/systemd/system/*.mount"
  "/etc/systemd/system/*.automount"
  "/etc/systemd/logind.conf.d/*"
  "/etc/systemd/sleep.conf.d/*"
)
# Never copied, even if a glob above matches them
SYSTEM_EXCLUDE_RE='(credentials|\.smbcred|/secrets?/|\.key$|\.pem$|/sbctl/|NetworkManager/system-connections)'

bold=$'\e[1m'; blue=$'\e[34m'; green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; reset=$'\e[0m'
step() { printf '\n%s%s==> %s%s\n' "$bold" "$blue" "$*" "$reset"; }
ok()   { printf '%s  ✓ %s%s\n' "$green" "$*" "$reset"; }
warn() { printf '%s  ! %s%s\n' "$yellow" "$*" "$reset"; }
die()  { printf '%s  ✗ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

ask() {   # ask "question" -> 0 if yes
  local a
  read -r -p "  $1 [y/N] " a </dev/tty
  [[ "$a" =~ ^[Yy]$ ]]
}
