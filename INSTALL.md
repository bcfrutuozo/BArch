# Installing Arch for BArch

How the machine this repo runs on was installed, step by step, so you can reproduce it on your
own hardware (or in a VM) before running `install.sh`. The end result:

| Piece | What |
|---|---|
| Disk | GPT: a 4 GiB ESP (`/boot`, FAT32) and one LUKS2 partition with everything else |
| Encryption | LUKS2, unlocked by the TPM (PCR 7) with the passphrase as fallback |
| Filesystem | btrfs inside LUKS, one subvolume per thing that must not roll back with `/` |
| Snapshots | snapper on `/`, a pre/post pair for every pacman transaction (`snap-pac`), bootable from Limine (`limine-snapper-sync`) |
| Boot | Limine (UEFI) loading Unified Kernel Images (UKI) built by mkinitcpio with a systemd initramfs |
| Secure Boot | your own keys with `sbctl` (Microsoft keys kept for option ROMs) |
| Swap | zram only, no swap partition or file |

The commands assume an NVMe disk (`/dev/nvme0n1`), a user called `you`, and the values of this
machine (Brazilian keyboard, São Paulo time, English system with Portuguese locale). Change
them as you go. Every step that only applies to Bruno's hardware is marked **(this machine)**.

**(this machine)** The AM5 build (late 2026) dual boots: Linux and Windows 11 Enterprise on the
WD_BLACK SN8100 2 TB, the old SN770 1 TB as an NTFS games disk shared by both. Step 2 has its
exact partitions, step 16 Windows and step 17 the games disk; the reasoning is in
[docs/new-machine.md](docs/new-machine.md) ("Disks and dual boot").

> **Read before you start.** Partitioning wipes the disk. Have the Arch ISO on a USB stick, a
> wired connection or Wi-Fi credentials, and a second device with this page open.

---

## 0. Firmware

- UEFI only (no CSM/legacy).
- Secure Boot **off** for now, or in **Setup Mode** (keys cleared). It is turned on at the end
  (step 12). Some firmwares only let you clear the keys from the Secure Boot menu ("Reset to
  Setup Mode", "Delete all keys").
- TPM 2.0 on (fTPM / PTT). In a VM: OVMF firmware, and `swtpm` if you want to test the TPM
  unlock; otherwise skip steps 12 and 13.

## 1. Live ISO

```bash
loadkeys br-abnt2                 # your keymap
iwctl                             # Wi-Fi only: station wlan0 connect <SSID>
ping -c2 archlinux.org
timedatectl set-ntp true
```

## 2. Partitions

```bash
sgdisk --zap-all /dev/nvme0n1
sgdisk -n1:0:+4G -t1:ef00 -c1:ESP       /dev/nvme0n1   # EFI system partition
sgdisk -n2:0:0   -t2:8309 -c2:cryptroot /dev/nvme0n1   # LUKS
partprobe /dev/nvme0n1
```

Why 4 GiB: every kernel is a UKI of 60–120 MB, and `limine-snapper-sync` keeps copies of the
UKIs of the snapshots it lists in the boot menu. 512 MB fills up after a few kernel updates.

### (this machine) SN8100 with room for Windows

**Install with only the SN8100 on the board.** The old SN770 still carries partitions labelled
`ESP` and `cryptroot` (the previous install): with both disks in, `/dev/disk/by-partlabel/...`
is ambiguous and the rest of this page could format or enroll the wrong one, and the firmware
may boot the old Limine. The SN770 goes into M2_5 only once the new system is installed and
booting on its own, after Windows; step 17 copies its data and then wipes it.

Pick the disk by model, never by `nvme0`/`nvme1` (the order follows the slots, not the disks):

```bash
ls -l /dev/disk/by-id/ | grep -i sn8100
SYS=$(ls /dev/disk/by-id/nvme-WD_BLACK_SN8100_* | grep -v -- -part | head -1)
lsblk "$SYS"                                  # one disk, ~1.8T, the right one

# 4 KiB logical sectors, so disk, LUKS (step 3) and btrfs all write in 4K: no 4K LUKS sector
# can be half-written on a power cut. Erases the whole drive; do it after the day-2 fio tests.
nvme id-ns -H "$SYS" | grep "LBA Format"     # the line with "Data Size: 4096 bytes" gives the number
nvme format "$SYS" --lbaf=<that number>      # skip if the drive only offers 512
cat /sys/block/$(basename "$(readlink -f "$SYS")")/queue/logical_block_size   # 4096

sgdisk --zap-all "$SYS"
sgdisk -n1:0:+4G    -t1:ef00 -c1:ESP       "$SYS"   # ESP, shared with Windows later
sgdisk -n2:0:+1580G -t2:8309 -c2:cryptroot "$SYS"   # LUKS, ~1.7 TB for Linux
partprobe "$SYS"
sgdisk -p "$SYS"                              # "Total free space" at the end: ~279 GiB
```

| # | Partition | Size | |
|---|---|---|---|
| 1 | ESP | 4 GiB | Limine, UKIs, snapshot entries; Windows adds `\EFI\Microsoft` (~100 MB) |
| 2 | cryptroot | 1580 GiB | LUKS2 → btrfs, everything Linux |
| — | free | ~279 GiB | **leave it unallocated**: Windows Setup creates MSR, NTFS (~300 GB) and WinRE there |

The disk is 2 TB = ~1863 GiB. Windows sits after Linux, so this split is meant to stay: growing
Linux later means moving the start of the Windows partition. From here on the commands use
`by-partlabel`, which is safe only because the SN8100 is the one disk.

## 3. LUKS2

```bash
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 \
  /dev/disk/by-partlabel/cryptroot
cryptsetup open --allow-discards --perf-no_read_workqueue --perf-no_write_workqueue \
  --persistent /dev/disk/by-partlabel/cryptroot cryptroot
cryptsetup luksDump /dev/disk/by-partlabel/cryptroot | grep -E '^(Flags|\s+(cipher|sector))'
dmsetup table cryptroot                 # ends with: allow_discards no_read_workqueue no_write_workqueue sector_size:4096
```

`--key-size 512`: XTS splits it in two, so this is AES-256 (cryptsetup's default, written out so
it matches BitLocker's XTS-AES 256 on the Windows side). `--sector-size 4096`: one encryption per 4K block instead of eight 512-byte ones (btrfs writes 4K
blocks anyway); it cannot be changed later without `cryptsetup reencrypt`. `--persistent` stores
the flags in the LUKS2 header, so every later unlock (initramfs, TPM) uses them with nothing in
the kernel command line: TRIM through LUKS, and en/decryption done inline instead of through
dm-crypt's kernel workqueues. Both target 4K latency on NVMe: on the old 5800X3D + SN770, with
512-byte sectors and neither flag, dm-crypt added ~11 µs to a 79 µs 4K read (fio, QD1). Undo the two `perf` flags any time with
`cryptsetup refresh --allow-discards --persistent cryptroot`.

Choose a real passphrase: the TPM unlock comes later and the passphrase is what you type
whenever the TPM refuses (firmware or Secure Boot changes, see [docs/machine.md](docs/machine.md)).

## 4. btrfs and the subvolumes

```bash
mkfs.fat -F32 -n ESP /dev/disk/by-partlabel/ESP
mkfs.btrfs -L arch /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
for sv in @ @home @snapshots @log @pkg @docker @vms; do btrfs subvolume create /mnt/$sv; done
btrfs subvolume create /mnt/@games          # (this machine) Wine/Proton prefixes and runners
umount /mnt
```

| Subvolume | Mounted at | Why it is separate |
|---|---|---|
| `@` | `/` | what snapper snapshots and what a rollback replaces |
| `@home` | `/home` | your files never roll back with the system (the repo has git, the rest has the backup) |
| `@snapshots` | `/.snapshots` | snapper's snapshots live outside `@`, so a rollback does not lose them |
| `@log` | `/var/log` | logs survive a rollback (you want to read why you rolled back) |
| `@pkg` | `/var/cache/pacman/pkg` | the package cache is not copied into every snapshot |
| `@docker` | `/var/lib/docker` | images and containers: big, constantly changing, not system state |
| `@vms` | `/var/lib/libvirt/images` | VM disks; also set `chattr +C` on it (below) so qcow2 files are not copy-on-write |
| `@games` | `/home/you/Games` | (this machine) game libraries stay out of `@home`'s backup and snapshots; on the AM5 build the games themselves go to the NTFS disk (step 17) and this keeps the Wine/Proton prefixes, which must not live on NTFS |

Mount them all with the same options:

```bash
o=noatime,compress=zstd:1,ssd,discard=async,space_cache=v2
mount -o $o,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache/pacman/pkg,var/lib/docker,var/lib/libvirt/images,boot}
mount -o $o,subvol=@home      /dev/mapper/cryptroot /mnt/home
mount -o $o,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o $o,subvol=@log       /dev/mapper/cryptroot /mnt/var/log
mount -o $o,subvol=@pkg       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o $o,subvol=@docker    /dev/mapper/cryptroot /mnt/var/lib/docker
mount -o $o,subvol=@vms       /dev/mapper/cryptroot /mnt/var/lib/libvirt/images
chattr +C /mnt/var/lib/libvirt/images
mount -o fmask=0077,dmask=0077 /dev/disk/by-partlabel/ESP /mnt/boot
```

(`@games` is mounted after the user exists, step 7.)

## 5. pacstrap

What this machine was installed with:

```bash
pacstrap -K /mnt base base-devel linux linux-headers linux-firmware amd-ucode \
  btrfs-progs cryptsetup networkmanager sudo git neovim efibootmgr limine sbctl tpm2-tss \
  zram-generator snapper snap-pac \
  nvidia-open-dkms nvidia-utils          # (this machine) RTX 5090 (Blackwell: the open modules only)
```

- Intel CPU: `intel-ucode` instead of `amd-ucode`.
- No NVIDIA card (or a VM): leave out the last line.
- The stock `linux` stays installed even on this machine: it is the fallback entry in Limine
  while the CachyOS kernel is built (step 14).

## 6. fstab

```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

Then **edit `/mnt/etc/fstab` and remove every `subvolid=NNN`** that genfstab adds, keeping only
`subvol=/@…`. A rollback (`limine-snapper-restore` replaces `@` with a copy of the snapshot)
gives `@` a new id: with the old `subvolid` still in fstab the two options disagree and `/`
does not mount. Compare with `system/files/etc/fstab` in this repo
(the NAS lines at its end are this machine only).

## 7. Inside the new system

```bash
arch-chroot /mnt

ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
sed -i 's/^#\(en_US.UTF-8\)/\1/; s/^#\(pt_BR.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8'  > /etc/locale.conf
echo 'KEYMAP=br-abnt2'   > /etc/vconsole.conf
echo 'yourhostname'      > /etc/hostname

passwd                                       # root
useradd -m -G wheel you && passwd you
EDITOR=nvim visudo                           # uncomment: %wheel ALL=(ALL:ALL) ALL
systemctl enable NetworkManager fstrim.timer

# (this machine) the games subvolume, owned by the user
mkdir -p /home/you/Games && chown you: /home/you/Games
echo "UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)  /home/you/Games  btrfs  noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=/@games  0 0" >> /etc/fstab
```

zram: `/etc/systemd/zram-generator.conf` (copy it from `system/files/etc/systemd/`):

```ini
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
```

and `zswap.enabled=0` on the kernel command line (step 8), so zswap does not sit in front of
zram.

## 8. Initramfs and the kernel command line

This setup uses the **systemd** initramfs (`systemd`, `sd-vconsole`, `sd-encrypt`), which is
what unlocks LUKS with the TPM. `/etc/mkinitcpio.conf`:

```bash
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)     # (this machine) early KMS; empty otherwise
HOOKS=(base systemd autodetect keyboard microcode modconf sd-vconsole block sd-encrypt filesystems fsck)
```

The repo's copy (`system/files/etc/mkinitcpio.conf`) also has two hooks you must **not** copy
to another machine:

- `acpi_override` **(this machine)**: loads `etc/initcpio/acpi_override/apic.aml`, a patched
  ACPI MADT table that disables CPU core 7, which crashes this particular CPU. On any other
  machine it describes the wrong CPU. `apply-system.sh` (step 11) checks the CPU model: on
  anything but that Ryzen 7 5800X3D it skips the table and offers `mkinitcpio.conf` without the
  hook, so the AM5 build runs every core. The first `sync.sh` there drops both from `system/`.
- `plymouth`: the boot splash. Optional; if you want it, install `plymouth`, put the hook after
  `systemd` and keep `splash` on the command line.

NVIDIA (this machine), `/etc/modprobe.d/nvidia.conf`:

```
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_EnableResizableBar=1
```

and enable the suspend helpers: `systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate`.

The command line goes in **both** `/etc/kernel/cmdline` and (later, step 10)
`/etc/default/limine`. `rd.luks.name` takes the UUID of the **LUKS partition**, not of the
btrfs inside it:

```bash
LUKS=$(blkid -s UUID -o value /dev/disk/by-partlabel/cryptroot)
echo "rd.luks.name=$LUKS=cryptroot rd.luks.options=tpm2-device=auto root=/dev/mapper/cryptroot rootflags=subvol=/@ rw quiet splash loglevel=3 zswap.enabled=0" > /etc/kernel/cmdline
```

(`rd.luks.options=tpm2-device=auto` is harmless before the TPM is enrolled: it asks for the
passphrase.)

## 9. First boot: a UKI and Limine by hand

The tools that automate Limine's entries are in the AUR, which is not reachable from the chroot
yet, so the first boot uses a UKI from mkinitcpio's own preset and a minimal `limine.conf`.

`/etc/mkinitcpio.d/linux.preset`: comment out the `default_image` / `fallback_*` lines and set

```bash
default_uki="/boot/EFI/Linux/arch-linux.efi"
```

then:

```bash
mkdir -p /boot/EFI/Linux /boot/EFI/limine /boot/EFI/BOOT
mkinitcpio -P
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/          # fallback path, firmwares that forget entries
cat > /boot/limine.conf <<'EOF'
timeout: 3

/Arch Linux
    protocol: efi
    path: boot():/EFI/Linux/arch-linux.efi
EOF
efibootmgr --create --disk /dev/nvme0n1 --part 1 --label Limine --loader '\EFI\limine\BOOTX64.EFI'
```

**(this machine)** the same, with the disk by id (variables from the live shell do not exist in
the chroot):

```bash
SYS=$(ls /dev/disk/by-id/nvme-WD_BLACK_SN8100_* | grep -v -- -part | head -1)
efibootmgr --create --disk "$SYS" --part 1 --label Limine --loader '\EFI\limine\BOOTX64.EFI'
```

The UKI carries the command line, the microcode and the initramfs, so the entry needs no
`cmdline:`.

```bash
exit
umount -R /mnt
reboot
```

It should ask for the LUKS passphrase and boot to a console.

**(this machine)** Stop here for the hardware tests of [docs/new-machine.md](docs/new-machine.md)
(console only, stock kernel: MemTest86+ first, then mprime, y-cruncher, gpu-burn). Continue
with step 10 only once the board, the CPU, the RAM and the 5090 passed; nothing above has to be
redone. There is no AUR helper yet: `stress-ng`, `smartmontools`, `nvme-cli`, `lm_sensors`,
`fio` come from pacman; mprime and y-cruncher are static tarballs from their sites (run them
from a folder in your home); gpu-burn is built with `git clone https://aur.archlinux.org/gpu-burn-git.git && cd gpu-burn-git && makepkg -si`
(it pulls `cuda`).

## 10. Snapper, Limine automation and the repo

Log in as your user. Snapper first: `snapper create-config /` wants to create `/.snapshots`
itself and fails when `@snapshots` is already mounted there, so let it create its subvolume,
delete it and mount ours back (`apply-system.sh`, step 11, does the same when the config is
still missing):

```bash
sudo umount /.snapshots
sudo rmdir /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a                       # @snapshots again, from fstab
sudo chmod 750 /.snapshots
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
```

Limits worth setting in `/etc/snapper/configs/root` (snap-pac adds two snapshots per pacman
run, so the number cleanup matters more than the timeline): `NUMBER_LIMIT="20"`,
`NUMBER_LIMIT_IMPORTANT="10"`, `TIMELINE_LIMIT_HOURLY="5"`, `TIMELINE_LIMIT_DAILY="7"`,
`TIMELINE_LIMIT_WEEKLY="2"`, `TIMELINE_LIMIT_MONTHLY="1"`, `TIMELINE_LIMIT_YEARLY="0"`. If your
user should list snapshots without sudo: `ALLOW_USERS="you"`.

Now the repo (it brings paru and the AUR packages, among them `limine-mkinitcpio-hook` and
`limine-snapper-sync`):

```bash
sudo pacman -S --needed git github-cli openssh
gh auth login
git clone git@github.com:bcfrutuozo/BArch.git ~/BArch     # or your fork
cd ~/BArch
./install.sh
```

From here **`limine-mkinitcpio-hook` owns the boot files**: it builds one UKI per kernel
(`/boot/EFI/Linux/<machine-id>_<kernel>.efi`) and writes the entries of `/boot/limine.conf`
itself. Undo the manual preset of step 9 (restore the original `linux.preset`, or delete it:
the hook does not use it), then write `/etc/default/limine`:

```bash
ENABLE_UKI=yes
KERNEL_CMDLINE[default]="rd.luks.name=<LUKS UUID>=cryptroot rd.luks.options=tpm2-device=auto root=/dev/mapper/cryptroot rootflags=subvol=/@ rw quiet splash loglevel=3 zswap.enabled=0"
ROOT_SNAPSHOTS_PATH="/@snapshots"
MAX_SNAPSHOT_ENTRIES=auto
```

(the same line as `/etc/kernel/cmdline`), and `/etc/limine-snapper-sync.conf` (the repo's copy,
with `/etc/limine-entry-tool.conf`, is offered again by `apply-system.sh`):

```bash
LIMIT_USAGE_PERCENT=85            # stop adding snapshot entries when the ESP is 85 % full
RESTORE_METHOD=replace
SNAPSHOT_FORMAT_CHOICE=2
```

```bash
sudo limine-update                                     # UKIs + limine.conf entries
sudo rm -f /boot/EFI/Linux/arch-linux.efi              # the step 9 UKI
sudo systemctl enable --now limine-snapper-sync.service
```

`limine-snapper-sync` adds a **Snapshots** submenu under each kernel: booting one boots that
snapshot read-only (`rootflags=subvol=/@snapshots/N/snapshot`), and `limine-snapper-restore`
makes it the new `@`. The Limine theme (colors, wallpaper) comes from `tools/limine-theme.py`.

## 11. System files from the repo

```bash
./scripts/apply-system.sh
```

It shows a diff for every file of `system/files` and asks before copying it. On a machine that
is not Bruno's, answer **no** to:

| File | Why |
|---|---|
| `/etc/fstab`, `/etc/crypttab`, `/etc/kernel/cmdline`, `/etc/default/limine`, `/boot/limine.conf` | UUIDs of his disk, his NAS shares |
| `/etc/mkinitcpio.conf`, `/etc/initcpio/**` | `acpi_override` disables a core of his CPU (step 8); on another CPU the script already leaves it out, the rest of the file (NVIDIA modules, plymouth) is still his |
| `/etc/modprobe.d/nvidia.conf` | only with an NVIDIA card |
| `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | logs **his** user in on tty1; edit the user name before taking it |
| `/etc/hostname`, `/etc/vconsole.conf` | his host name, his keyboard |

Inside a VM it skips the disk, boot and NVIDIA files by itself. After it: `sudo limine-update`
if anything boot-related changed.

**(this machine)** On a new disk, even for the same user, the script skips the disk files by
itself (`/etc/fstab`, `/etc/crypttab`, `/etc/kernel/cmdline`, `/etc/default/limine`,
`/boot/limine.conf`: the root filesystem's UUID is not the one in the repo's fstab) and leaves
out the ACPI override (step 8). The ones written in steps 6–10 stay. Only the NAS shares come
over by hand, with their credentials file restored from the backup or written again:

```bash
grep cifs ~/BArch/system/files/etc/fstab | sudo tee -a /etc/fstab
sudo install -d -m 700 /etc/samba/credentials       # nasfrutuozo: username=, password=
sudo systemctl daemon-reload
```

## 12. Secure Boot

Reboot into the firmware, put Secure Boot in **Setup Mode**, boot Arch again and:

```bash
sudo sbctl status                       # Setup Mode: Enabled
sudo sbctl create-keys
sudo sbctl enroll-keys -m               # -m keeps Microsoft's keys: GPU option ROMs and firmware need them
sudo sbctl sign -s /boot/EFI/limine/BOOTX64.EFI
sudo sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sudo limine-update                      # rebuilds the UKIs; the limine tools sign them with sbctl
sudo sbctl verify                       # every .efi on the ESP must say "is signed"
```

`-s` saves the file in sbctl's database, so its pacman hook re-signs it after every update.
Reboot, turn Secure Boot **on** in the firmware, boot, and check `sbctl status` (Secure Boot:
Enabled). Lock the firmware setup with a password, or anyone can turn it off again.

`sbctl status` may report firmware quirks (this machine has FQ0001: it boots unsigned images
when the policy is violated); read the linked wiki page, the TPM binding below is what still
protects the disk in that case.

## 13. TPM unlock

Only once Secure Boot is on and stable, because PCR 7 measures the Secure Boot state:

```bash
sudo systemd-cryptenroll /dev/disk/by-partlabel/cryptroot --tpm2-device=auto --tpm2-pcrs=7
```

Reboot: the disk opens without the passphrase. After a firmware update, a dbx update or any
Secure Boot change the TPM refuses and the passphrase is asked again; re-enroll with the same
command plus `--wipe-slot=tpm2` (the bar warns about this, see [docs/machine.md](docs/machine.md)).

## 14. The CachyOS kernel (this machine)

`linux-cachyos` (BORE scheduler) is not installed by pacman: it is built by `kernel-update`
and listed in `IgnorePkg` in `/etc/pacman.conf` so `paru -Syu` never builds the stock one:

```bash
kernel-update -f
sudo limine-update
```

Elsewhere the stock `linux` is perfectly fine; skip this step (the VM path of `install.sh`
does).

## 15. Check

```bash
sudo snapper -c root list               # snap-pac pairs from the install are there
sudo limine-update && sudo sbctl verify
bootctl status | grep -i 'secure boot'  # enabled (user)
lsblk -f                                # ESP, crypto_LUKS → cryptroot btrfs
findmnt -t btrfs -o TARGET,OPTIONS      # every subvolume, no subvolid= from fstab
zramctl                                 # zram0 as swap
```

Then the rest of the README: `kernel-update -f` (this machine), restoring secrets from the
backup, and the post-install notes in **Fresh install**.

## 16. Windows (this machine)

Before the SN770 goes in, so Windows Setup sees one disk and one ESP: Windows 11 Enterprise (business
editions ISO) into the ~279 GiB left free on the SN8100 (Setup creates MSR, NTFS and WinRE there and puts its boot
manager in the existing ESP), with Secure Boot keys already enrolled with `-m` (step 12). In the
partition screen pick the **unallocated space** only, never partition 1 or 2.

The KMS activation right after the first login (`slmgr /ipk`, `/skms`, `/ato`, `/dlv`) and the
settings (Fast Startup and hibernation off, the `bcdedit` task that keeps Limine first,
telemetry, BitLocker with the TPM once Windows boots through Limine) are in [docs/new-machine.md](docs/new-machine.md). Back in Linux:

```bash
sudo limine-scan                        # pick "Windows Boot Manager": the entry goes into limine.conf
sudo systemd-cryptenroll /dev/disk/by-partlabel/cryptroot --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2   # only if the passphrase was asked
```

## 17. The games disk (this machine)

The SN770 is the previous install. The games themselves are downloaded again (Steam,
Battle.net); what is worth carrying over is what took work to get running and is not in the
backup (`~/Games` never is): the Battle.net prefix (launcher installed, logged in) and its
GE-Proton, the 3DMark prefix (.NET 4.8, the native `d3dcompiler_47`, the tests), and the
Proton builds Steam uses. About 22 GB. Secrets and app state come from the backup (README,
step 5 of **Fresh install**).

**a. Copy the runners and prefixes from the old disk.** Shut down, put the SN770 in M2_5, boot
the new system (make sure the firmware boots the SN8100's Limine, not the old one). Both disks
now have an `ESP` and a `cryptroot` label: from here address them by id only.

```bash
OLD=$(ls /dev/disk/by-id/nvme-WD_BLACK_SN770_1TB_* | grep -v -- -part | head -1)
lsblk -o NAME,SIZE,PARTLABEL "$OLD"             # 931.5G: ESP + cryptroot, the old system
sudo cryptsetup open "$OLD-part2" oldroot       # the old passphrase
sudo mkdir -p /mnt/old

# @games without the game files: battle.net/{prefix,proton}, 3dmark/prefix, re-enhance
sudo mount -o ro,subvol=@games /dev/mapper/oldroot /mnt/old
rsync -aH --info=progress2 \
  --exclude='/battle.net/games/' --exclude='/steam/' --exclude='/3dmark/setup/' \
  /mnt/old/ ~/Games/
sudo umount /mnt/old

# Steam's extra Proton builds (GE-Proton) from the old home
sudo mount -o ro,subvol=@home /dev/mapper/oldroot /mnt/old
mkdir -p ~/.local/share/Steam/compatibilitytools.d
rsync -aH /mnt/old/$USER/.local/share/Steam/compatibilitytools.d/ ~/.local/share/Steam/compatibilitytools.d/
# anything else still missing from the old home: copy it now, the disk is wiped next
sudo umount /mnt/old
sudo cryptsetup close oldroot

du -sh ~/Games/*                                # battle.net ~4 GB, 3dmark ~17 GB
```

**b. Wipe it and make it the games disk.**

```bash
GAMES="$OLD"
lsblk -o NAME,SIZE,PARTLABEL "$GAMES"           # last look: this is the disk being erased
sudo pacman -S --needed nvme-cli
# 4 KiB logical sectors, like the SN8100 (step 2); the format erases it and resets the SSD's state
sudo nvme id-ns -H "$GAMES" | grep "LBA Format"  # the line with "Data Size: 4096 bytes" gives the number
sudo nvme format "$GAMES" --lbaf=<that number>   # if it only offers 512: sudo blkdiscard -f "$GAMES"
cat /sys/block/$(basename "$(readlink -f "$GAMES")")/queue/logical_block_size   # 4096
sudo sgdisk -o -n1:0:0 -t1:0700 -c1:games "$GAMES"
sudo partprobe "$GAMES" && sudo udevadm settle
sudo pacman -S --needed ntfs-3g                 # mkfs.ntfs; mounting uses the kernel's ntfs3
sudo mkfs.ntfs -Q -c 4096 -L games "$GAMES-part1"   # 4K clusters: what ntfs3 handles best
sudo mkdir -p /games                            # at the root: /mnt stays for network shares (the NAS)
echo "UUID=$(sudo blkid -s UUID -o value "$GAMES-part1")  /games  ntfs3  uid=1000,gid=1000,windows_names,noatime,nofail  0 0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /games && df -h /games
```

`windows_names` refuses names Windows could not open; `nofail` keeps a missing or dirty disk
from stopping the boot.

**c. Point the launchers at it.** Two places from here on: **`/games`** (NTFS, both systems)
holds the games themselves, **`~/Games`** (`@games`, btrfs, outside snapper and the backup)
holds what only Linux uses: Wine/Proton prefixes, Proton builds, the `run.sh` launchers.
Prefixes never go on NTFS (they rely on symlinks, `:` in `dosdevices/c:`, case sensitivity and
Unix permissions).

```bash
# Battle.net: the launcher stays in ~/Games/battle.net/prefix; its G: drive, where the games
# install, now points at the NTFS disk (the same folder is D:\Battle.net in Windows)
mkdir -p /games/Battle.net
ln -sfn /games/Battle.net ~/Games/battle.net/prefix/dosdevices/g:
~/Games/battle.net/run.sh                       # install the games again into G:\
```

Steam (after `install.sh`, with Steam logged in):
1. Settings → Storage → add a library at `/games/SteamLibrary` (it creates `steamapps/`) and make
   it the default.
2. Quit Steam, keep its Proton prefixes on btrfs through a link, start Steam again:
   ```bash
   mkdir -p ~/Games/compatdata
   rm -rf /games/SteamLibrary/steamapps/compatdata
   ln -s ~/Games/compatdata /games/SteamLibrary/steamapps/compatdata
   ```
3. Install the games there.

Update the games path in `games/.config/gamemode.ini` (`~/Games/battle.net/games` →
`/games/Battle.net`) and the line about drive `G:` in [docs/machine.md](docs/machine.md). In
Windows, point Battle.net and Steam at the same folders (Battle.net → "Locate the game",
Steam → add `D:\SteamLibrary`) instead of downloading again.

## Testing in a VM first

- virt-manager / QEMU with UEFI (OVMF). For Secure Boot and TPM: the `*.secboot` OVMF variant
  and an emulated TPM 2.0 (`swtpm`); without them skip steps 12 and 13 and type the passphrase.
- Use `/dev/vda` instead of `/dev/nvme0n1` (and `vda1`, `vda2`), leave out the NVIDIA packages.
- `install.sh` and `apply-system.sh` detect the VM (`systemd-detect-virt`) and skip NVIDIA, the
  CachyOS kernel and every disk/boot file.
