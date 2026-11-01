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
VM_SKIP='^/(etc/fstab|etc/crypttab|etc/kernel/cmdline|etc/default/limine|boot/|etc/mkinitcpio|etc/initcpio/|etc/modprobe\.d/nvidia|etc/docker/daemon\.json|etc/hostname|etc/vconsole\.conf|etc/systemd/system/getty@)'
[[ -n "$VIRT" && "$VIRT" != none ]] && warn "running in a VM ($VIRT): disk, boot and NVIDIA files are skipped"

changed=()
while IFS= read -r -d '' file; do
  target="/${file#"$src"/}"
  if [[ -n "$VIRT" && "$VIRT" != none && "$target" =~ $VM_SKIP ]]; then
    ok "skipped in VM: $target"; continue
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
  ask "Create the snapper config for / (snapper -c root create-config /)?" \
    && sudo snapper -c root create-config / && ok "config root created"
else
  warn "/ is not btrfs: no snapper config"
fi

step "System services"
for s in "${SYSTEM_SERVICES[@]}"; do
  if systemctl is-enabled --quiet "$s" 2>/dev/null; then ok "$s already enabled"; continue; fi
  ask "Enable $s?" && sudo systemctl enable --now "$s" && ok "$s"
done

((${#changed[@]})) || { ok "No files changed."; exit 0; }

step "Next steps"
printf '  %s\n' "${changed[@]}"
echo
echo "  If the kernel command line, mkinitcpio or initcpio files changed:  sudo mkinitcpio -P"
echo "  If limine files changed: check that the boot entries are correct before rebooting."
echo "  If fstab or mount units changed:  sudo systemctl daemon-reload"
