#!/usr/bin/env bash
# Fresh install: puts the files from system/files/ back into place, one by one,
# showing the difference and asking before each. Redacted passwords must be filled in by hand.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

src="$REPO/system/files"
modes="$REPO/system/modes.txt"
[[ -d "$src" ]] || die "system/files is empty; run collect-system.sh on the original machine first"

mode_of() { awk -v f="$1" '$2 == f { print $1; exit }' "$modes" 2>/dev/null || true; }

# Numa VM (teste do repositório), arquivos ligados ao disco, ao boot e ao hardware desta
# máquina ficam de fora: aplicá-los deixaria a VM sem boot.
VIRT=$(systemd-detect-virt 2>/dev/null || true)
VM_SKIP='^/(etc/fstab|etc/crypttab|etc/kernel/cmdline|etc/default/limine|boot/|etc/mkinitcpio|etc/initcpio/|etc/modprobe\.d/nvidia|etc/docker/daemon\.json|etc/hostname|etc/vconsole\.conf|etc/systemd/system/getty@|etc/systemd/network/30-virbr0\.)'
# 30-virbr0.* too: a test VM usually gets its own address from the host's 192.168.122.0/24, and a
# bridge with 192.168.122.1/24 inside it would take that route and cut the guest off
[[ -n "$VIRT" && "$VIRT" != none ]] && warn "running in a VM ($VIRT): disk, boot, NVIDIA and VM-bridge files are skipped"

# The disk files carry the UUIDs of the disk they were collected from. On a new install (a new
# disk, even for the same user) they would leave the machine unbootable, so they are skipped
# when / is not the filesystem the repo's fstab names; the NAS lines are merged by hand.
DISK_FILES='^/(etc/fstab|etc/crypttab|etc/kernel/cmdline|etc/default/limine|boot/limine\.conf)$'
ROOT_UUID=$(findmnt -no UUID / 2>/dev/null || true)
if [[ -n "$ROOT_UUID" ]] && ! grep -q "UUID=$ROOT_UUID" "$src/etc/fstab" 2>/dev/null; then
  SAME_DISK=no
  warn "/ is a different disk than the repo's fstab: fstab, crypttab, kernel cmdline and limine files are skipped"
else
  SAME_DISK=yes
fi

# The ACPI override (etc/initcpio/acpi_override/apic.aml, loaded by the acpi_override hook) is
# a MADT patched for one Ryzen 7 5800X3D whose core 7 crashes: on any other CPU it describes the
# wrong processor (the AM5 build wants every core). Only that CPU gets the table and the hook;
# elsewhere the table is skipped and mkinitcpio.conf is offered without the hook.
ACPI_OVERRIDE_CPU='AMD Ryzen 7 5800X3D 8-Core Processor'
CPU_MODEL=$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)
if [[ "$CPU_MODEL" != "$ACPI_OVERRIDE_CPU" ]]; then
  ACPI_OVERRIDE=no
  warn "CPU is '$CPU_MODEL': the ACPI override (core 7 off, for the 5800X3D) is left out"
else
  ACPI_OVERRIDE=yes
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The GPU drivers chosen in install.sh: without NVIDIA its module options, Docker's NVIDIA runtime
# and the nvidia modules in the initramfs are left out (mkinitcpio would fail on the missing modules).
gpu_choose
NVIDIA_FILES='^/etc/(modprobe\.d/nvidia\.conf|docker/daemon\.json)$'
gpu_has nvidia || warn "no NVIDIA driver chosen: its module options, Docker runtime and initramfs modules are left out"

mkinitcpio_conf() {   # the repo's mkinitcpio.conf with the hooks and modules this machine has no use for
  local sed_args=()
  [[ "$ACPI_OVERRIDE" == no ]] && sed_args+=(-e '/^HOOKS=/ { s/\bacpi_override\b ?//; s/\( /(/ }')
  gpu_has nvidia || sed_args+=(-e '/^MODULES=/ { s/\bnvidia(_modeset|_uvm|_drm)?\b ?//g; s/\( /(/; s/ \)/)/ }')
  if ((${#sed_args[@]})); then sed -E "${sed_args[@]}" "$1"; else cat "$1"; fi
}

changed=()
while IFS= read -r -d '' file; do
  target="/${file#"$src"/}"
  if [[ -n "$VIRT" && "$VIRT" != none && "$target" =~ $VM_SKIP ]]; then
    ok "skipped in VM: $target"; continue
  fi
  if [[ "$SAME_DISK" == no && "$target" =~ $DISK_FILES ]]; then
    ok "skipped (other disk, its UUIDs): $target"; continue
  fi
  if [[ "$ACPI_OVERRIDE" == no && "$target" == /etc/initcpio/acpi_override/* ]]; then
    ok "skipped (ACPI override, other CPU): $target"; continue
  fi
  if ! gpu_has nvidia && [[ "$target" =~ $NVIDIA_FILES ]]; then
    ok "skipped (no NVIDIA): $target"; continue
  fi
  if [[ "$target" == /etc/mkinitcpio.conf ]]; then
    mkinitcpio_conf "$file" > "$tmp/mkinitcpio.conf"
    file="$tmp/mkinitcpio.conf"
  fi
  if sudo test -f "$target" && sudo cmp -s "$file" "$target"; then
    ok "unchanged: $target"; continue
  fi
  step "$target"
  sudo test -f "$target" && sudo diff -u "$target" "$file" || true
  grep -q REDACTED "$file" && warn "contains REDACTED values: fill them in after installing"
  if ask "Install this file?"; then
    m="$(mode_of "$target")"
    sudo install -D -m "${m:-644}" "$file" "$target"
    changed+=("$target")
    ok "installed"
  fi
done < <(find "$src" -type f -print0 | sort -z)

step "Snapper"
# snap-pac, the snapshot entries in Limine and the agent's safety snapshots all use config "root"
if sudo test -f /etc/snapper/configs/root; then
  ok "config root already exists"
elif findmnt -no FSTYPE / | grep -qx btrfs; then
  # create-config makes /.snapshots a subvolume of its own and fails when it already exists.
  # With @snapshots mounted there (INSTALL.md): let snapper create its subvolume, delete it and
  # mount @snapshots back, so the snapshots stay outside @ and survive a rollback.
  if ask "Create the snapper config for / (snapper -c root create-config /)?"; then
    if mountpoint -q /.snapshots; then
      if sudo umount /.snapshots && sudo rmdir /.snapshots \
        && sudo snapper -c root create-config / \
        && sudo btrfs subvolume delete /.snapshots \
        && sudo mkdir /.snapshots \
        && sudo mount /.snapshots \
        && sudo chmod 750 /.snapshots; then
        ok "config root created, /.snapshots is the @snapshots subvolume again"
      else
        warn "snapper setup did not finish: check /.snapshots (fstab entry, sudo mount -a)"
      fi
    elif [[ -d /.snapshots ]] && ! sudo btrfs subvolume show /.snapshots >/dev/null 2>&1; then
      if sudo rmdir /.snapshots 2>/dev/null && sudo snapper -c root create-config /; then
        ok "config root created"
      else
        warn "/.snapshots is a non-empty folder: move it away and run this again"
      fi
    else
      sudo snapper -c root create-config / && ok "config root created"
    fi
  fi
else
  warn "/ is not btrfs: no snapper config"
fi

step "System services"
for s in "${SYSTEM_SERVICES[@]}"; do
  if systemctl is-enabled --quiet "$s" 2>/dev/null; then ok "$s already enabled"; continue; fi
  ask "Enable $s?" && sudo systemctl enable --now "$s" && ok "$s"
done

# libvirt's network "default" is only a pointer to virbr0, the bridge systemd-networkd serves
# (30-virbr0.*): no dnsmasq. A fresh libvirt (or the old NAT network) gets the repo's definition
if command -v virsh >/dev/null && [[ -z "$VIRT" || "$VIRT" == none ]]; then
  step "libvirt network"
  v="virsh -c qemu:///system"
  if sudo $v net-dumpxml default 2>/dev/null | grep -q "<forward mode='bridge'"; then
    ok "network default already points at virbr0"
  elif ask "Make libvirt's network \"default\" use the networkd bridge virbr0 (no dnsmasq)?"; then
    sudo $v net-destroy default >/dev/null 2>&1 || true
    sudo $v net-undefine default >/dev/null 2>&1 || true
    sudo networkctl reload
    if sudo $v net-define "$REPO/system/libvirt/default.xml" >/dev/null && sudo $v net-autostart default >/dev/null \
      && sudo $v net-start default >/dev/null; then
      ok "network default -> virbr0"
    else
      warn "could not define the network: sudo $v net-define $REPO/system/libvirt/default.xml"
    fi
  fi
fi

((${#changed[@]})) || { ok "No files changed."; exit 0; }

step "Next steps"
printf '  %s\n' "${changed[@]}"
echo
echo "  If the kernel command line, mkinitcpio or initcpio files changed:  sudo mkinitcpio -P"
echo "  If limine files changed: check that the boot entries are correct before rebooting."
echo "  If fstab or mount units changed:  sudo systemctl daemon-reload"
