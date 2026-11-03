// Store.qml — the music pipeline on the NAS (server/music), through its HTTP API with the URL and
// token `barch music install` left in ~/.config/barch/music.json (the same calls `barch music`
// makes): status, the jobs, one job in full, resolve / retry / reject / undo, scan, Lidarr.
// MusicBrainz is searched from here too (curl, one request at a time) to find a release by hand.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string home: Quickshell.env("HOME")
    readonly property string confPath: home + "/.config/barch/music.json"
    property string url: ""
    property string token: ""
    readonly property bool configured: url !== ""

    property var status: ({ counts: {}, running: "", missing: [] })
    property bool reachable: true
    property var jobs: []                 // summaries, newest first
    property string selected: ""
    property var job: null                // the selected job in full
    property string coverFile: ""         // the selected job's cover, fetched with curl (the token stays out of URLs and logs)
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/barch/music-covers"
    property var mbResults: []
    property bool mbBusy: false
    property string statusText: ""
    property bool statusBad: false
    property int busy: 0

    readonly property var states: ["review", "queued", "working", "done", "failed", "rejected"]
    readonly property int reviewCount: (status.counts || {}).review || 0

    function say(msg, bad) { statusText = msg; statusBad = !!bad }
    function when(t) { return t ? Qt.formatDateTime(new Date(t * 1000), "dd/MM HH:mm") : "" }
    function stateColor(s) { return s === "done" ? Ui.green : s === "review" ? Ui.yellow : s === "failed" ? Ui.red : s === "rejected" ? Ui.overlay : Ui.accent }
    function openUrl(u) { if (u) Quickshell.execDetached(["xdg-open", u]) }

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

    // api("GET", "/api/status", null, d => ...): d is the parsed answer; errors go to the status line
    function api(method, path, body, cb, quiet) {
        if (!configured) { say("no " + confPath + ": run barch music install", true); return }
        const cmd = ["curl", "-sS", "--max-time", "60", "-X", method, "-H", "X-Barch-Token: " + token, "-H", "Content-Type: application/json"]
        if (body !== null && body !== undefined) cmd.push("--data", JSON.stringify(body))
        cmd.push(url + path)
        busy++
        run(cmd, (out, err, code) => {
            busy--
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code !== 0 || !d) {
                reachable = false
                if (!quiet) say("pipeline not reachable at " + url + (err.trim() ? " (" + err.trim().split("\n").pop() + ")" : ""), true)
                return
            }
            reachable = true
            if (!d.ok) { say(d.error || "the pipeline refused", true); return }
            if (cb) cb(d)
        })
    }

    function refresh() {
        api("GET", "/api/status", null, d => status = d, true)
        refreshCovers()
        api("GET", "/api/jobs", null, d => {
            jobs = (d.jobs || []).slice().sort((a, b) => (b.updated || 0) - (a.updated || 0))
            if (!selected) { const r = jobs.filter(j => j.state === "review")[0]; if (r) select(r.id) }
        }, true)
        if (selected) loadJob(selected)
    }
    function select(id) {
        if (id === selected) return
        selected = id; job = null; mbResults = []; coverFile = ""
        if (id) loadJob(id)
    }
    function loadJob(id) {
        api("GET", "/api/jobs/" + id, null, d => {
            if (store.selected !== id) return
            const changed = !store.job || store.job.updated !== d.job.updated
            store.job = d.job
            if (changed) fetchCover(id, d.job.updated)
        }, true)
    }
    function fetchCover(id, stamp) {
        const f = cacheDir + "/" + id + "-" + Math.round(stamp || 0) + ".jpg"
        run(["sh", "-c", 'mkdir -p "$1" && find "$1" -name "$2-*" ! -path "$3" -delete; [ -s "$3" ] || { curl -sSf --max-time 30 -H "X-Barch-Token: $4" -o "$3.$$" "$5" && mv -f "$3.$$" "$3"; } || { rm -f "$3.$$"; exit 1; }',
             "sh", cacheDir, id, f, token, url + "/api/jobs/" + id + "/cover"], (out, err, code) => {
            if (store.selected === id) store.coverFile = code === 0 ? "file://" + f : ""
        })
    }
    Timer {   // the pipeline works on its own (Lidarr, scans): follow it while the window is open
        interval: 8000; running: store.configured; repeat: true
        onTriggered: store.refresh()
    }

    // ---------- actions ----------
    function act(id, action, extra) {
        const body = Object.assign({ action: action }, extra || {})
        say(action + " " + id + "…")
        api("POST", "/api/jobs/" + id, body, d => { say(id + ": " + d.job.state + (action === "resolve" || action === "retry" ? " (queued again)" : "")); refresh() })
    }
    function scan() { say("looking for finished torrents and inbox folders…"); api("POST", "/api/scan", {}, d => { say(d.new + " new album(s) queued"); refresh() }) }
    function lidarr(path, body) { api("POST", "/api/lidarr/" + path, body, d => say(d.result)) }

    // ---------- the library's covers ----------
    property var covers: ({ running: "", queued: 0, entries: [] })
    readonly property int coversToLook: covers.entries.filter(e => e.verdict === "better").length
    function refreshCovers() { api("GET", "/api/covers", null, d => covers = d, true) }
    function checkCovers(artist) { api("POST", "/api/covers/check", { artist: artist }, d => { say(d.result); refreshCovers() }) }
    function coverAct(action, folder) {
        say(action + " " + folder + "…")
        api("POST", "/api/covers/" + action, { folder: folder }, d => { say(d.result); refreshCovers() })
    }
    // one image of the covers check, fetched with curl into the cache: cb("file://...") or cb("")
    function coverImage(folder, which, stamp, cb) {
        const f = cacheDir + "/lib-" + Qt.md5(folder) + "-" + which + "-" + Math.round(stamp || 0) + ".jpg"
        run(["sh", "-c", 'mkdir -p "$1"; [ -s "$2" ] || { curl -sSf --max-time 30 -G -H "X-Barch-Token: $3" --data-urlencode "folder=$4" -d "which=$5" -o "$2.$$" "$6" && mv -f "$2.$$" "$2"; } || { rm -f "$2.$$"; exit 1; }',
             "sh", cacheDir, f, token, folder, which, url + "/api/covers/image"], (out, err, code) => cb(code === 0 ? "file://" + f : ""))
    }
    Timer { interval: 4000; running: store.configured && (store.covers.running !== "" || store.covers.queued > 0); repeat: true; onTriggered: store.refreshCovers() }
    function pickCover(folder, i) { api("POST", "/api/covers/pick", { folder: folder, alt: i }, d => { say(d.result); refreshCovers() }) }

    // Claude on one album's cover (barch music covers ask): folder -> { running, text, bad }
    property var asks: ({})
    function setAsk(folder, v) { const a = Object.assign({}, asks); a[folder] = v; asks = a }
    function askCover(folder, complaint) {
        setAsk(folder, { running: true, text: "Claude is looking at the candidates…", bad: false })
        run([home + "/.local/bin/barch", "--json", "music", "covers", "ask", folder, complaint], (out, err, code) => {
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code === 0 && d && d.ok) setAsk(folder, { running: false, text: d.summary + (d.cost ? "  ($" + d.cost.toFixed(2) + ")" : ""), bad: false, proposed: d.proposed })
            else setAsk(folder, { running: false, text: (err.trim().split("\n").pop() || "Claude did not finish"), bad: true })
            refreshCovers()
        })
    }

    // ---------- MusicBrainz (by hand) ----------
    function mbSearch(artist, album) {
        const q = []
        if (album.trim()) q.push('release:"' + album.replace(/"/g, " ").trim() + '"')
        if (artist.trim()) q.push('artist:"' + artist.replace(/"/g, " ").trim() + '"')
        if (!q.length) return
        mbBusy = true
        run(["curl", "-sS", "--max-time", "30", "-G", "-A", "barch-music-app/1.0 ( https://github.com/bcfrutuozo/BArch )",
             "--data-urlencode", "query=" + q.join(" AND "), "-d", "limit=25", "-d", "fmt=json",
             "https://musicbrainz.org/ws/2/release"], (out, err, code) => {
            mbBusy = false
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (!d) { say("MusicBrainz: " + (err.trim() || "no answer"), true); return }
            mbResults = (d.releases || []).map(r => ({
                mbid: r.id, title: r.title, disambiguation: r.disambiguation || "",
                artist: (r["artist-credit"] || []).map(a => a.name + (a.joinphrase || "")).join(""),
                date: r.date || "", country: r.country || "", tracks: r["track-count"] || 0,
                formats: (r.media || []).map(m => m.format || "?").join(" + "), status: r.status || "",
                group: (r["release-group"] || {})["primary-type"] || "", url: "https://musicbrainz.org/release/" + r.id
            }))
            if (!mbResults.length) say("MusicBrainz: nothing for " + q.join(" AND "))
        })
    }
}
