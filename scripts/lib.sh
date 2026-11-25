#!/usr/bin/env bash
# Shared settings and helpers for the BArch scripts.
# shellcheck disable=SC2034  # sourced by the scripts: the variables below are theirs

# Repository root (the folder that contains scripts/)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stow packages: each one is a folder in the repo that mirrors $HOME.
# name -> paths (relative to $HOME, separated by spaces) that belong to it
declare -A PACKAGES=(
  [claude]=".claude/settings.json"
  [hypr]=".config/hypr"
  [quickshell]=".config/quickshell"
  [foot]=".config/foot .config/xdg-terminals.list"
  [ghostty]=".config/ghostty/config.ghostty"
  [nvim]=".config/nvim"
  [mpv]=".config/mpv"
  [uwsm]=".config/uwsm"
  [environment]=".config/environment.d"
  [systemd]=".config/systemd/user"
  [games]="Games/battle.net/run.sh Games/3dmark/run.sh .config/gamemode.ini .local/share/applications/steam.desktop .local/share/applications/Superposition.desktop .local/share/applications/3dmark.desktop"
  [bin]=".local/bin/kernel-update .local/bin/gsr-replay-saved .local/share/kernel-update .local/bin/theme-auto .local/bin/apps-theme .local/bin/papirus-accent .local/bin/barch .local/bin/nas-mount .local/bin/keyring-wait"
  [calendar]=".config/khal .config/vdirsyncer/config"
  [audio]=".config/pipewire .config/wireplumber"
  [obs]=".local/share/applications/obs-stream.desktop .local/share/applications/obs-guitarra.desktop"
  [clip]=".local/share/applications/barch-clip.desktop"
  [spotify]=".local/share/applications/spotify-launcher.desktop"
  [moonlight]=".local/share/applications/com.moonlight_stream.Moonlight.desktop"
  [applio]=".local/share/applications/applio.desktop"
)

# User services to enable on a fresh install
USER_SERVICES=(cliphist.service)

# System services and timers to enable on a fresh install (apply-system.sh asks first)
SYSTEM_SERVICES=(earlyoom.service smartd.service paccache.timer fstrim.timer btrfs-scrub@-.timer setvtrgb.service numlock.service nftables.service rtkit-daemon.service bluetooth.service barch-bt-le.service snapper-timeline.timer snapper-cleanup.timer limine-snapper-sync.service libvirtd.socket docker.socket barch-backup-root.timer barch-disk-health.timer ckb-next-daemon.service systemd-timesyncd.service)

# System files copied into system/files/ (never symlinked).
# Globs are allowed. Anything missing is skipped, and so are symlinks.
SYSTEM_FILES=(
  /etc/kernel/cmdline
  /etc/mkinitcpio.conf
  "/etc/mkinitcpio.conf.d/*"
  "/etc/mkinitcpio.d/*.preset"
  "/etc/initcpio/**"
  /etc/default/limine
  /etc/limine-entry-tool.conf
  /etc/limine-snapper-sync.conf
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
  /etc/systemd/zram-generator.conf
  "/etc/modules-load.d/*"
  /etc/docker/daemon.json
  /etc/smartd.conf
  /etc/nftables.conf
  "/etc/brave/policies/managed/*"
  "/etc/chromium/policies/managed/*"
  /usr/local/bin/desktop-notify
  /usr/local/bin/smartd-alert
  /usr/local/bin/btrfs-scrub-report
  /usr/local/bin/archnews
  /usr/local/bin/barch-agent-snapshot
  /usr/local/bin/barch-failure-relay
  /usr/local/bin/barch-killswitch
  /usr/local/bin/barch-backup-root
  /usr/local/bin/barch-disk-health
  /usr/local/bin/numlock
  /usr/local/bin/barch-bt-le
  /etc/polkit-1/rules.d/50-barch-agent-snapshot.rules
  /etc/polkit-1/rules.d/50-barch-killswitch.rules
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

# GPU drivers. install.sh asks once (detected vendors as the default) and keeps the answer in
# GPU_FILE; apply-system.sh reuses it. BARCH_GPU="intel nvidia" (or "none") skips the question.
GPU_FILE="$HOME/.config/barch/gpu"
GPU_VENDORS=(nvidia intel amd)
# in packages/*.txt but useless without an NVIDIA card (the lists come from this machine)
NVIDIA_ONLY='^(nvidia|lib32-nvidia|opencl-nvidia|cuda|ggml-cuda|libva-nvidia-driver|egl-gbm|egl-x11)'
declare -A GPU_PACKAGES=(
  [nvidia]="nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver"
  [intel]="mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver"
  [amd]="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon"
)

gpu_detect() {   # vendors of the display controllers (PCI class 03), from sysfs: no pciutils needed
  local d v found=()
  for d in /sys/bus/pci/devices/*; do
    [[ $(cat "$d/class" 2>/dev/null) == 0x03* ]] || continue
    case $(cat "$d/vendor") in
      0x10de) v=nvidia ;; 0x8086) v=intel ;; 0x1002) v=amd ;; *) continue ;;   # VMs' virtual GPUs: none
    esac
    [[ " ${found[*]} " == *" $v "* ]] || found+=("$v")
  done
  echo "${found[*]:-none}"
}

gpu_valid() {   # "intel nvidia" / "none" -> 0 when every word is a known vendor
  local w
  [[ "$1" == none ]] && return 0
  [[ -n "$1" ]] || return 1
  for w in $1; do [[ " ${GPU_VENDORS[*]} " == *" $w "* ]] || return 1; done
}

gpu_choose() {   # sets GPU ("nvidia intel" or "none"): BARCH_GPU, then the saved answer, then asks
  local saved="" detected a
  [[ -f "$GPU_FILE" ]] && saved=$(<"$GPU_FILE")
  if [[ -n "${BARCH_GPU:-}" ]]; then
    GPU=$(tr ',' ' ' <<<"$BARCH_GPU" | xargs)
    gpu_valid "$GPU" || die "BARCH_GPU='$BARCH_GPU': use nvidia, intel, amd (several separated by spaces) or none"
  elif [[ -n "$saved" ]] && gpu_valid "$saved"; then
    GPU=$saved
  else
    detected=$(gpu_detect)
    echo "  GPU drivers to install: nvidia, intel, amd (several separated by spaces) or none."
    echo "  Detected on this machine: $detected"
    while :; do
      read -r -p "  GPU drivers [$detected] " a </dev/tty
      GPU=$(tr ',' ' ' <<<"${a:-$detected}" | xargs)
      gpu_valid "$GPU" && break
      warn "unknown answer '$a'"
    done
  fi
  mkdir -p "$(dirname "$GPU_FILE")"
  echo "$GPU" > "$GPU_FILE"
  ok "GPU drivers: $GPU (saved in ${GPU_FILE/#$HOME/\~}; delete it to be asked again)"
}

gpu_has() { [[ " $GPU " == *" $1 "* ]]; }
