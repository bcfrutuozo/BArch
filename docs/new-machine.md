# New machine: validating the AM5 build

The 2026-11 build (Ryzen 9 9950X3D, MSI MEG X870E GODLIKE, 2x32 GB DDR5-6000 CL30, WD_BLACK
SN8100 2 TB, MSI MPG Ai1300TS, ASUS TUF RTX 5090) replaces the 5800X3D/B550 described in [machine.md](machine.md).
The Godlike came through Amazon Global and **MSI Brasil does not take its RMA**: anything wrong
with it has to show up inside Amazon's 30-day return window. So the order is: prove the
machine under Linux from a USB stick first, migrate the system only after that.

Official manuals: `/mnt/nasfrutuozo/organization/desktops/bcfrutuozo/manuals/` (the Godlike, the
Maestro 900R, MSI Center).

## What the manual says about the ports

Back panel (manual p. 25, block diagram p. 90):

| Ports | From |
|---|---|
| 1: USB 10G Type-A, the top one, also the **Flash BIOS port** (its MCU flashes with no CPU) | X870E chipset |
| 2: USB 10G Type-A | X870E chipset |
| 3: 4x USB 10G Type-A | Realtek RTS5420 hub, behind the chipset |
| 11: 2x USB 40G Type-C (USB4, DisplayPort out) | ASM4242 (shares PCIe 5.0 x4 with M2_2) |
| 12: **3x USB 10G Type-C** | **CPU** |
| 13: USB 10G Type-C | X870E chipset |
| 14: USB 10G Type-A | X870E chipset |

- **No Type-A port comes from the CPU**: the CPU's USB is only the three Type-C ports of item 12.
  With Windows on its own partition (dual boot, below) the ToneX runs there natively, so its
  pedal no longer needs a CPU controller for a VM: any port works.
- **No HDMI**: the iGPU only comes out of the USB4 ports (DisplayPort alt mode, 4K 60 Hz), so the
  live ISO (no NVIDIA driver) and any test without the 5090 need a USB-C → DisplayPort cable.
- LAN: 10G Marvell AQC113CS (`atlantic`) and 5G Realtek RTL8126 (`r8169`).
- PCI_E1 + PCI_E2 from the CPU, x16/x0 or x8/x8; PCI_E3 x4 from the chipset (x2 with M2_4 used).
- Super I/O NCT6687: fans, pump and voltages need `nct6687d-dkms` (AUR); without it `sensors`
  shows only the CPU (k10temp) and the drives.

## Known Linux problems on MSI X870E boards

- [kernel bug 220469](https://bugzilla.kernel.org/show_bug.cgi?id=220469) (2025-08, Godlike, early
  BIOS): the live USB repeats `hub doesn't have any ports (err -19)` and freezes; `pci=nomsi` gets
  further, `acpi=off` sometimes boots. No BIOS or kernel version in the report, no answer yet.
- [kernel bug 221646](https://bugzilla.kernel.org/show_bug.cgi?id=221646) (2026-06, PRO X870E-S EVO,
  kernel 7.0): early hang with ACPI on, IRQ failures on xHCI and NVMe, ASM4242 USB4 probe `-110`.
  Points at MSI firmware across the X870E line rather than the Godlike alone.
- The board has USB devices of its own inside (Dynamic Dashboard, EZ Bridge on `JUSB_BRG_1`): a
  hub that reports no ports is likely one of those or the USB4 controller's virtual hub.
- Kernel 7.3 xHCI regression (devices that drop off during enumeration take ~6 s and may die,
  [CachyOS #1135](https://github.com/CachyOS/linux-cachyos/issues/1135)): carried as a fixup in
  `bin/.local/share/kernel-update/` until 7.3.y has upstream `6895dbdc19d9`.

## Before the first power-on

1. Photograph the sealed box, the serial label and the AM5 socket with its cover still on (bent
   pins void the return).
2. Update the BIOS with the Flash BIOS button (no CPU or RAM needed), FAT32 stick in the port the
   manual marks. Never cut power during the flash.
3. Parts per the manual: RAM in **DIMMA2 + DIMMB2**; SN8100 in **M2_1** (CPU); SN770 in M2_3 or
   M2_5 (chipset). M2_2 shares PCIe 5.0 x4 with the rear USB 40 Gbps ports (both drop to x2) and
   M2_4 shares with PCI_E3. The PSU's G.I. Port cable goes to **JUSB1**, the only free USB 2.0
   header.

BIOS baseline for the tests: EXPO on, Memory Context Restore on, Secure Boot off (until the
migration), everything else at defaults.

## Day 1: Linux from the stick

Write the current Arch ISO to a stick, copy `scripts/hw-report.sh` to a second stick (or to the
NAS), boot the ISO from a **rear USB-C port of item 12 (the CPU's)**: a USB-C stick or an adapter.

1. If it reaches the prompt: `bash /path/hw-report.sh /path/on/second/stick/report-day1` and read
   `summary.txt`. Every count there should be 0 (the nvidia trace below aside).
2. If it freezes, try one change at a time, write down what each one changes, and run the report
   whenever it boots:
   - BIOS: disable the USB4 controller; then the Dynamic Dashboard; then Wi-Fi/Bluetooth.
   - Kernel command line (`e` at the ISO menu): `modprobe.blacklist=thunderbolt`, then
     `usbcore.autosuspend=-1`.
   - Diagnosis only, never a fix: `pci=nomsi`, `acpi=off`. They show where it breaks.
3. Seeing a freeze: remove `quiet` and add `ignore_loglevel` to watch the console, and photograph
   the screen where it stops. For a log that survives, netconsole sends the kernel log over UDP:
   `netconsole=@/eth0,6666@<receiver-ip>/` on the command line (interface name from a previous
   boot's `ip -br link`), and on another machine `nc -lu 6666 | tee godlike.log`. It starts once
   the network driver loads, so a hang before that only shows on screen.

**If no combination boots reliably, return the board inside the 30 days.** The fallback is an
ASUS X870E (the Crosshair 2006 is the Dark Hero underneath, national warranty).

## The return window: three days of tests

The parts arrive on different days, and Amazon counts each item's window from its own delivery
(check the date under the order): the **board's 30 days start when the board arrives**, whether
or not the CPU is there yet. So the first full test starts the day the **minimum set** is in:
board, CPU, RAM, PSU and cooler. The 9950X3D has an iGPU (out of the USB4 ports only, with a
USB-C → DisplayPort cable) and the ISO boots from a stick, so the 5090 and the SN8100 can come
later. Run it on top of the motherboard box if the case is not there yet.

**Test the whole machine at once.** Whatever has arrived goes in, the RTX 5090 (and the TRYX riser,
if it will be used) included: the windows run in parallel, and the PSU, the VRM and the case's
airflow only show their limits with the CPU and the GPU loaded together. Isolating is for when
something fails: then take parts out in this order and repeat the failing test each time: the
5090 (back to the iGPU), the riser (card straight in PCI_E1), the second NVMe, then RAM one stick
at a time in A2.

**Display on the live ISO: the monitor on the board's USB4 port (iGPU), not on the 5090.** The ISO
has no NVIDIA driver; if its `nouveau` cannot drive Blackwell there is no image, which looks like
a dead board. Once `nvidia-open` is installed (below), the 5090's outputs can be used.

**Tools on the live ISO.** Boot the Arch ISO with `cow_spacesize=8G` on its command line (`e` at
the menu) so pacman has room in RAM, then:

```bash
pacman -Sy stress-ng fio iperf3 smartmontools nvme-cli lm_sensors memtester alsa-utils ethtool iw s-tui
# with the 5090 in: the driver, then modprobe nvidia (blacklist nouveau first if it grabbed the card)
pacman -S nvidia-open nvidia-utils
```

`nvidia-open` is built for the repo's current `linux`: it only loads if the ISO's kernel is the same
version (`uname -r` against `pacman -Si linux`), so use the latest ISO. If `modprobe nvidia`
refuses with a version mismatch, leave the GPU test for the installed system.

y-cruncher and mprime (Prime95) are static binaries: download them beforehand from their sites
onto the second stick (on the installed system they are in the AUR: `y-cruncher`, `mprime`).
Keep `sensors` (or `s-tui`) open in a second TTY during every load test: CPU (Tctl) under 95 °C,
VRM and SN8100 temperatures where the board shows them.

### Day 1 (the evening the minimum set arrives): boots, then RAM overnight

1. Day 1 above: ISO from a rear CPU USB port, `hw-report.sh`, the freeze checklist if needed.
2. 30 min of `stress-ng --cpu 0 --cpu-method all -t 30m --metrics` with `sensors` open: the
   cooler is mounted right (hot spot offset bracket) and the VRM holds.
3. **memtest86+** overnight (`memtest86+-efi`, or the entry on the Arch ISO menu), EXPO on: at
   least 2 full passes of 64 GB. One error = the kit or EXPO, never trust btrfs on it.

### Day 2: CPU, RAM under the OS, storage, ports

- **CPU**, each 1–2 h, one at a time:
  - `y-cruncher` → Stress Test, all tests (AVX-512, memory controller): the one that finds Zen 5
    instability first.
  - `mprime -t` → Small FFTs (heat, VRM), then Blend (RAM).
  - Per core (a weak core passes all-core loads): Small FFTs pinned to one thread at a time,
    `for c in $(seq 0 31); do echo core $c; timeout 300 taskset -c $c ./mprime -t; done`
    (stop at the first "FATAL ERROR"/"Rounding" line and note the core).
- **RAM in the OS:** `memtester 48G 2` (leaves room for the system); `stressapptest -s 3600 -M 48000`
  on the installed system.
- **NVMe**, each drive in each slot it will live in:
  - `lspci -vv -s <addr> | grep LnkSta`: SN8100 in M2_1 must be `32GT/s, Width x4`.
  - `nvme smart-log /dev/nvme0` before and after: `critical_warning 0`, `media_errors 0`.
  - `nvme device-self-test /dev/nvme0 -s 2` (long self-test, minutes), result in
    `nvme self-test-log /dev/nvme0`.
  - Before the install (destroys the data, the drive is new): a full write + verify,
    `fio --name=full --filename=/dev/nvme0n1 --rw=write --bs=1M --iodepth=32 --ioengine=io_uring --direct=1 --verify=crc32c --do_verify=1`,
    then 10 min of sequential write (`--time_based --runtime=600`) watching the temperature in
    `nvme smart-log`: Gen5 drives throttle around 80–85 °C, which is heat, not a defect.
- **USB:** a fast USB SSD in every port, `lsusb -t` shows the negotiated speed (5000M, 10000M,
  20000M, USB4 40G), a 5-minute copy each while `dmesg -w` runs in another TTY: any
  `xhci_hcd`, `reset`, `disconnect` line is the known X870E problem showing up.
- **Network:**
  - `ethtool <if>`: the speed negotiated on each port.
  - `iperf3 -c <nas>` both ways (`-R`), 60 s: ~940 Mbit/s on 1G with 0 retransmits; on the NAS
    run `iperf3 -s` in a container.
  - The 10G port without a 10G partner: cable the 10G (AQC113) and the 5G (RTL8126) ports
    together, put one in a namespace (`ip netns add t; ip link set <if2> netns t`, an address on
    each side) and run iperf3 across: proves both ports at 5G.
  - `ethtool -S <if> | grep -i err` must stay at 0.
  - Wi-Fi and Bluetooth: an iperf3 run over Wi-Fi; pair the AirPods.
- **Audio:**
  - `speaker-test -c 2 -t wav` on the rear and front outputs, the jack detection of the front panel.
  - `alsabat` with a cable from line out to line in (it plays a tone and analyses what came
    back).
  - The output at 32-bit/192 kHz as in `audio/`.
  - Music playing during a y-cruncher run, `pw-top` open: the ERR column must not climb
    (crackles under load are the board's DPC/IRQ problem).

### Day 3: install, the GPU, sleep, everything at once

- **GPU** (the 5090; from day 1 if it was already in, live ISO with `nvidia-open`):
  - Link: `nvidia-smi -q | grep -A3 "Link Width"` and `lspci -vv -s <addr> | grep LnkSta` under
    load (it drops to Gen 1 at idle): **`32GT/s, Width x16`** in PCI_E1. With the TRYX riser the
    same, or the riser is the problem (Kabum, 7-day return); straight in the slot as reference.
  - An hour of a heavy game or benchmark at full power; `journalctl -k | grep -iE "aer|pcie bus error|xid"`
    stays empty (an `Xid` is the card or its power reporting a fault).
  - The 12V-2x6 plug fully seated (no gap at the latch), checked again after the hour.
- **Virtualization** (BIOS: SVM on, IOMMU on): `lsmod | grep kvm_amd`, one VM boots. Linux VMs and
  Docker only; the ToneX moved to the native Windows, no USB passthrough any more.
- **Sleep:** 20 cycles of `sudo rtcwake -m mem -s 30` with the AW3225QF connected; every one must
  wake with image.
- **Everything at once**, 1 h: y-cruncher on the CPU and the game or benchmark on the GPU together
  (~1 kW with the 5090).
  This is the PSU (watch the Ai1300TS on JUSB1, `lsusb | grep 0db0:aa6f`), the VRM and the case's
  airflow at full power.
- `hw-report.sh` at the end, kept with the day-1 report.

After day 3, use the machine normally for the rest of the window with the persistent journal:
a freeze in week three still leaves its previous boot behind for `hw-report.sh`.

### ToneX: native Windows, not a VM

On the old machine the ToneX software ran in a Windows 11 VM with a whole CPU USB controller
passed through (QEMU's emulated xHCI made USB audio unusable). With Windows installed natively
(dual boot) it runs there: no passthrough, no reserved ports, every USB port is the host's. The
trade-off: playing through the ToneX software means booting Windows. The libvirt VM
"Windows 11 IoT LTSC" and its saved XML (backup) are no longer needed on the new machine;
libvirt stays for Linux test VMs.

## Disks and dual boot (plan, decided 2026-11-22)

Linux first, Windows 11 Enterprise (General Availability Channel, activated by the KMS host on the
NAS) second, on the fast disk; the old disk only for games.

**SN8100 2 TB (M2_1), in this order:**

| # | Partition | Size | What |
|---|---|---|---|
| 1 | ESP, shared | 4 GiB | Limine, UKIs, snapshot entries, plus Windows' `\EFI\Microsoft` (~100 MB) |
| 2 | LUKS2 → btrfs | ~1580 GiB | Linux, subvolumes as today (INSTALL.md) |
| 3–5 | MSR, NTFS, WinRE | ~280 GiB left free | Windows Setup creates them in the free space: ~300 GB for Windows, Visual Studio, tools |

Linux used ~240 GB without games on the old machine, so ~1.7 TB leaves room for AI models and
video. Decide the split now: Windows sits after Linux, so growing Linux later means moving the
start of the Windows partition.

One ESP, not two: Windows Setup does not take a second ESP on the same disk without a manual
`dism` + `bcdboot`, and the boot order lives in NVRAM either way. Never run Windows' boot repair
(`bootrec /fixboot`, Startup Repair) without remembering the ESP is shared; `limine-update`
rebuilds the Linux side.

**SN770 1 TB (M2_5): games.** One NTFS partition, unencrypted, shared by both systems:
`UUID=<uuid> /games ntfs3 uid=1000,gid=1000,windows_names,noatime,nofail 0 0`. One Steam
library (`SteamLibrary`) used by both Steams; Proton prefixes (`compatdata`) stay on btrfs (a
symlink), never on NTFS (symlinks, `:` in names). Battle.net games can live there too. Outside
snapper.

**Order of work:**
1. Linux on partitions 1–2, ~280 GiB left unallocated at the end. No ACPI override here (the
   old 5800X3D's core-7 MADT): `apply-system.sh` leaves it out on any other CPU; check
   `nproc` = 32 and no `acpi_override` in `HOOKS=` of `/etc/mkinitcpio.conf`.
2. Secure Boot keys enrolled **with Microsoft's** (`sbctl enroll-keys -m`), or the firmware
   refuses `bootmgfw.efi` when Limine chains to it.
3. Windows Setup into the free space (it finds the ESP itself), from the **business editions**
   ISO (Microsoft 365 admin center / VLSC), edition **Windows 11 Enterprise**. No key during
   Setup. At the sign-in screen: Sign-in options → **Domain join instead** creates a local
   account (Enterprise still offers it; the consumer Pro ISO does not). A Microsoft account can be
   added later.
4. **Activation, on the first desktop**, before anything else (terminal as administrator). The
   GVLK is Microsoft's public KMS client key for Windows 11 Enterprise; the host is the KMS on the
   NAS (its address stays in `~/.config/barch`, not here):
   ```
   slmgr /ipk NPPR9-FWDCX-D2C8J-H872K-2YT43
   slmgr /skms kms.example.com:1688
   slmgr /ato
   slmgr /dlv
   ```
   `/dlv` must show "Windows(R), Enterprise edition", "License Status: Licensed" and the KMS
   machine name. If the board's LAN has no inbox driver, install the chipset/LAN driver first
   (activation needs the network). `0xC004F038` means the host has not reached its client count
   (25 Windows clients): see "Current count" in `slmgr /dlv` on the host. KMS activation lasts 180
   days and renews itself every 7 days while the host is reachable.
5. In Windows: Fast Startup and hibernation **off** (`powercfg /h off`), or the NTFS games disk
   is left dirty and Linux mounts it read-only. No automatic device encryption yet (signing in
   with a Microsoft account turns it on with Microsoft's defaults): BitLocker goes on by hand in
   step 8, once Windows boots through Limine. Never on the games disk.
6. A scheduled task at startup (SYSTEM) keeps Limine first in the UEFI order after updates:
   `bcdedit /set {fwbootmgr} displayorder {<Limine GUID from bcdedit /enum firmware>} /addfirst`.
   Required: every yearly feature update (25H2, 26H2...) tends to put Windows Boot Manager first
   again.
7. Back in Linux: `sudo limine-scan`, pick "Windows Boot Manager" (it writes the `protocol: efi`
   entry by partition GUID). `limine-snapper-sync` already excludes `Windows*` entries.
8. **BitLocker on C:, TPM only** (decided 2026-11-23: like LUKS, the disk opens by itself on this
   machine only; a disk sent back under warranty stays unreadable). Windows has a password on the
   local account and locks on idle and resume, like the Quickshell lock; no autologin.
   1. Before turning it on, `gpedit.msc` → Windows Components → BitLocker Drive Encryption →
      Operating System Drives → **Configure TPM platform validation profile for native UEFI
      firmware configurations: Enabled, PCRs 7 and 11 only**. With our own Secure Boot keys
      BitLocker may otherwise fall back to the legacy profile (PCR 0/2/4), which measures the
      Limine binary, and every Limine update would ask for the recovery key. In the same
      folder, **Choose drive encryption method and cipher strength (Windows 10 [Version 1511]
      and later): Enabled, operating system drives XTS-AES 256-bit**, the same AES-256 as LUKS
      (the default is 128; changing it later means decrypting and encrypting again).
   2. Boot Windows **through Limine** (the path BitLocker seals to), then turn BitLocker on for
      C: (used space only is fine on a new disk). The disk is in 4K logical sectors (INSTALL.md
      step 2), so BitLocker and NTFS work in 4K with Setup's defaults; nothing to choose. `msinfo32` → "PCR7 Configuration" and
      `manage-bde -protectors -get C:` show what it sealed to.
   3. The 48-digit recovery key goes to Bitwarden, not a Microsoft account.
   From then on, **always boot Windows through Limine**, never the firmware's boot menu (F11):
   the other path measures differently and asks for the recovery key.
   **When the PCR 7 changes** (BIOS update, which can also reset the fTPM; Secure Boot keys; a
   db/dbx update from Windows Update): Linux asks the LUKS passphrase once, re-enroll as in
   docs/machine.md; Windows asks the recovery key once, through Limine, and reseals itself on that
   boot (if it asks again: `manage-bde -protectors -disable C:` then `-enable C:`). Before a
   planned BIOS update, `Suspend-BitLocker -MountPoint C: -RebootCount 1` in Windows skips its
   recovery screen: the next Windows boot, whenever it comes, reseals to the new values (the key
   is in the clear on disk until then, so only right before flashing). Never "Clear TPM".
9. Only then the SN770 into M2_5: copy the old `~/Games` off it, wipe it, NTFS at `/games`
   (INSTALL.md step 17). Windows was installed with one disk in, so Setup could not pick the
   wrong one.

**Why Enterprise and not LTSC or IoT:** same controls as LTSC (telemetry off, the whole group
policy set, Windows Update for Business), plus the Store, Xbox app, Game Bar and Gaming Services
for Game Pass and anti-cheat titles, and the yearly scheduler/driver work for new hardware. IoT
Enterprise (non-LTSC) is the same binary but OEM-only and licensed for fixed-purpose devices, with
no KMS key; Enterprise is the volume edition the NAS's KMS activates. To keep Windows from
changing under a game, pin the version: `gpedit.msc` → Windows Update → Manage updates offered
from Windows Update → **Select the target Feature Update version** (`Windows 11`, e.g. `25H2`),
and raise it by hand once a release has settled. After each feature update, re-check the
telemetry and app policies below. Windows Update can also update the Secure Boot db/dbx
(Microsoft's KEK is enrolled): that changes PCR 7, so Linux asks the passphrase once; re-enroll
the TPM (docs/machine.md). Never "Clear TPM" in Windows. A
Microsoft account works (Settings → Accounts → sign in with a Microsoft account) for OneDrive
and settings sync; see step 5 about the encryption it switches on (with BitLocker already on, Windows offers to back up
the recovery key to the account; decline). Anti-cheat games and DLSS 5
are what Windows is there for.

**Telemetry, three layers** (a local account sends the least; a Microsoft account syncs by
design):
1. `gpedit.msc` → Windows Components → Data Collection → **Allow Diagnostic Data: Disabled**.
   Only Enterprise/Education honour "off"; that is why Enterprise and not Pro. Services `DiagTrack` and
   `dmwappushservice` disabled. O&O ShutUp10++ for the rest (reversible).
2. Defender **off** (decided 2026-11-23: no resident scanner taking memory and CPU). Order
   matters, or Windows turns it back on:
   1. Windows Security → Virus & threat protection → Manage settings → **Tamper Protection
      off** (only from this screen; while it is on, the policies below are ignored).
   2. `gpedit.msc` → Windows Components → Microsoft Defender Antivirus → **Turn off Microsoft
      Defender Antivirus: Enabled**, and under Real-time Protection → **Turn off real-time
      protection: Enabled**.
   3. Reboot; `Get-MpComputerStatus` in PowerShell must show `AntivirusEnabled` and
      `RealTimeProtectionEnabled` False. Check again after every feature update.
   What it costs: nothing scans what Windows downloads or runs, and from Windows the shared
   games disk and the ESP are writable. Linux keeps its own guard: root is on LUKS, and Secure
   Boot with our keys refuses any unsigned EFI binary or UKI, so a replaced bootloader or kernel
   stops at boot instead of running (`limine.conf` itself is not hash-enrolled). Keep SmartScreen on and download games only
   through Steam/Battle.net/Xbox. Core isolation (Memory integrity) is a separate switch and the
   one with a measurable cost in games; leave it as the anti-cheats require (some need it on).
3. pfBlockerNG on pfSense with a telemetry-only list (not one that also blocks Windows Update,
   activation or Defender definitions), and DNS forced through pfSense: block outbound 53/853
   from the LAN except to pfSense, Windows' own DNS-over-HTTPS off, no VPN client in Windows.
   It applies to the whole network.

## After the migration (to build with the hardware in)

Decided 2026-11-22, not written yet:

- **PSU telemetry (Ai1300TS, USB `0db0:aa6f` on JUSB1).** A sampler of our own in
  `agent/events.py` reading its hidraw (command `0xE0`, 62-byte reply; boboom66/msi-psu-monitor
  and onlyjco/msi-psu-tool as protocol references, not run as root): input/output power,
  efficiency, temperature, fan, 12 V and the current of each 12V-2x6 pin. A udev rule for the
  hidraw, a rule in `agent/rules.json` for pin imbalance (a contact going bad on the 5090's
  plug), `barch psu`, a chart in the System Center. During the hardware tests a small reviewed
  script is enough to watch the pins through the GPU hour.
- **`windows/` in the repo:** a reviewed PowerShell post-install (the `bcdedit` task, hibernation
  and Fast Startup off, BitLocker PCR policy and status, telemetry policy, Defender off), cloned on the
  Windows side (the repo is public; Windows cannot read the LUKS disk).
- **Windows follows the theme like Linux** (`theme-auto`: light 08:00–18:00, dark otherwise):
  `windows/theme.ps1 [light|dark]` sets `AppsUseLightTheme`/`SystemUsesLightTheme`, broadcasts
  `WM_SETTINGCHANGE`, the accent color and the wallpaper from `palettes.json`, and the Corsair
  K95/Scimitar color through OpenRGB's CLI (no iCUE). Run by a scheduled task (logon, 08:00,
  18:00, resume, unlock), nothing resident. Without OpenRGB the devices fall back to the
  profile saved in their memory from ckb-next.

## Notes from the old machine

`hw-report.sh` run on the 5800X3D (2026-11-15): every pattern at 0 except repeated
`nvidia-drm-crtc.h:371 nv_flip == NULL` warnings from the NVIDIA driver in bursts. That is the
driver, not the board: expect the same on the new machine and do not count it against the Godlike.
