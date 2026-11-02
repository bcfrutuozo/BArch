// Store.qml — the restic repository `barch backup` writes to: status of the last run, the
// snapshots, the files inside each one (listed on demand) and restores into ~/Restore.
// Same repository, password file and cache as barch (bin/barch: BACKUP_*); never deletes anything.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string home: Quickshell.env("HOME")
    readonly property string confPath: home + "/.config/barch/backup.conf"
    readonly property string passPath: home + "/.config/barch/backup/password"
    readonly property string statePath: home + "/.local/state/barch/backup/last.json"
    readonly property string defaultRepo: "/mnt/nasfrutuozo/organization/desktops/bcfrutuozo/restic"
    readonly property string restoreDir: home + "/Restore"
    readonly property string barch: home + "/.local/bin/barch"

    property string repo: defaultRepo
    property var last: ({})
    property string nextRun: ""
    property bool configured: false
    property var snapshots: []           // restic snapshots --json, newest first
    property var stats: ({})             // id -> { total_size, total_file_count }
    property var children: ({})          // snapshot id + "\u0001" + dir path -> [entries]
    property var findResults: []
    property string status: ""
    property bool statusBad: false
    property int busy: 0                 // restic processes running
    property bool ready: false

    // restore
    property bool restoring: false
    property string restoreLog: ""
    property string restoreTarget: ""

    function say(msg, bad) { status = msg; statusBad = !!bad }
    function json(t, f) { try { return JSON.parse(t) } catch (e) { return f } }
    function short(id) { return String(id).slice(0, 8) }
    function human(bytes) {
        const u = ["B", "kB", "MB", "GB", "TB"]
        let i = 0, n = Number(bytes) || 0
        while (n >= 1000 && i < u.length - 1) { n /= 1000; i++ }
        return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + " " + u[i]
    }
    function when(iso) { return String(iso).slice(0, 16).replace("T", " ") }
    function ago(ms) {
        const s = Math.max(0, (Date.now() - ms) / 1000)
        if (s < 5400) return Math.round(s / 60) + " min ago"
        if (s < 172800) return (s / 3600).toFixed(1).replace(/\.0$/, "") + " h ago"
        return Math.round(s / 86400) + " d ago"
    }

    // ---------- processes ----------
    Component {
        id: procComp
        Process {
            id: p
            property var cb: null
            property var onLine: null
            property string out: ""
            property string err: ""
            stdout: StdioCollector { onStreamFinished: p.out = text }
            stderr: StdioCollector { onStreamFinished: p.err = text }
            onExited: (code, status) => { if (cb) cb(out, err, code); p.destroy() }
        }
    }
    function run(cmd, cb) { const p = procComp.createObject(store, { command: cmd, cb: cb }); p.running = true; return p }
    function restic(args, cb) {
        busy++
        const cmd = ["env", "RESTIC_REPOSITORY=" + repo, "RESTIC_PASSWORD_FILE=" + passPath, "RESTIC_CACHE_DIR=" + home + "/.cache/restic", "restic"].concat(args)
        return run(cmd, (out, err, code) => { busy = Math.max(0, busy - 1); if (code !== 0 && err.trim()) say("restic " + args[0] + ": " + err.trim().split("\n").pop(), true); cb(out, err, code) })
    }

    // ---------- status ----------
    function refreshStatus() {
        run(["sh", "-c", 'f="$1"; [ -r "$f" ] && . "$f"; printf "%s\\n" "${BACKUP_REPO:-}"; [ -s "$2" ] && echo configured; cat "$3" 2>/dev/null; echo; systemctl --user show barch-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null',
             "sh", confPath, passPath, statePath], out => {
            const lines = out.split("\n")
            repo = lines[0].trim() || defaultRepo
            let i = 1
            configured = lines[i] === "configured"; if (configured) i++
            const rest = lines.slice(i).join("\n")
            const m = /(\{[\s\S]*\})\s*\n?([^\n]*)\s*$/.exec(rest)
            last = m ? json(m[1], {}) : {}
            nextRun = m ? m[2].trim() : rest.trim()
        })
    }
    function refreshSnapshots() {
        restic(["snapshots", "--json"], (out, err, code) => {
            const list = json(out, [])
            list.sort((a, b) => String(b.time).localeCompare(String(a.time)))
            snapshots = list
            ready = true
        })
    }
    function refreshAll() { refreshStatus(); refreshSnapshots() }
    Component.onCompleted: refreshAll()

    function loadStats(id) {
        if (stats[id]) return
        restic(["stats", id, "--json"], out => { const s = json(out, null); if (s) { const m = Object.assign({}, stats); m[id] = s; stats = m } })
    }

    // ---------- browsing ----------
    function key(id, path) { return id + "\u0001" + path }
    function loaded(id, path) { return key(id, path) in children }
    function loadDir(id, path) {
        const k = key(id, path)
        if (k in children) return
        const m = Object.assign({}, children); m[k] = null; children = m      // loading
        restic(["ls", id, path, "--json"], out => {
            const list = []
            for (const line of out.split("\n")) {
                const n = json(line, null)
                if (!n || n.struct_type !== "node" && n.message_type !== "node") continue
                if (n.path === path) continue
                list.push({ name: n.name, path: n.path, type: n.type, size: n.size || 0, mtime: n.mtime || "" })
            }
            list.sort((a, b) => (a.type === "dir" ? 0 : 1) - (b.type === "dir" ? 0 : 1) || a.name.localeCompare(b.name))
            const m2 = Object.assign({}, children); m2[k] = list; children = m2
        })
    }
    function find(id, pattern) {
        if (!pattern.trim()) { findResults = []; return }
        restic(["find", "--snapshot", id, "--json", pattern], out => {
            const res = json(out, [])
            const list = []
            for (const r of res) for (const m of r.matches || []) list.push({ name: m.path.split("/").pop(), path: m.path, type: m.type, size: m.size || 0, mtime: m.mtime || "" })
            findResults = list
        })
    }

    // ---------- restore ----------
    function restore(id, paths) {
        if (!paths.length || restoring) return
        const stamp = Qt.formatDateTime(new Date(), "yyyyMMdd-HHmm")
        restoreTarget = restoreDir + "/" + short(id) + "-" + stamp
        restoring = true
        restoreLog = "restic restore " + short(id) + " → " + restoreTarget + "\n" + paths.map(p => "  " + p).join("\n") + "\n\n"
        const args = ["restore", id, "--target", restoreTarget, "--verbose"]
        for (const p of paths) args.push("--include", p)
        restic(args, (out, err, code) => {
            restoring = false
            restoreLog += out + (err ? "\n" + err : "") + "\n" + (code === 0 ? "done: " + restoreTarget : "FAILED (exit " + code + ")")
            say(code === 0 ? "restored into " + restoreTarget : "restore failed", code !== 0)
        })
    }
    function openTarget() { if (restoreTarget) Quickshell.execDetached(["xdg-open", restoreTarget]) }
    function runBackup() {
        Quickshell.execDetached(["setsid", "-f", "foot", "-T", "barch backup run", "-e", "sh", "-c", barch + ' backup run; echo; printf "\\n[Enter to close] "; read -r _'])
        say("backup running in a terminal; refresh when it ends")
    }
    function terminal(title, cmd) {
        Quickshell.execDetached(["setsid", "-f", "foot", "-T", title, "-e", "sh", "-c", cmd + '; echo; printf "\\n[Enter to close] "; read -r _'])
    }
}
