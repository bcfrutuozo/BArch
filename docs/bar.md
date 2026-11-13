# The bar (Quickshell)

Press **Super+/** for the full, always up-to-date list of shortcuts (Hyprland and Neovim tabs).
The main pieces:

- **Workspaces** with the icons of the apps on each one; **Alt+Tab** with live previews (releasing
  Alt swaps the chosen window into the current one's place; Space only focuses); **Super+Tab** or the
  top-right corner of the main monitor opens the workspace overview (drag windows between workspaces).
- **Launcher** (Super+Space): apps, `w` windows, `c` clipboard with image thumbnails (Super+V),
  `p` git projects, `/` files, `:` emoji, `?` web, `=` calculator, `>` run, `a` Claude (Super+A;
  asks in a new session in `~/BArch`, Shift+Enter continues the last one), `b` wallpapers ([theme.md](theme.md#wallpapers));
  OCR, color picker, QR.
- **Window tools:** minimize (Super+M, comes back to its own workspace), always on top
  (Super+Shift+P), right-click menu on any window preview, swap/resize with Super+Shift/Ctrl+arrows,
  maximize keeping the bar and gaps (Super+Alt+F), kill a frozen app by clicking it (Super+Ctrl+Alt+Del),
  tabbed groups (Super+G groups or ungroups, Super+Alt+Tab cycles the tabs, Super+Alt+1..9 picks one,
  dragged onto the tab bar join), screen zoom around the cursor (Super+Ctrl+scroll, Super+Ctrl+0 resets;
  `hypr/scripts/zoom.sh`, back to 1 at a reload).
  Alt+Tab and Super+Tab reach the remote machine when Parsec's immersive mode is on
  (`hypr/scripts/passthrough.sh`: an X11 window holding the keyboard gets the shortcut instead of
  Hyprland, since Xwayland's grab never reaches the compositor).
- **Control Center:** Light / Dark / Auto, Display (HDR, SDR brightness, side monitor on/off,
  Themes, Wallpaper), Bluetooth, Caffeine, Night Light, Do Not Disturb, Anonymous Mode and VPN Region ([privacy.md](privacy.md)), Game HDR,
  Game HUD (MangoHud), Screenshot, screen Recording (full screen or region).
- **Polkit agent** (`Quickshell.Services.Polkit`, no hyprpolkitagent): the password dialog apps get
  when they ask for privileges (`pkexec`, GNOME Disks, …), in the bar's theme.
- **Own notification server** with history, DND, sounds and app actions; privacy indicator
  (mic, camera, screen sharing); ShadowPlay-style replay (off at login,
  Super+Alt+R turns it on, Alt+F10 saves); **microphone recording** (Super+R starts, Super+R again
  stops: `record/mic.sh`, `pw-record` from the default source into `~/Recording/<date>.wav`, 48 kHz
  mono 24-bit, a pulsing red mic with the time in the bar, click it to stop too; a notification with
  Play / Folder; `barch mic`); weather with rain alerts;
  iCloud agenda in the clock's calendar; quick notes (Super+N); session restore at login.
- **Lock screen** (`quickshell/lock/`, Super+L, idle and login): blurred wallpaper per monitor, clock,
  date and weather, notifications that arrived while away, music playing; follows the theme live
  through `~/.local/state/quickshell/theme.json` and shows the scene chosen for it in
  `wallpaper.json`. It is its own Quickshell process, so it does not
  fall with the bar, and it stays resident: `scripts/lock.sh` starts it at login and every lock
  request (hypridle, Super+L) is just `ipc call lock lock`, so the screen is up as soon as each
  monitor draws a frame instead of after a Quickshell start. The wallpapers it shows are small,
  pre-blurred copies (`<palette>/<scene>/primary-lock.png`, `secondary-lock.png`, made by
  `make_wallpapers.py`), and everything fades in together. It is the only locker: if the
  process dies while locked, `lock.sh` starts it again and locks it again (Hyprland allows a new
  lock to take over), slowing down to one try every 10 s after three quick failures. If it was
  Hyprland that died, `start-hyprland` brings it back in safe mode with the session locked and
  no lock client is accepted (safe mode ignores the config); `lock.sh` logs that and stops: log
  in on a tty and run `uwsm stop`;
  **Super+Ctrl+Alt+L** kills and relaunches it by hand (works while locked, for a red/black or
  frozen screen; while unlocked it is how an edit under `lock/` is applied, since the resident
  process does not watch its files). `qs -p ~/.config/quickshell/lock ipc call lock state` shows
  what it thinks.
  PAM: `/etc/pam.d/barch-lock` (in `system/`; the plain `login` stack until it is installed). It also
  unlocks the GNOME keyring (`pam_gnome_keyring`): with autologin nothing else does, so apps that
  need a secret at startup are held until then with `keyring-wait` (Nextcloud: drop-in in `systemd/`)
  instead of asking for the keyring password at every login.
  To look at it without locking: `lock/preview.sh` (a normal window with its own Shell ID).
- **Claude usage** (`quickshell/claude/`, `barch claude`): the plan's limits as Claude Code's `/usage` shows
  them, read the same way (the OAuth usage endpoint with the login's token in `~/.claude/.credentials.json`;
  `usage.py` never prints the token and never refreshes it, Claude Code does that when it runs). In the bar: the
  five-hour window's percentage next to a robot, yellow from 70 %, red from 90 % (of any limit). Click: each
  limit as a bar with its reset (Session, Week, the top model's weekly share, "Fable" today, with its allowance),
  the plan (Max 5x), where the week went (Claude Code, chats…), extra usage if enabled, and what this machine's
  agents spent today and this week by source (`claude-cost.log`: scheduled tasks, voice fallback, the music,
  books and video agents), with buttons to the Center's History and Agent pages. Every 5 minutes and on open;
  `barch-events` keeps `claude.session.pct`, `claude.week.pct` and `claude.fable.pct` in the metrics and warns at
  90 % of the window, 85 % of the week or of the Fable share (rules `claude-*`).
- **Inbox** (`quickshell/inbox/`, `barch inbox`): what waits for a decision of yours, in one place: the music
  pipeline's review queue (and how many of those wait only on a year-only date, which one button in the
  Music app settles: **Accept the year for N albums**, `barch music accept-year [--dry-run]`), the library
  albums the MusicBrainz sweep could not tie, the video dub jobs in review, the book requests pending a
  pick, the failure logs of the last day, the health check's issues and the agent reports that ask for
  attention (these two until dismissed: a **Dismiss** button next to them, the same state as the System
  Center's). A tray icon with the total, only while there is something; the panel lists each source with
  an **Open** to the right app or Center page. `inbox.sh` asks every source with a timeout every 2 minutes,
  so the NAS asleep only hides its lines (the panel says what was not reachable).
- **System health:** `.pacnew` files, failed services, TPM fallback warning, the daily backup (failed
  or more than two days old), the local disks ([agent.md](agent.md#automation)) and a monthly cleanup. **Automation** (`barch-events`, see [agent.md](agent.md#automation)):
  metrics history, the event log and the rules of `agent/rules.json` (disk full, VPN dropped,
  game opened, monitor plugged…), shown in the System Center.
- **Bluetooth audio** (`audio/`): headsets are output only, AAC first (then SBC-XQ, SBC); the
  headset profile (HFP/HSP, 16 kHz mono) is out of the roles and the automatic switch to it is off,
  so an app opening the microphone (Discord, a call) never degrades the music: the fifine is the
  microphone. The connected device shows its codec in the Bluetooth tile and in the bar's device list.
- **Updates:** pending packages, unread Arch news (also enforced by a pacman hook) and the kernel.
- **Volume on screen** (`audio/VolumeOsd.qml`): a pill near the bottom of every monitor (icon, level,
  percentage) for 1.4 s whenever the default output's volume or mute changes, and "Microphone muted / on"
  for the mic key. It watches PipeWire, not the keys, so the keyboard's roller, a voice command and a
  headset's own buttons show it too; click-through and above fullscreen windows, so it shows in games.
  Not shown while the pointer is on the bar's volume icon or its panel is open, nor for the jump a change
  of default device brings. The bar itself only carries the speaker icon (dim when muted; click for the
  panel with the level, devices, apps and microphone). `position: "center"` and `offset` in the file move it.
- **Smaller widgets:** power menu (Reload Hyprland, Lock, Suspend, Reboot and Shut Down, the last two
  with a second click to confirm); media player in the clock island (MPRIS, shows only while something plays);
  system monitor (CPU, RAM, GPU bars and, apart, download and upload: the physical interfaces summed, VPN tunnel and VMs left out, on a log scale up to the link speed; click for temperatures, VRAM, GPU power and the network speed in MB/s and Mb/s; right-click btop);
  disks (turns yellow/red as one fills; click a mount to open it); virtual machines (libvirt: start,
  console, pause, reboot, shut down); AirPods (`pods/`, from [omarchy-pods](https://github.com/thisisgm/omarchy-pods): battery,
  listening mode; its daemon `librepods`/`librepods-ctl` is built into `~/.local` by `install.sh`
  at the commit pinned there, `PODS_COMMIT`).
