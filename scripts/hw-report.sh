#!/usr/bin/env bash
# hw-report.sh: read-only snapshot of a machine's firmware, buses and kernel log, made for
# validating new hardware (docs/new-machine.md). Self-contained on purpose: it runs from the
# Arch ISO too (copy it to the stick), needs only bash, coreutils, pciutils and usbutils, and
# never changes anything.
#   ./scripts/hw-report.sh [outdir]          # default: ./hw-report-<host>-<date>
#   sudo ./scripts/hw-report.sh              # same, with the full kernel log when dmesg is restricted
# Output: one folder plus a .tar.gz of it; summary.txt first lists every known-bad pattern found
# in the log (USB hubs, xHCI timeouts, IOMMU faults, IRQ and ACPI errors, NVMe timeouts).
set -uo pipefail

out=$(realpath -m "${1:-./hw-report-$(uname -n)-$(date +%Y%m%d-%H%M%S)}")
mkdir -p "$out" || exit 1
cd "$out" || exit 1

# run <file> <command...>: output and errors into <file>, never stop on a failing command
run() { local f=$1; shift; { echo "\$ $*"; "$@"; } >"$f" 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }
dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || echo "?"; }

# kernel log of this boot: dmesg if readable, else the journal
if dmesg >/dev/null 2>&1; then
  dmesg -T >kernel.log 2>&1
elif have journalctl; then
  journalctl -k -b 0 --no-pager >kernel.log 2>&1
else
  echo "no readable kernel log (run with sudo)" >kernel.log
fi
# the previous boot, when the journal is persistent: what a freeze left behind
have journalctl && journalctl -k -b -1 --no-pager >kernel-previous-boot.log 2>&1

{
  echo "date:      $(date -Is)"
  echo "kernel:    $(uname -r)"
  echo "cmdline:   $(cat /proc/cmdline)"
  echo "board:     $(dmi board_vendor) $(dmi board_name) (rev $(dmi board_version))"
  echo "bios:      $(dmi bios_vendor) $(dmi bios_version) ($(dmi bios_date))"
  echo "cpu:       $(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)"
  echo "microcode: $(awk -F': ' '/^microcode/ {print $2; exit}' /proc/cpuinfo)"
  echo "memory:    $(awk '/^MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
  sb=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ')
  echo "secure boot: ${sb:-?} (1 = on)"
  echo "iommu groups: $(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
  x3d=$(cat /sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode 2>/dev/null)
  echo "x3d mode:  ${x3d:-not present}"
} >system.txt

run pci.txt lspci -nnk
run pci-tree.txt lspci -tv
run usb.txt lsusb
run usb-tree.txt lsusb -tv
run block.txt lsblk -o NAME,MODEL,SIZE,TRAN,TYPE,FSTYPE,MOUNTPOINTS
run net.txt ip -br link
have nvme && run nvme.txt nvme list
have rfkill && run rfkill.txt rfkill list

# which PCI controller owns each USB bus: tells a chipset port from a CPU or USB4 one
for bus in /sys/bus/usb/devices/usb*; do
  [[ -e $bus ]] || continue
  pci=$(basename "$(readlink -f "$bus/..")")
  printf '%-6s %s  %s\n' "$(basename "$bus")" "$pci" "$(lspci -s "$pci" 2>/dev/null | cut -d' ' -f2-)"
done >usb-controllers.txt

# IOMMU groups with their devices (what can be passed to a VM on its own)
for g in /sys/kernel/iommu_groups/*; do
  [[ -d $g ]] || continue
  for d in "$g"/devices/*; do
    printf 'group %-3s %s\n' "$(basename "$g")" "$(lspci -nns "$(basename "$d")" 2>/dev/null)"
  done
done | sort -V >iommu-groups.txt

# known-bad patterns, each with a count and its first lines
patterns=(
  "hub doesn't have any ports|config failed, hub"
  "device descriptor read|device not accepting address|error -(71|110)"
  "xhci.*(HC died|halted|not responding|timeout|error)"
  "thunderbolt.*(error|fail|missing)|USB4.*(error|fail)"
  "IO_PAGE_FAULT|AMD-Vi.*(fault|error|event)"
  "can't find IRQ|irq.*(fail|nobody cared)|AMDI0030"
  "ACPI (BIOS )?Error|ACPI Exception|\\[Firmware Bug\\]"
  "nvme.*(timeout|reset|I/O error)"
  "\\[Hardware Error\\]|Machine check events logged|EDAC .*(CE|UE)"
  "BTRFS (error|critical)|csum failed"
  "Call Trace|kernel BUG|BUG:|Oops"
)
# lines that match a pattern above but are harmless on every machine
benign="_OSI\\(Linux\\) query ignored"
{
  cat system.txt
  echo
  echo "== Known-bad patterns in this boot's kernel log"
  for p in "${patterns[@]}"; do
    hits=$(grep -iE "$p" kernel.log | grep -vE "$benign")
    n=$(grep -c . <<<"$hits")
    printf '%5s  %s\n' "$n" "$p"
    ((n > 0)) && head -5 <<<"$hits" | sed 's/^/         /'
  done
  if [[ -s kernel-previous-boot.log ]] && ! grep -q 'No entries\|Specifying boot ID' kernel-previous-boot.log; then
    echo
    echo "== Previous boot: last 15 kernel lines (where a freeze stopped)"
    tail -15 kernel-previous-boot.log
  fi
} >summary.txt

tar -czf "$out.tar.gz" -C "$(dirname "$out")" "$(basename "$out")"
cat summary.txt
echo
echo "Report: $out/ and $out.tar.gz"
