#!/usr/bin/env bash
# kernel-check: runs only on the first login with a kernel not checked yet.
# Usage: kernel-check.sh prepare <rundir>   (exit 75 = this kernel was already checked)
#        kernel-check.sh finish <rundir>    (records the kernel as checked)
last=$BARCH_STATE/last-kernel
kernel=$(uname -r)

case $1 in
  prepare) ;;
  finish) echo "$kernel" >"$last"; exit 0 ;;
  *) exit 0 ;;
esac
[[ $(cat "$last" 2>/dev/null) == "$kernel" ]] && exit 75

out=$2/context.md
section() { printf '\n## %s\n\n```\n' "$1"; shift; "$@" 2>&1; printf '```\n'; }

{
  echo "# Kernel facts — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "- Kernel now: $kernel"
  echo "- Kernel last checked: $(cat "$last" 2>/dev/null || echo 'none (first run of this check)')"
  echo "- Kernel of the previous boot: $(journalctl -b -1 -k -o cat -g '^Linux version' --no-pager 2>/dev/null | head -1)"
  section "Packages" pacman -Q linux-cachyos linux-cachyos-headers nvidia-open-dkms nvidia-utils
  section "Kernel command line" cat /proc/cmdline
  section "dkms status" dkms status
  section "Loaded modules (nvidia, ntsync)" sh -c "lsmod | grep -E '^(nvidia|ntsync)'"
  section "nvidia-smi" nvidia-smi --query-gpu=name,driver_version,pstate,temperature.gpu --format=csv
  section "NTSYNC device" ls -l /dev/ntsync
  section "BORE (/proc/sys/kernel/sched_bore)" cat /proc/sys/kernel/sched_bore
  section "Kernel log of this boot, warnings and worse" journalctl -k -b 0 -p warning --no-pager -o short-monotonic
  section "Kernel log of the previous boot, warnings and worse" journalctl -k -b -1 -p warning --no-pager -o short-monotonic
  section "Failed units" sh -c 'systemctl --failed --no-legend; systemctl --user --failed --no-legend'
} >"$out"
