// Store.qml — Radarr, Sonarr and the PT-BR pipeline (server/video) through video.py, next to this file
// (the same keys `barch video` uses, ~/.config/barch/video.json): search and add, the library with the
// checklist of every file, interactive releases, the download queue, the dub jobs.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string script: Quickshell.shellDir + "/video.py"

    property var status: ({ movies: 0, movies_with_file: 0, series: 0, queue: 0, pipeline: { counts: {} }, free_gb: 0 })
    property bool reachable: true
    property string statusText: ""
    property bool statusBad: false
    property int busy: 0

    // Search
    property string kind: "movie"         // movie | series
    property string query: ""
    property var results: []
    property bool searching: false
    property var adding: ({})             // "<kind>:<id>" -> true while it is being added

    // Library
    property var movies: []
    property var series: []
    property bool moviesLoading: false
    property bool seriesLoading: false
    property var movie: null              // the movie on the right (video.py movie)
    property var show: null               // the series on the right (video.py show)
    property bool detailLoading: false

    // Releases (one target at a time: a movie, a season, an episode)
    property var relTarget: null          // { kind, id, season, episode, label }
    property var releases: []
    property bool releasesLoading: false
    property int grabbing: -1

    // Queue and dub
    property var queue: []
    property var dubs: []
    property var dub: null                // the job on the right (dub-show)

    readonly property int dubReview: ((status.pipeline || {}).counts || {}).review || 0

    // a page asks the window to show another page (and what to open there)
    signal navigate(string page)

    function say(msg, bad) { statusText = msg; statusBad = !!bad }
    function openUrl(u) { if (u) Quickshell.execDetached(["xdg-open", u]) }

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

    // video(["movies"], d => ...): d is the parsed answer when ok; errors go to the status line
    function video(args, cb, quiet, fail) {
        busy++
        run(["python3", "-I", script].concat(args), (out, err, code) => {
            busy--
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (!d) { say("video.py: " + (err.trim().split("\n").pop() || "no answer"), true); if (fail) fail(""); return }
            if (!d.ok) {
                if (/not reachable/.test(d.error || "")) reachable = false
                if (!quiet) say(d.error || "refused", true)
                if (fail) fail(d.error || "")
                return
            }
            reachable = true
            if (cb) cb(d)
        })
    }

    function refresh() {
        video(["status"], d => status = d, true)
        loadQueue(); loadDubs()
    }

    // ---- search / add
    function search(q, k) {
        query = q.trim(); if (k) kind = k
        if (!query) return
        searching = true; results = []
        video(["search", query, "--kind", kind], d => {
            searching = false
            results = d.results
            say(results.length + (kind === "movie" ? " movies" : " series") + " for “" + query + "”")
        }, false, () => searching = false)
    }
    function add(item, profile) {
        const key = item.kind + ":" + item.id
        const a = Object.assign({}, adding); a[key] = true; adding = a
        const done = () => { const b = Object.assign({}, store.adding); delete b[key]; store.adding = b }
        say("adding " + item.title + (profile === "auto" ? ": looking at the 4K releases first (up to a few minutes)…" : "…"))
        video(["add", item.kind, String(item.id), "--profile", profile], d => {
            done()
            say(d.title + " added with " + d.profile + " (" + d.why + "), searching")
            results = results.map(r => r.kind === item.kind && r.id === item.id ? Object.assign({}, r, { library_id: d.id }) : r)
            if (item.kind === "movie") loadMovies(); else loadSeries()
        }, false, done)
    }

    // ---- library
    function loadMovies() {
        moviesLoading = true
        video(["movies"], d => { moviesLoading = false; movies = d.movies }, false, () => moviesLoading = false)
    }
    function loadSeries() {
        seriesLoading = true
        video(["series"], d => { seriesLoading = false; series = d.series }, false, () => seriesLoading = false)
    }
    function openMovie(id) {
        if (!movie || movie.id !== id) { movie = null; clearReleases() }
        detailLoading = true
        video(["movie", String(id)], d => { detailLoading = false; movie = d.movie }, false, () => detailLoading = false)
    }
    function openShow(id) {
        if (!show || show.id !== id) { show = null; clearReleases() }
        detailLoading = true
        video(["show", String(id)], d => { detailLoading = false; show = d.series }, false, () => detailLoading = false)
    }
    function setProfile(k, id, p) {
        video(["profile", k, String(id), p], d => {
            say("profile: " + d.profile)
            if (k === "movie") { openMovie(id); loadMovies() } else { openShow(id); loadSeries() }
        })
    }
    function searchNow(t) {
        const args = ["search-now", t.kind, String(t.id)]
        if (t.season) args.push("--season", String(t.season))
        video(args, d => say((t.label || "") + ": " + d.command + " sent"))
    }

    // ---- releases
    function clearReleases() { relTarget = null; releases = []; releasesLoading = false }
    function targetArgs(t) {
        const a = [t.kind, String(t.id)]
        if (t.season) a.push("--season", String(t.season))
        if (t.episode) a.push("--episode", String(t.episode))
        return a
    }
    function findReleases(t) {
        relTarget = t; releases = []; releasesLoading = true
        say((t.label || "") + ": asking the indexers (up to a few minutes)…")
        video(["releases"].concat(targetArgs(t)), d => {
            if (relTarget !== t) return
            releasesLoading = false; releases = d.releases
            say((t.label || "") + ": " + d.releases.length + " releases, " + d.accepted + " fit the profile")
        }, false, () => releasesLoading = false)
    }
    function grab(n) {
        const t = relTarget
        if (!t || grabbing >= 0) return
        grabbing = n
        video(["grab"].concat(targetArgs(t), ["--pick", String(n)]), d => {
            grabbing = -1
            say("downloading: " + d.grabbed)
            loadQueue()
        }, false, () => grabbing = -1)
    }

    // ---- queue
    function loadQueue() { video(["queue"], d => queue = d.items, true) }
    function remove(item, blocklist, research) {
        const args = ["remove", item.app, item.ids.join(",")]
        if (blocklist) args.push("--blocklist")
        if (research) args.push("--search")
        video(args, d => { say("removed: " + (item.release || item.what) + (blocklist ? " (blocklisted)" : "")); loadQueue() })
    }

    // ---- dub
    function loadDubs() { video(["dub"], d => dubs = d.jobs, true) }
    function openDub(id) { video(["dub-show", id], d => dub = d.job) }
    function dubAct(id, action, guid) {
        const args = ["dub-act", id, action]
        if (guid) args.push("--guid", guid)
        video(args, d => { say(id + ": " + action + " sent"); loadDubs(); openDub(id) })
    }

    // the queue moves: every 5 s while something downloads, every 30 s otherwise
    readonly property bool downloading: queue.some(q => q.state === "downloading" && q.progress < 100)
    Timer { interval: store.downloading ? 5000 : 30000; running: true; repeat: true; onTriggered: store.refresh() }
    Component.onCompleted: { refresh(); loadMovies(); loadSeries() }

    // little helpers for the pages
    function gb(x) { return x >= 100 ? Math.round(x) + " GB" : (x || 0).toFixed(1) + " GB" }
    function dubTint(s) {
        return s === "done" ? Ui.green : s === "review" ? Ui.yellow : s === "skipped" ? Ui.overlay
             : s === "downloading" || s === "aligning" ? Ui.accent : s === "" ? Ui.overlay : Ui.subtext
    }
}
