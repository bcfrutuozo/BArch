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
  The ToneX pedal (a USB 2.0 device) goes there with a cable from USB-C to its own connector;
  everything else on the Type-A ports.
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

### Day 3: install, the GPU, the ToneX, sleep, everything at once

- **GPU** (the 5090; from day 1 if it was already in, live ISO with `nvidia-open`):
  - Link: `nvidia-smi -q | grep -A3 "Link Width"` and `lspci -vv -s <addr> | grep LnkSta` under
    load (it drops to Gen 1 at idle): **`32GT/s, Width x16`** in PCI_E1. With the TRYX riser the
    same, or the riser is the problem (Kabum, 7-day return); straight in the slot as reference.
  - An hour of a heavy game or benchmark at full power; `journalctl -k | grep -iE "aer|pcie bus error|xid"`
    stays empty (an `Xid` is the card or its power reporting a fault).
  - The 12V-2x6 plug fully seated (no gap at the latch), checked again after the hour.
- **ToneX passthrough** (BIOS: SVM and IOMMU on). Its own section below.
- **Sleep:** 20 cycles of `sudo rtcwake -m mem -s 30` with the AW3225QF connected; every one must
  wake with image.
- **Everything at once**, 1 h: y-cruncher on the CPU and the game or benchmark on the GPU together
  (~1 kW with the 5090).
  This is the PSU (watch the Ai1300TS on JUSB1, `lsusb | grep 0db0:aa6f`), the VRM and the case's
  airflow at full power.
- `hw-report.sh` at the end, kept with the day-1 report.

After day 3, use the machine normally for the rest of the window with the persistent journal:
a freeze in week three still leaves its previous boot behind for `hw-report.sh`.

### ToneX passthrough on the new board

What has to be true is the same as on the B550 (there the CPU controller `2d:00.3`, IOMMU group 20, went whole to the VM, since QEMU's emulated xHCI made USB audio unusable): a USB controller of the CPU alone
in its IOMMU group, given whole to the VM.

1. Groups: `for d in /sys/kernel/iommu_groups/*/devices/*; do g=${d#*/iommu_groups/}; echo "group ${g%%/*}: $(lspci -nns ${d##*/})"; done | grep -i usb`.
   A USB controller whose group has nothing else is a candidate; the ones under the chipset
   usually share a group.
2. Which ports it owns: only the three CPU Type-C ports (item 12) can belong to it. The CPU has
   two 10G controllers (`1022:15b6`, `1022:15b7`, each with a 480M and a 10G bus, each usually
   alone in its group) plus a USB 2.0-only one (`1022:15b8`). The pedal is USB 2.0, so it rides
   the port's USB 2.0 wires: it must show **under the controller that goes to the VM**, not under
   15b8 or a hub. Plug the pedal into each one and look at
   `readlink -f /sys/bus/usb/devices/*/ | grep -v usb` or `lsusb -t`: the bus of the candidate
   controller. Label those ports: only the pedal goes there.
3. Update the VM's hostdev address (`virsh edit "Windows 11 IoT LTSC"`), start it, play through
   the ToneX software, record a minute.
4. **Ten start/stop cycles of the VM.** Some AMD USB controllers do not come back from the reset
   at VM shutdown: the host must get the pedal back every time, without `dmesg` errors.

## Disks and dual boot (plan, decided 2026-11-22)

Linux first, Windows 11 IoT Enterprise LTSC second, on the fast disk; the old disk only for games.

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
3. Windows Setup into the free space (it finds the ESP itself).
4. In Windows: Fast Startup and hibernation **off** (`powercfg /h off`), or the NTFS games disk
   is left dirty and Linux mounts it read-only. Device encryption / BitLocker **off**: signing in
   with a Microsoft account turns it on, and booting Windows through Limine one time and through
   the firmware menu the next changes the measured boot path, so it would ask for the recovery
   key; never on the games disk.
5. A scheduled task at startup (SYSTEM) keeps Limine first in the UEFI order after updates:
   `bcdedit /set {fwbootmgr} displayorder {<Limine GUID from bcdedit /enum firmware>} /addfirst`.
   LTSC gets no feature updates, so a reset is rarer, but the task stays.
6. Back in Linux: `sudo limine-scan`, pick "Windows Boot Manager" (it writes the `protocol: efi`
   entry by partition GUID). `limine-snapper-sync` already excludes `Windows*` entries.
7. Only then the SN770 into M2_5: copy the old `~/Games` off it, wipe it, NTFS at `/games`
   (INSTALL.md step 17). Windows was installed with one disk in, so Setup could not pick the
   wrong one.

**Windows 11 IoT LTSC notes:** no Store, Xbox app or Game Bar out of the box (`wsreset -i`
brings the Store back; Gaming Services and the Xbox app from there for Game Pass titles). A
Microsoft account works (Settings → Accounts → sign in with a Microsoft account) for OneDrive
and settings sync; see step 4 about the encryption it switches on. Anti-cheat games and DLSS 5
are what Windows is there for.

**Telemetry, three layers** (a local account sends the least; a Microsoft account syncs by
design):
1. `gpedit.msc` → Windows Components → Data Collection → **Allow Diagnostic Data: Disabled**.
   Only Enterprise/Education honour "off"; that is why LTSC. Services `DiagTrack` and
   `dmwappushservice` disabled. O&O ShutUp10++ for the rest (reversible).
2. Defender kept on with exclusions for `D:\` (the games disk) and the Visual Studio folders,
   cloud protection and sample submission off. Fully disabling it leaves the shared games disk
   and the shared ESP exposed to whatever runs in Windows.
3. pfBlockerNG on pfSense with a telemetry-only list (not one that also blocks Windows Update,
   activation or Defender definitions), and DNS forced through pfSense: block outbound 53/853
   from the LAN except to pfSense, Windows' own DNS-over-HTTPS off, no VPN client in Windows.
   It applies to the whole network.

## Notes from the old machine

`hw-report.sh` run on the 5800X3D (2026-11-15): every pattern at 0 except repeated
`nvidia-drm-crtc.h:371 nv_flip == NULL` warnings from the NVIDIA driver in bursts. That is the
driver, not the board: expect the same on the new machine and do not count it against the Godlike.
