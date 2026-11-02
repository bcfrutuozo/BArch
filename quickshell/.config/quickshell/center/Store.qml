// Store.qml — what the Center knows and does: systemd units and timers (user and system),
// the failures `barch failure` saved, the agent tasks and their reports, the safety snapshots,
// the bar's health check and the journal. Actions run the same commands `barch` and systemctl
// would; system units go through polkit (the bar's agent asks the password).
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string home: Quickshell.env("HOME")
    readonly property string state: home + "/.local/state/barch"
    readonly property string repo: Quickshell.shellDir + "/../../../.."       // quickshell/.config/quickshell/center → BArch
    readonly property string ignorePath: repo + "/agent/failure-ignore"
    readonly property string barch: home + "/.local/bin/barch"

    // ---------- data ----------
    property var units: ({ user: [], system: [] })          // systemctl list-units
    property var unitFiles: ({ user: {}, system: {} })      // unit -> enabled state
    property var timers: ({ user: [], system: [] })
    property var health: ({})
    property var tasks: []
    property var reports: []                                // every report's meta, newest first
    property var snapshots: []
    property var failures: []                               // [{ path, name, unit, stamp, time, size }]
    property var ignore: []                                 // agent/failure-ignore lines
    property string journal: ""
    property string status: ""
    property bool statusBad: false
    property bool ready: false

    // the text panel (journal of a unit, a failure log, a report)
    property string logTitle: ""
    property string logText: ""
    property string logPath: ""
    property bool logOpen: false

    function say(msg, bad) { status = msg; statusBad = !!bad }
    readonly property var failedNow: units.user.filter(u => u.active === "failed").map(u => ({ scope: "user", unit: u.unit }))
                                     .concat(units.system.filter(u => u.active === "failed").map(u => ({ scope: "system", unit: u.unit })))

    // ---------- running commands ----------
    Component {
        id: procComp
        Process {
            id: p
            property var cb: null
            property string out: ""
            property string err: ""
            stdout: StdioCollector { onStreamFinished: p.out = text }
            stderr: StdioCollector { onStreamFinished: p.err = text }
            onExited: (code, status) => { if (cb) cb(out, err, code); p.destroy() }
        }
    }
    function run(cmd, cb) {
        const p = procComp.createObject(store, { command: cmd, cb: cb })
        p.running = true
        return p
    }
    function json(text, fallback) { try { return JSON.parse(text) } catch (e) { return fallback } }

    // ---------- refresh ----------
    function refreshUnits() {
        for (const scope of ["user", "system"]) {
            const flag = scope === "user" ? ["--user"] : []
            run(["systemctl"].concat(flag, ["list-units", "--type=service", "--all", "-o", "json"]), out => {
                const u = Object.assign({}, units); u[scope] = json(out, []); units = u
            })
            run(["systemctl"].concat(flag, ["list-unit-files", "--type=service,timer", "-o", "json"]), out => {
                const map = {}
                for (const f of json(out, [])) map[f.unit_file] = f.state
                const u = Object.assign({}, unitFiles); u[scope] = map; unitFiles = u
            })
            run(["systemctl"].concat(flag, ["list-timers", "--all", "-o", "json"]), out => {
                const t = Object.assign({}, timers); t[scope] = json(out, []); timers = t
            })
        }
    }
    function refreshHealth(force) {
        run([barch, "--json", "health"].concat(force ? ["--refresh"] : []), (out, err, code) => {
            const h = json(out, null)
            if (h) health = h; else say("health: " + (err.trim() || "the bar is not reachable"), true)
        })
    }
    function refreshAgent() {
        run([barch, "--json", "agent", "list"], out => tasks = json(out, []))
        run(["sh", "-c", 'for f in "$1"/reports/*/2*.json; do [ -r "$f" ] && jq -c . "$f"; done', "sh", state], out => {
            const list = []
            for (const line of out.split("\n")) { const r = json(line, null); if (r) list.push(r) }
            list.sort((a, b) => String(b.time).localeCompare(String(a.time)))
            reports = list
        })
    }
    function refreshSnapshots() { run([barch, "--json", "snapshot", "list"], out => snapshots = json(out, [])) }
    function refreshFailures() {
        run(["sh", "-c", 'find "$1" -maxdepth 1 -name "*.log" -printf "%T@ %s %f\\n" 2>/dev/null | sort -rn', "sh", state + "/failures"], out => {
            const list = []
            for (const line of out.split("\n")) {
                const m = /^(\d+)\.?\d* (\d+) (.+)$/.exec(line)
                if (!m) continue
                const name = m[3]
                const nm = /^(.*)-(\d{8}-\d{6})\.log$/.exec(name)
                list.push({ path: state + "/failures/" + name, name: name, unit: nm ? nm[1] : name, stamp: nm ? nm[2] : "",
                            time: Number(m[1]) * 1000, size: Number(m[2]) })
            }
            failures = list
        })
        ignoreFile.reload()
    }
    function refreshJournal(args) {
        run(["journalctl", "--no-pager", "-o", "short-iso"].concat(args || ["-b", "-p", "warning", "-n", "400"]), (out, err) => journal = out || err)
    }
    function refreshAll() {
        refreshUnits(); refreshHealth(false); refreshAgent(); refreshSnapshots(); refreshFailures()
        ready = true
    }
    Component.onCompleted: refreshAll()
    Timer { interval: 30000; running: true; repeat: true; onTriggered: { store.refreshUnits(); store.refreshFailures() } }

    // ---------- failure-ignore (a file of the repo) ----------
    FileView {
        id: ignoreFile
        path: store.ignorePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: store.ignore = text().split("\n")
    }
    function setIgnore(lines) {
        ignoreFile.setText(lines.join("\n").replace(/\n*$/, "\n"))
        ignore = lines
    }
    readonly property var ignoreGlobs: ignore.filter(l => l.trim() !== "" && !l.startsWith("#"))
    function ignored(unit) {
        return ignoreGlobs.some(g => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$").test(unit))
    }

    // ---------- actions ----------
    function unitAction(scope, action, unit) {
        const flag = scope === "user" ? ["--user"] : []
        say(action + " " + unit + "…")
        run(["systemctl"].concat(flag, [action, unit]), (out, err, code) => {
            say(code === 0 ? action + " " + unit + ": done" : action + " " + unit + ": " + (err.trim() || "failed (" + code + ")"), code !== 0)
            refreshUnits()
        })
    }
    function showJournal(scope, unit, lines) {
        const flag = scope === "user" ? ["--user"] : []
        logTitle = "journal · " + unit + (scope === "user" ? " (user)" : ""); logText = "loading…"; logPath = ""; logOpen = true
        run(["journalctl"].concat(flag, ["-u", unit, "-n", String(lines || 300), "--no-pager", "-o", "short-iso"]), (out, err) => logText = (out || err).trim() || "(empty)")
    }
    function showFile(title, path) {
        logTitle = title; logText = "loading…"; logPath = path; logOpen = true
        run(["cat", path], (out, err) => logText = out || err)
    }
    function terminal(title, cmd) {
        Quickshell.execDetached(["setsid", "-f", "foot", "-T", title, "-e", "sh", "-c", cmd + '; echo; printf "\\n[Enter to close] "; read -r _'])
    }
    function investigate(path) { Quickshell.execDetached([barch, "agent", "investigate", path]); say("Claude is opening the log in a terminal") }
    function continueSession(id) { Quickshell.execDetached([barch, "agent", "continue", id]) }
    function ask(text) { Quickshell.execDetached([barch, "agent", "ask", text]); say("asked Claude in a terminal") }
    function runTask(task) {
        say("running " + task + " (a notification arrives when it ends)…")
        run(["systemctl", "--user", "start", "--no-block", "barch-agent@" + task + ".service"], (out, err, code) => { if (code !== 0) say(err.trim(), true); refreshAgent() })
    }
    function deleteFailure(path) { run(["rm", "-f", path], () => { refreshFailures(); if (logPath === path) logOpen = false }) }
    function deleteFailuresOf(unit) {
        const paths = failures.filter(f => f.unit === unit).map(f => f.path)
        if (paths.length) run(["rm", "-f"].concat(paths), () => { refreshFailures(); logOpen = false })
    }
    function copy(text) { run(["wl-copy", text], () => say("copied: " + text)) }
    function snapperCmd(kind, s) {
        const range = s.pre + ".." + (s.post !== null && s.post !== undefined ? s.post : "")
        return "sudo snapper -c root " + kind + " " + range
    }
    function openPath(path) { Quickshell.execDetached(["sh", "-c", 'exec uwsm app -- foot -e "${EDITOR:-nvim}" -R "$1"', "sh", path]) }
    function pretty(us) {
        if (!us) return "—"
        const d = new Date(us / 1000)
        return Qt.formatDateTime(d, "ddd dd/MM HH:mm")
    }
    function ago(ms) {
        if (!ms) return ""
        const s = Math.max(0, (Date.now() - ms) / 1000)
        if (s < 90) return Math.round(s) + " s ago"
        if (s < 5400) return Math.round(s / 60) + " min ago"
        if (s < 172800) return (s / 3600).toFixed(1).replace(/\.0$/, "") + " h ago"
        return Math.round(s / 86400) + " d ago"
    }
    function stampToDate(stamp) {   // 20261031-083738
        const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/.exec(stamp || "")
        return m ? m[1] + "-" + m[2] + "-" + m[3] + " " + m[4] + ":" + m[5] + ":" + m[6] : stamp
    }
}
