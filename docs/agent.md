# Agent and automation

Claude Code working on this machine by itself, and the event bus that reacts without it.

## Agent

Claude Code works on this machine on its own, read-only unless you are in the session:

- **Failure → agent.** Every service that fails (system or user, through an `OnFailure=` drop-in
  in `service.d/`) is handed to `barch failure`: it saves the status and the journal of the failed
  run to `~/.local/state/barch/failures/` and notifies with **Investigate** (opens Claude in a
  terminal, already reading the log) and **Show log**. Every failure's log is kept, but a unit
  notifies at most once every 30 min; repeats inside that window are counted and the next
  notification says so ("failed (4× since 21:16)"). `agent/failure-ignore` skips units (apps
  launched by uwsm, barch's own). When it was Hyprland that died (uwsm restarts it in place),
  the user services that only lost their compositor (portals, cliphist, hyprsunset) are not
  reported one by one: their logs are saved and, 30 s later, one notification says "Hyprland
  crashed at 10:58" with the list, and its log (`failures/hyprland-<stamp>.log`: coredumps,
  crash report, journal of the session unit) is what **Investigate** opens. When Hyprland exits
  cleanly instead (a logout, a restart after an update), the same services fall with it but nothing
  is notified: their logs are saved already dismissed. So is a failure whose log says `Driver/library
  version mismatch`: the NVIDIA driver was updated and the old module is still loaded (nvidia-cdi-refresh
  fails five times in a row then), which only the reboot fixes. The logs of the last
  day count in the System Center's sidebar and in the Inbox until dismissed (`barch failure dismiss`,
  the names in `failures/.dismissed`; the log stays for the morning and weekly tasks). `vdirsyncer` skips
  its run quietly while iCloud cannot be resolved (VPN switching, link down) instead of failing.
  `barch metrics summary` and the Center's History count **incidents**, not logs: a unit failing again
  within 30 min of its previous failure is the same incident (`failure_incidents` in `events.py`).
- **Safety snapshot.** Every Claude session started in `~/BArch` takes a snapper pre snapshot of
  `/` when it starts and a post one when it ends (hooks in `claude/.claude/settings.json` →
  `barch-agent-snapshot@.service`, which polkit lets you start without a password). The agent is
  told the number. The pre is kept out of snapper's number cleanup until its post exists (a day
  at most, for sessions that never end cleanly). `barch snapshot list` shows the pairs; `sudo snapper -c root status pre..post`
  shows what a session changed outside the repo and `undochange` reverts it. `/home` is not in the
  snapshot (the repo has git); sessions in other folders take none.
- **Scheduled tasks.** `agent/tasks/<task>.md` (prompt + allowed tools) and an optional
  `<task>.sh` that collects the facts, run by `barch-agent@<task>.timer` with `claude -p` in
  `dontAsk` mode: only the listed read-only tools work, and edits are denied. The report goes to
  `~/.local/state/barch/reports/` and a notification with **Open report** and **Continue** (resume
  the session to talk about it).

| Task | When | What |
|---|---|---|
| `aur-review` | every 6 h, and in Update All | Reads the PKGBUILD diff of each pending AUR update (source moved, new install script, downloads run at build time, obfuscation, new committer); heuristic flags plus Claude's verdict, cached per AUR commit |
| `kernel-check` | first login with a new kernel | NVIDIA module built and loaded, NTSYNC, BORE, new kernel errors vs. the previous boot |
| `morning` | weekdays 08:00 | Agenda, updates and Arch news, health, overnight failures, disk |
| `weekly-review` | Sundays 18:00 | Recurring journal errors, failures, snapshots, unsaved BArch changes |
| `upstream-watch` | Mondays 09:30 | Hyprland, Quickshell, gamescope and NVIDIA release notes against this config and `agent/watchlist.md` |
| `barch-audit` | monthly | README, `docs/` and CLAUDE.md vs code, unused scripts, package lists, `user-services.txt`, `SYSTEM_FILES` |

```bash
barch agent list                       # tasks, last result, next run
barch agent run morning                # run one now
barch agent report kernel-check        # last report
barch aur review                       # what Update All shows before paru -Syu
```

Each run uses Claude like a conversation would (a task costs roughly what a short session does).

## Automation

`barch-events.service` (`agent/events.py`) is the desktop's event bus, its memory and its reflexes,
without any AI:

- **Metrics**, every 30 s into `~/.local/state/barch/metrics.db` (SQLite; raw samples for a week,
  hourly averages for a year): CPU and GPU temperature, load and power, every hwmon sensor
  (`temp.<name>`), RAM and zram, the disks (`disk.root.pct`, `disk.home.pct`, free GB), ping and
  VPN latency, whether the VPN is up, AirPods battery per side, the health check's issue count,
  the Claude plan's limits (`claude.session.pct`, `claude.week.pct`, `claude.fable.pct`, every five
  minutes through the bar), and the boot time of every boot (`systemd-analyze`, once per boot). Every five minutes the NAS too
  (`nas.*`, see [NAS](nas.md)): array and fullest pool, hottest disk, disks not OK, containers
  down or with an update, Unraid's unread warnings, its CPU and RAM, and `cert.days`, the days left
  on the certificate closest to expiring, and the firewalls (`fw.<site>.*`, see NAS → Firewalls).
  The **local disks** too (`agent/disk.py`, `barch disk status`): `smartd` only speaks when the SSD fails and
  `btrfs-scrub-report` when the monthly scrub finds errors, so nothing kept the numbers in between.
  `/usr/local/bin/barch-disk-health` (root, `barch-disk-health.timer`, hourly, both in `system/`) dumps
  `smartctl -j` of every disk and `btrfs device stats` and `btrfs scrub status` of every btrfs into
  `~/.local/state/barch/disk/health.json` (no serial numbers), and the daemon turns it into
  `smart.<disk>.temp|wear.pct|spare.pct|media_errors|err_log|unsafe_shutdowns|written_tb` and
  `btrfs.<fs>.errors|scrub.age_d|scrub.errors`, with their history in the Center; the health widget
  shows a red **Disk Health** card with whatever `barch disk status` lists as a problem (SMART failing,
  a critical warning, media errors, spare under 50 %, wear over 90 %, 70 °C, a failed self-test, btrfs
  errors counted, a scrub with errors, aborted, overdue by 45 days or never run, or the dump itself
  missing or older than three hours).
- **Events**, stored and matched as they happen: Hyprland's socket2 (`window.open`,
  `window.close` with class and title, `window.fullscreen`, `window.urgent`, `monitor.added`,
  `monitor.removed`), `vpn.up`, `vpn.down` (the tunnel dropped) and `vpn.off` (turned off: Disconnect, Anonymous Mode off, a voice command; `pia.sh disconnect` leaves the time in `stopped`), both with the tunnel that went away and whether the kill switch is holding the traffic, `anon.on`/`anon.off`, `net.up`/`net.down` (default
  route), `pods.connected`/`pods.disconnected`, `session.locked`/`unlocked`, `failure` (a new
  log from `barch failure`), `boot`, `claude.cost` (every agent task run and voice fallback writes
  a line to `~/.local/state/barch/claude-cost.log`), `music.review` (an album of the NAS music
  pipeline landed in the review queue, polled every 2 min: id, name, problem, `cover_only`),
  `video.foreign` (a movie or episode file of the video pipeline has audio beyond the original language
  and PT-BR, polled every 5 min: title, extra, what the trim does about it), `startup`,
  and the NAS: `nas.down` / `nas.up`, `nas.array` (state), `nas.disk`, `nas.containers`, `nas.alert`
  (Unraid's own warnings and alerts) and `cert.expiring`, each with a one-line `text`; the local disks:
  `disk.smart` (SMART failing, a critical warning, media errors that grew), `disk.selftest`, `btrfs.errors`
  (a counter grew) and `btrfs.scrub` (errors, aborted, or overdue, weekly), each with `text`; and the firewalls
  (`fw.*`, see NAS → Firewalls): `fw.down` / `fw.up`, `fw.auth`, `fw.boot`, `fw.gateway`, `fw.interface`,
  `fw.ipsec`, `fw.dnsbl` and `fw.client` (a device never seen before took a lease).
- **Rules** in `agent/rules.json`: `when` is an event name plus regexes on its fields
  (`{"event": "window.open", "class": "^steam_app_"}`) or a metric with `above`/`below` and a
  `clear` value for hysteresis (`{"metric": "disk.root.pct", "above": 90, "clear": 85}` fires once
  when crossed and re-arms below 85); `do` is a list of shell commands with `{field}` placeholders
  (shell-quoted; the fields also come as `EVENT_*` variables), `notify` a notification, `say` a
  sentence through `barch voice say`, `ask` a notification with a **Run** button instead of acting,
  `cooldown` how long before it may fire again, `critical` and `enabled`. The daemon reloads the
  file when it changes. It ships with: disk above 90 %, CPU above 90 °C, GPU above 85 °C, VPN
  dropped (spoken), network down and back, AirPods below 20 % per side, monitor connected or
  removed, a boot over 60 s, a Claude call over a dollar, the Claude plan at 90 % of its 5-hour window
  or 85 % of the week or of the Fable share and an album of the music pipeline waiting
  only for a cover (`music.review` with `cover_only`: Claude searches the web for it, `barch music
  cover-ask`, in a transient unit so the daemon never waits), a video file with audio in another language
  (`video.foreign`, a notification: the pipeline trims it by itself), the NAS ones (not answering and back,
  array not started, a disk with a problem, a container down, an Unraid alert or warning, array or a
  pool above 85 %, a disk above 50 °C), a certificate about to expire, the local disk ones (SMART
  failing or media errors, a failed self-test, the NVMe over 90 % of its endurance or over 70 °C, btrfs
  error counters growing, a scrub with errors or overdue), the firewall ones (not answering and
  back, key refused, reboot, gateway or interface down and back, the IPsec tunnel down and back, the DNSBL not
  blocking, a device never seen before on any network, the omni IoT network with more than 300 blocked
  connections in five minutes); two disabled ones keep caffeine on
  while a game window is open (Bruno wants notifications while playing, so no DND there).

```bash
barch rules list                              # every rule, enabled or not, when it fired last
barch rules test window.open class=steam_app_1 # which rules would fire (nothing runs)
barch rules test metric disk.root.pct 95
barch rules fire game-opened                  # run a rule's actions now (the Run button)
barch rules disable monitor-added             # flips "enabled" in rules.json
barch events log 30 --filter vpn              # what happened; --since 7d
barch metrics summary                         # boot, failure incidents per week, Claude cost, temperatures now
barch metrics series gpu.temp --since 7d
```

The System Center shows the same: **Automation** (rules with a switch each, Run, the event log)
and **History** (the charts). Rules are plain commands, so a rule can also run a scheduled agent
task (`barch agent run …`) or open Claude on something (`barch agent ask "…"`).
