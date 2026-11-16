# New machine: validating the AM5 build

The 2026-11 build (Ryzen 9 9950X3D, MSI MEG X870E GODLIKE, 2x32 GB DDR5-6000 CL30, WD_BLACK
SN8100 2 TB, MSI MPG Ai1300TS) replaces the 5800X3D/B550 described in [machine.md](machine.md).
The Godlike came through Amazon Global and **MSI Brasil does not take its RMA**: anything wrong
with it has to show up inside Amazon's 30-day return window. So the order is: prove the board
under Linux from a USB stick first, migrate the system only after that.

Official manuals and datasheets: `~/Documents/Manuais/PC-2026/` (outside the repo).

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
NAS), boot the ISO from a **rear USB port wired to the CPU**.

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

## Week 1: stress everything once

After the install (or from the stick), with a persistent journal so a freeze leaves the previous
boot behind for `hw-report.sh`:

- Memory: memtest86+ overnight, then TestMem5 (anta777) or y-cruncher with EXPO on. btrfs turns
  unstable RAM into checksum errors, so this comes before trusting the disk.
- CPU and VRM: hours of all-core load (y-cruncher, `stress-ng`, the kernel build) while watching
  temperatures.
- Every M.2 slot: read and write the SN8100 and the SN770 in each slot once.
- Every port: each rear USB, the front panel, USB4, 10 GbE, Wi-Fi, Bluetooth, audio; the PSU on
  JUSB1 (`lsusb | grep 0db0:aa6f`).
- PCIe: the GPU in PCI_E1; the second x16 slot once if possible.
- Suspend and resume cycles (the AW3225QF has had wake problems before).
- `hw-report.sh` at the end, kept with the day-1 report: the comparison is the record of what the
  board did inside the return window.

## Notes from the old machine

`hw-report.sh` run on the 5800X3D (2026-11-15): every pattern at 0 except repeated
`nvidia-drm-crtc.h:371 nv_flip == NULL` warnings from the NVIDIA driver in bursts. That is the
driver, not the board: expect the same on the new machine and do not count it against the Godlike.
