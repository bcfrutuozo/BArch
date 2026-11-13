// Store.qml — the torrent statistics service on the NAS (server/torrents, container barch-torrents)
// through its HTTP API, with the URL and token `barch torrents install` left in
// ~/.config/barch/torrents.json. One range for the whole window; everything is read only.
pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string confPath: Quickshell.env("BARCH_TORRENTS_CONF") || Quickshell.env("HOME") + "/.config/barch/torrents.json"
    property string url: ""
    property string token: ""
    readonly property bool configured: url !== "" && token !== ""

    property bool reachable: true
    property string statusText: ""
    property bool statusBad: false
    property int busy: 0

    // the range every page looks at
    property string range: "30d"
    readonly property var ranges: [
        { value: "24h", label: "24 h" }, { value: "7d", label: "7 d" }, { value: "30d", label: "30 d" },
        { value: "90d", label: "90 d" }, { value: "1y", label: "1 y" }, { value: "all", label: "All" }
    ]
    readonly property string rangeLabel: range === "all" ? "since tracking began" : "in " + (ranges.filter(r => r.value === range)[0] || { label: range }).label

    property var status: ({})
    property var overview: ({})
    property var samples: []
    // the period the charts show (the whole range asked for, however little of it has data yet) and
    // when tracking began, marked on them
    property real axisFrom: NaN
    property real axisTo: NaN
    readonly property real began: status.start || NaN
    readonly property string beganLabel: "tracking began " + day(status.start)
    property var history: ({ kind: "day", buckets: [] })

    // Sources: every category, indexer or tracker, and the history of the one picked
    property string by: "indexer"
    property var groups: []
    property string groupKey: ""
    property bool groupPicked: false
    property var groupHistory: null

    // Torrents: the list (optionally of one source) and the history of the one picked
    property string tBy: ""
    property string tKey: ""
    property string tState: "all"
    property string tSort: "up"
    property string tQuery: ""
    property var torrents: []
    property bool torrentsLoading: false
    property string torrentHash: ""
    property var torrent: null
    property var torrentHistory: null

    signal navigate(string page)

    function say(msg, bad) { statusText = msg; statusBad = !!bad }

    FileView {
        path: store.confPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try { const c = JSON.parse(text()); store.url = (c.url || "").replace(/\/$/, ""); store.token = c.token || "" } catch (e) {}
            store.refresh()
        }
    }

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
    function run(cmd, cb) { const p = procComp.createObject(store, { command: cmd, cb: cb }); p.running = true; return p }

    // api("GET", "/api/status", d => ...): d is the parsed answer; errors go to the status line
    function api(method, path, cb, quiet) {
        if (!configured) { say("no service in " + confPath + ": run barch torrents install", true); return }
        busy++
        run(["curl", "-sS", "--max-time", "30", "-X", method, "-H", "X-Barch-Token: " + token, url + path], (out, err, code) => {
            busy--
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code !== 0 || !d) {
                reachable = false
                if (!quiet) say("the service is not reachable at " + url + (err.trim() ? " (" + err.trim().split("\n").pop() + ")" : ""), true)
                return
            }
            reachable = true
            if (!d.ok) { say(d.error || "the service refused", true); return }
            if (cb) cb(d)
        })
    }
    function qs(o) { return Object.keys(o).filter(k => o[k] !== "" && o[k] !== undefined).map(k => k + "=" + encodeURIComponent(o[k])).join("&") }

    function refresh() {
        api("GET", "/api/status", d => {
            status = d
            if (d.error) say("qBittorrent: " + d.error, true)
            else if (statusBad) say("")
        })
        api("GET", "/api/overview?" + qs({ range: range }), d => overview = d, true)
        api("GET", "/api/samples?" + qs({ range: range }), d => { axisFrom = d.from; axisTo = d.to; samples = d.samples }, true)
        api("GET", "/api/history?" + qs({ range: range }), d => history = d, true)
        loadGroups()
        loadTorrents()
    }
    onRangeChanged: refresh()

    // ---- sources
    function loadGroups() {
        api("GET", "/api/groups?" + qs({ by: by, range: range }), d => {
            if (d.by !== by) return
            groups = d.groups
            if (!groupPicked || !groups.some(g => g.key === groupKey)) { groupKey = groups.length ? groups[0].key : ""; groupPicked = groups.length > 0 }
            loadGroupHistory()
        }, true)
    }
    function setBy(b) { if (b === by) return; by = b; groups = []; groupPicked = false; groupHistory = null; loadGroups() }
    function pickGroup(k) { groupKey = k; groupPicked = true; groupHistory = null; loadGroupHistory() }
    function loadGroupHistory() {
        if (!groupPicked) { groupHistory = null; return }
        const b = by, k = groupKey
        // an empty key is a real group (no indexer known), so it is sent even when empty
        api("GET", "/api/history?range=" + encodeURIComponent(range) + "&by=" + b + "&key=" + encodeURIComponent(k),
            d => { if (b === by && k === groupKey) groupHistory = d }, true)
    }
    function groupName(k) { return k !== "" ? k : by === "indexer" ? "(no indexer)" : by === "category" ? "(no category)" : "(not read yet)" }

    // ---- torrents
    function loadTorrents() {
        torrentsLoading = true
        let path = "/api/torrents?" + qs({ range: range, state: tState, sort: tSort, q: tQuery, limit: 500 })
        if (tBy) path += "&by=" + tBy + "&key=" + encodeURIComponent(tKey)
        api("GET", path, d => { torrentsLoading = false; torrents = d.torrents }, true)
        if (torrentHash) loadTorrent()
    }
    function showTorrentsOf(b, k) { tBy = b; tKey = k; tQuery = ""; loadTorrents(); navigate("torrents") }
    function clearGroupFilter() { tBy = ""; tKey = ""; loadTorrents() }
    function pickTorrent(h) { if (h !== torrentHash) { torrent = null; torrentHistory = null } torrentHash = h; loadTorrent() }
    function loadTorrent() {
        const h = torrentHash
        api("GET", "/api/torrents/" + h + "?" + qs({ range: range }), d => { if (h === torrentHash) { torrent = d.torrent; torrentHistory = d.history } }, true)
    }

    function sampleNow() {
        api("POST", "/api/sample", d => { say("sampling now"); again.restart() })
    }
    Timer { id: again; interval: 2500; onTriggered: store.refresh() }
    Timer { interval: 60000; running: true; repeat: true; onTriggered: store.refresh() }

    // ---- how numbers are written
    function bytes(v) {
        if (v === null || v === undefined) return "—"
        const a = Math.abs(v)
        const u = a >= 1e12 ? ["TB", 1e12] : a >= 1e9 ? ["GB", 1e9] : a >= 1e6 ? ["MB", 1e6] : a >= 1e3 ? ["KB", 1e3] : ["B", 1]
        const x = v / u[1]
        return (u[1] === 1 || Math.abs(x) >= 100 ? Math.round(x) : Math.abs(x) >= 10 ? x.toFixed(1) : x.toFixed(2)) + " " + u[0]
    }
    function rate(v) { return bytes(v) + "/s" }
    function ratio(v) { return v === null || v === undefined ? "—" : v >= 100 ? Math.round(v).toString() : v >= 10 ? v.toFixed(1) : v.toFixed(v < 1 ? 3 : 2) }
    function ratioTint(v) { return v === null || v === undefined ? Ui.overlay : v >= 1 ? Ui.green : Ui.yellow }
    function day(t) { return t ? Qt.formatDateTime(new Date(t * 1000), "dd/MM/yy") : "" }
    function when(t) { return t ? Qt.formatDateTime(new Date(t * 1000), "dd/MM/yy HH:mm") : "" }
    function ago(t) {
        if (!t) return "never"
        const s = Math.max(0, (status.now || Date.now() / 1000) - t)
        return s < 90 ? Math.round(s) + " s ago" : s < 5400 ? Math.round(s / 60) + " min ago" : s < 172800 ? Math.round(s / 3600) + " h ago" : Math.round(s / 86400) + " d ago"
    }
    function span(s) {
        if (!s) return "—"
        return s < 3600 ? Math.round(s / 60) + " min" : s < 172800 ? (s / 3600).toFixed(1) + " h" : Math.round(s / 86400) + " d"
    }
    readonly property var bucketWord: ({ hour: "hour", day: "day", week: "week", month: "month" })
}
