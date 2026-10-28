---
description: Check after a new kernel (NVIDIA module, dmesg, NTSYNC, BORE)
tools: Read Grep Glob Bash(journalctl *) Bash(dkms status*) Bash(modinfo *) Bash(systemctl status *)
notify: always
---
This is the first boot with a new kernel (context.md has the before/after versions). Check that it
came up right on this machine:

- The NVIDIA module (`nvidia-open-dkms`) was built for this kernel and is loaded; the GPU answers.
- NTSYNC is available (`/dev/ntsync`, module `ntsync`) and the BORE scheduler is active
  (`/proc/sys/kernel/sched_bore` = 1). Both matter for games (Proton) and desktop latency.
- The kernel log of this boot has no new errors compared with the previous boot. Known noise that
  also shows on the previous boot is not news.
- No failed units.

If everything is fine, status `ok` with a one-line summary such as "Kernel 7.3.1: NVIDIA, NTSYNC
and BORE ok, no new errors". If something is wrong, status `alert`, and the report brings the
diagnosis: what failed, the evidence (log lines), the likely cause and the fix to try (for example
`kernel-update -f`, `sudo dkms autoinstall`, or booting the previous kernel from Limine).
