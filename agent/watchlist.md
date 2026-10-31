# Watch list

Open items the `upstream-watch` task checks against each new release. Add a line when something
is waiting on upstream; remove it when it's solved.

- **gamescope: inverse tone mapping (SDR → HDR) nested in Hyprland.** It did not work with
  gamescope 3.17 + Hyprland 0.56 (README, "Games"), so WoW uses the SDR brightness slider.
  Report any gamescope or Hyprland release that mentions nested HDR, `--hdr-itm-enable`,
  color management of nested sessions or the Wayland color-management protocol.
- **nvidia-drm: modeset refused after resume, then a hard hang.** Once in a while, coming back
  from S3, every atomic commit fails with `Failed to initialize semaphore for plane fence` /
  `Failed to apply atomic modeset. Error code: -11` and the next modesets hang the machine
  (no VT switch; 2026-10-28, nvidia-open 615.78.08, linux-cachyos 7.3.0, Hyprland 0.56).
  `hdr-kick.sh` now stops kicking when it sees that error. Report any NVIDIA driver release
  that mentions suspend/resume, plane fences or semaphores with nvidia-drm, and any Hyprland
  or aquamarine release that changes how it handles resume or failed commits.
- **Hyprland: realtime scheduling kills the compositor.** Hyprland 0.57 gains SCHED_RR through
  rtkit and arms `RLIMIT_RTTIME` (200 ms); long NVIDIA modesets (dpms off while locked, resume)
  got it SIGKILLed six times on 2026-10-31, so `HYPRLAND_NO_RT=1` is set in the uwsm env
  (README, "Machine-specific notes"). Report any Hyprland release whose notes mention realtime,
  rtkit, `RLIMIT_RTTIME`, a realtime watchdog or hyprwm/Hyprland#16737 / discussion #16648: the
  variable can go once that is in. Also report changes to `start-hyprland` or `--locked` /
  `--locked-cmd`: the safe-mode restart after a crash denies every lock client (session only
  recoverable from a tty).
