# The desktop apps

The Quickshell apps with their own window (`qs -p <dir>`, closing the window quits the process) and the smaller services next to them. Music, Player, Books, Video, Torrents and Backup Browser have their own pages.

## Hyprland Settings

**Hyprland Settings** (`quickshell/hypr/`, its own Quickshell window: "Hyprland Settings" in the
launcher, `barch hypr [page]`): every config option of the Hyprland version installed, read from
`hyprctl descriptions` (name, description, default, current value, range, enum) and typed with
the Lua stubs Hyprland ships (`/usr/share/hypr/stubs/hl.meta.lua`), so nothing is hardcoded
and a new release shows its new options by itself. Sections in a sidebar, search across all of
them, and each option gets the control its type asks for: switch, slider + field, enum,
color (hex + hue/saturation/lightness/alpha popup), gradient (stops + angle), gaps (one or four
values), vec2, text with the choices the description lists. Every row says where the value
comes from (`conf/look.lua:9`), what Hyprland's default is, whether the bar's theme owns it
(border colors, rounding, background: change those in the palette editor) and has a reset.
More pages: **Monitors** (every field of `hl.monitor` per output, with the modes the output
reports), **Key binds** (everything `hyprctl binds` knows; add binds that run a command or a
Lua dispatcher, with flags and the `Group|Name` description of the shortcut sheet; turn a
bind of the files off with `hl.unbind`), **Animations** (the tree with enabled/speed/curve/style,
the bezier curves drawn, new beziers and springs), **Rules** (window, layer and workspace: the
files' ones read-only with their line, the app's ones editable as match + properties),
**Devices** (`hl.device` per input device), **Startup** (commands at session start, environment,
gestures), **Idle & lock** (`hypridle.conf`: lock, sleep and inhibit commands, the listeners
with their timeouts, presets for lock / screen off / suspend; edited in place, comments kept,
hypridle restarted), **Night light** (`hyprsunset.conf`: the profiles by time of day, no filter /
temperature / gamma, hyprsunset restarted) and **Files** (the Lua files, config errors, the
app's own file).
The hand-written Lua is never edited: what you change goes to `hypr/.config/hypr/settings.json`
(saved with the repo) and `conf/settings.lua`, required by `hyprland.lua`, applies it on top of
the files, so a reload or a fresh install keeps it; a reset removes the entry and the files'
value is back. Options, monitors, animations and devices apply live (`hyprctl eval` into
`BArch.settings.apply`, since the Lua config has no `hyprctl keyword`); binds, rules and
gestures reload Hyprland; environment waits for the next start. `barch hypr get|set|reset|list|status`
does the same from a shell (`barch hypr set general:gaps_out 10`, `barch hypr reset all`), and
the app follows the file while open.

## System Center

**System Center** (`quickshell/center/`, own window: "System Center" in the launcher, `barch center [page]`):
the agent infrastructure and systemd in one place. **Overview** (the bar's health check with a
Check now, failed units, failures in the last day, the latest report of every agent task, the
next timers), **NAS** (what `barch nas status` knows, asked every minute: array, parity check, every
disk with status, temperature and usage, the pools, containers down or with an update, Unraid's unread
warnings, the days left on each certificate, and the `nas.*` metrics over 24 h, 7 d or 30 d; the
sidebar counts its problems in red), **Firewalls** (what `barch fw status` knows about omni and chaos, asked every
minute: WAN latency and loss, interfaces, the IPsec tunnel, the DNSBL check, clients online, what each firewall
blocked by interface, the DHCP leases by network with a filter, and the `fw.*` metrics over time), **Services** (user and system units with state and enabled state, journal, start /
stop / restart / reset-failed / enable / disable; system units go through polkit, so the bar's
agent asks the password), **Timers** (both scopes, next and last run, run the service now),
**Failures** (the logs `barch failure` saved, grouped by unit: view, Investigate with Claude,
delete; **Dismiss** per unit or **Dismiss all** keeps the logs and takes them out of the sidebar's
count, **Delete all** (click twice) removes them; the ignore list `agent/failure-ignore` editable),
**Agent** (ask Claude, each task with
its timer, last result, Run now, the report in a side panel, Continue the session, history of
reports; a report that asks for attention counts in the sidebar until its **Dismiss**, or the
Overview's and this page's **Dismiss all**: the report stays, the task's next run starts clean), **Automation** (the rules of `agent/rules.json` with a switch each, Run now, when
each fired last, and the event log of `barch-events`, see [Automation](agent.md#automation)), **History**
(the machine over time from `metrics.db`: boot time, failures per week, what Claude cost,
temperatures, load, GPU power, network latency, disk, any metric, in 1 h to 30 d ranges; a chart spans
the whole range and its lines stop where the sampling stopped, a night asleep is a hole, not a straight line),
**Snapshots** (the pre/post pairs of the Claude sessions: Status and Undo open a
terminal with the `sudo snapper` command, copy it, resume that session) and **Journal** (this
boot, by priority, unit and regex). Nothing is reimplemented: it runs `systemctl`, `journalctl`
and `barch --json …` and refreshes every 30 s.

## Packages

**Packages** (`quickshell/packages/`, "Packages" in the launcher, `barch packages`): what pacman
knows. **Installed**: explicit, AUR, orphans or everything, with description, size, install date,
details and file list on the right; remove (`pkexec pacman -Rns`, with the list of what would go
first; polkit asks the password), mark as explicit / dependency, install through paru in a
terminal. **Updates & lists**: pending updates (checkupdates and paru -Qua; Update All is the
bar's flow), `.pacnew` files (pacdiff in a terminal) and whether `packages/pacman.txt` and
`aur.txt` match what is explicitly installed, with a button that regenerates them (the
removal does it by itself). **History**: the pacman log, newest first, by action and name.

## Audio Mixer

**Audio Mixer** (`quickshell/mixer/`, "Audio Mixer" in the launcher, `barch mixer`): PipeWire through
`Quickshell.Services.Pipewire`. **Devices**: outputs and inputs with volume, mute, a peak
meter, their format (`s32le 2ch 192000Hz`) and the default. **Apps**: every stream playing or
recording with its own volume and a combo that moves it to another device (`pactl
move-sink-input` with the object serial, which WirePlumber remembers for that app).
**Settings**: the graph rate and a forced sample rate or quantum (`pw-metadata` settings,
live, until PipeWire restarts; the permanent values stay in `audio/`), the Bluetooth codec and
profile of a connected headset, pavucontrol / qpwgraph if installed.

## Clip

**Clip** (`quickshell/clip/`, "Clip" in the launcher, `barch clip [file]`, "Open with" in Thunar, or a video dropped
on the window): a video editor in the spirit of the iPhone's. The frame with a crop rectangle over it (corners
and edges to drag, the inside to move it, a rule-of-thirds grid, the rest dimmed), aspect chips (free, the
original, square, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3), turn left / right and mirror, and a filmstrip of the video
below with a grip at each end to trim and a playhead to scrub (the frame follows; `I`/`O` mark the start and
end at the playhead, arrows step one frame, Shift+arrows one second, `R` turns, `0` resets). Nothing plays
inside the window (no Qt Multimedia here): **Preview** (Space) runs the edit through the same ffmpeg command
the export uses, as fast as the GPU can, piped into an mpv window, so what it shows is what will be saved,
HDR included. **Save** (Ctrl+S) asks for a new file next to the original (`<name>-clip.<ext>`, `-2`, `-3` when
taken) or **Replace original** (the old file goes to the trash, or stays as `<name>.orig.<ext>` where there is no
trash), with a progress bar, speed and the encoder in the footer, Cancel, then Play / Show in folder / Open the
result. `clip.py` next to it is the ffmpeg side, shared with `barch clip export`: `ffprobe` for what the file
is (size as displayed, since a phone's video carries its rotation as a tag and ffmpeg turns it by itself),
frames and the filmstrip as JPEGs in `~/.cache/barch/clip/` (HDR tone mapped for the screen), and the
export: the crop is measured on the frame as displayed (after the file's rotation, the turn and the mirror),
rounded to even numbers; the video is re-encoded with NVENC (H.264 stays H.264, AV1 stays AV1, everything
else becomes HEVC, 10-bit kept 10-bit, the color tags and the HDR10 metadata kept; `libx264`/`libx265`
where there is no NVENC), decoded on the GPU, audio and subtitles copied, the container kept, chapters
dropped. `barch clip info <file>` shows what it sees; `tests/test_clip.py` covers the crop math, the filter
chains, the encoder choice, the probe summary and the progress lines.

## BArch Drop

**BArch Drop** (`agent/drop.py`, `barch-drop.service`, `barch drop`): AirDrop from the iPhone without
AirDrop (the AWDL radio it needs is out of reach of this Intel card). Share → **Send to BArch**, a Shortcut
that posts each item over the LAN (`Get Contents of URL`, form field `file`, the token as
`Authorization: Bearer`), or the page the service serves at `http://<desktop>:8350/` in Safari (any size,
with progress; Add to Home Screen makes it an app). Files land in `~/Downloads/iPhone` (never overwritten:
`name-2.ext`), streamed to disk, with one notification per batch (Open, Show in folder); a text or link
(form field `text`, the second Shortcut **Copy to BArch**) goes to the clipboard, with Open for a link.
`barch drop setup` prints the page's link as a QR code and the Shortcut step by step; the token, port,
folder and allowed networks are in `~/.config/barch/drop.json` (mode 600, made on the first run). The
firewall opens TCP 8350 to this LAN only (`100.100.0.0/24`), and the service checks the address again.

## Applio

**Applio** (`quickshell/applio/`, "Applio" in the launcher, `barch applio`): the voice changer's web interface as a
background server. Open starts it as a user unit (`applio`, port 6969), waits for it to answer (10-20 s the first
time) and opens it in the browser; while it runs a voice icon sits next to the tray (dim and pulsing while it
starts): click opens the page again, right click stops the server (one started by hand with `run-applio.sh` too).
The voice models are in `~/Applications/Applio/logs`; a recording of Super+R lands in `~/Recording`, which the
Batch tab takes as its input folder.
