// Store.qml — the music pipeline on the NAS (server/music), through its HTTP API with the URL and
// token `barch music install` left in ~/.config/barch/music.json (the same calls `barch music`
// makes): status, the jobs, one job in full, resolve / retry / reject / undo, scan, Lidarr.
// MusicBrainz is searched from here too (curl, one request at a time) to find a release by hand.
pragma Singleton
pragma ComponentBehavior: Bound
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
    function copy(t) { if (t) run(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", t], null) }

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
        refreshLibrary()
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
    // the cover Bruno found himself for a job: a file picked with zenity (uploaded with curl, the token
    // in a header) or a URL; the pipeline checks it (square, >= 500 px) and keeps it with the job
    function pickJobCover(id) {
        const start = home + "/Downloads/"
        run(["zenity", "--file-selection", "--title=Cover for " + id, "--file-filter=Images | *.png *.jpg *.jpeg *.webp", "--filename=" + start],
            (out, err, code) => { const f = out.trim(); if (code === 0 && f) uploadJobCover(id, f) })
    }
    function uploadJobCover(id, file) {
        const name = file.split("/").pop()
        const ctype = /\.png$/i.test(file) ? "image/png" : /\.webp$/i.test(file) ? "image/webp" : "image/jpeg"
        say("uploading " + name + "…")
        busy++
        run(["curl", "-sS", "--max-time", "120", "-X", "POST", "-H", "X-Barch-Token: " + token, "-H", "Content-Type: " + ctype,
             "--data-binary", "@" + file, url + "/api/jobs/" + id + "/cover?label=" + encodeURIComponent(name)], (out, err, code) => {
            busy--
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code !== 0 || !d) { say("upload failed" + (err.trim() ? ": " + err.trim().split("\n").pop() : ""), true); return }
            if (!d.ok) { say(d.error || "the pipeline refused the image", true); return }
            say(d.result)
            loadJob(id)
        })
    }
    function clearJobCover(id) { api("POST", "/api/jobs/" + id + "/cover", { url: "" }, d => { say(d.result); loadJob(id) }) }
    function scan() { say("looking for finished torrents and inbox folders…"); api("POST", "/api/scan", {}, d => { say(d.new + " new album(s) queued"); refresh() }) }
    function lidarr(path, body) { api("POST", "/api/lidarr/" + path, body, d => say(d.result)) }

    // ---------- the library's covers ----------
    property var covers: ({ running: "", queued: 0, entries: [] })
    readonly property int coversToLook: covers.entries.filter(e => e.verdict === "better" && !e.applied).length   // waiting for Replace / Keep mine
    // the answer replaces the model only when it changed: a new object every 8 s would rebuild the
    // list, reload every thumbnail and send the scroll back to the top
    function refreshCovers() { api("GET", "/api/covers", null, d => { if (JSON.stringify(d) !== JSON.stringify(covers)) covers = d }, true) }
    readonly property bool coversBusy: covers.running !== "" || (covers.queued || 0) > 0
    property var artists: []              // the artist folders of /music: [{ name, albums }] (the Covers page's list)
    property string coversArtist: ""      // the artist the Covers page shows
    property var albums: []               // that artist's album folders: [{ folder, cover }] (every one, checked or not)
    function loadArtists() { api("GET", "/api/library/artists", null, d => { const a = d.artists || []; if (JSON.stringify(a) !== JSON.stringify(artists)) artists = a }, true) }
    function loadAlbums(artist) {
        if (!artist) { albums = []; return }
        api("GET", "/api/library/albums?artist=" + encodeURIComponent(artist), null, d => {
            const a = d.albums || []
            if (coversArtist === artist && JSON.stringify(a) !== JSON.stringify(albums)) albums = a
        }, true)
    }
    onCoversArtistChanged: loadAlbums(coversArtist)
    // target: an artist folder (every album) or "Artist/Album" (that one)
    function checkCovers(target) { coversArtist = target.split("/")[0]; api("POST", "/api/covers/check", { artist: target }, d => { say(d.result); refreshCovers() }) }
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

    // Claude on a job that stopped for its cover (barch music cover-ask): finds the front on the web
    // and runs the album with it; asks[id] follows it like the covers page does
    function askJobCover(id, hint) {
        setAsk(id, { running: true, text: "Claude is searching the web for the cover…", bad: false })
        run([home + "/.local/bin/barch", "--json", "music", "cover-ask", id, hint || ""], (out, err, code) => {
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code === 0 && d && d.ok) setAsk(id, { running: false, text: d.summary + (d.cost ? "  ($" + d.cost.toFixed(2) + ")" : ""), bad: false, proposed: d.proposed })
            else setAsk(id, { running: false, text: (err.trim().split("\n").pop() || "Claude did not finish"), bad: true })
            refresh()
        })
    }

    // the review albums waiting only on a year-only date (nothing on earth has the day): one decision for all
    readonly property var yearOnly: jobs.filter(j => j.state === "review" && (j.problems || []).length === 1
                                                     && /^no full original release date/.test(j.problems[0]))
    property bool acceptingYear: false
    function acceptYear() {
        if (acceptingYear || !yearOnly.length) return
        acceptingYear = true
        run([home + "/.local/bin/barch", "--json", "music", "accept-year"], (out, err, code) => {
            acceptingYear = false
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code === 0 && d && d.ok) say(d.count + " album(s) queued again with the year as YYYY-01-01")
            else say((err.trim().split("\n").pop() || "accept-year failed"), true)
            refresh()
        })
    }

    // Fix with Agent (barch music fix): Claude takes the job over, resolves it and follows the run
    function fixJob(id, hint) {
        setAsk(id, { running: true, text: "The agent took the album over: researching, resolving, following the run… (minutes)", bad: false })
        run([home + "/.local/bin/barch", "--json", "music", "fix", id, hint || ""], (out, err, code) => {
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code === 0 && d && d.ok) setAsk(id, { running: false, text: d.summary + (d.cost ? "  ($" + d.cost.toFixed(2) + ")" : ""), bad: !d.fixed, proposed: d.fixed })
            else setAsk(id, { running: false, text: (err.trim().split("\n").pop() || "the agent did not finish"), bad: true })
            refresh()
        })
    }

    // ---------- the library tied to MusicBrainz (library.py): progress and the albums to decide ----------
    property var library: ({ counts: {}, albums: 0, current: "", paused: false, decide: [] })
    readonly property int libraryToDecide: (library.decide || []).length
    function refreshLibrary() { api("GET", "/api/library/sweep", null, d => { if (JSON.stringify(d) !== JSON.stringify(library)) library = d }, true) }
    function libraryAct(action, body) { api("POST", "/api/library/" + action, body, d => { say(d.result); refreshLibrary() }) }
    function libraryMbAdd(folder) { run([home + "/.local/bin/barch", "music", "mb-add", folder], (out, err, code) => say((out || err).trim().split("\n")[0], code !== 0)) }

    // ---------- the library's artists tied to Lidarr's MusicBrainz artists (artists.py) ----------
    property var artistsData: ({ counts: {}, artists: [] })
    readonly property var decideStates: ["missing", "suspect"]
    readonly property int artistsToDecide: (artistsData.artists || []).filter(a => decideStates.indexOf(a.state) !== -1).length
    Timer { interval: 60000; running: store.configured; repeat: true; triggeredOnStart: true; onTriggered: store.refreshArtists() }
    function refreshArtists() { api("GET", "/api/artists", null, d => { if (JSON.stringify(d) !== JSON.stringify(artistsData)) artistsData = d }, true) }
    // candidates for a folder (who its albums credit first) or a name typed: cb(d) with { query, tied, candidates }
    function artistCandidates(folder, q, cb) {
        const qs = folder && !q ? "folder=" + encodeURIComponent(folder) : "q=" + encodeURIComponent(q || folder)
        api("GET", "/api/artists/candidates?" + qs, null, cb)
    }
    function artistAct(action, body, cb) {
        say(action + "…")
        api("POST", "/api/artists/" + action, body, d => { say(d.result.split("\n").join(" · ")); refreshArtists(); if (cb) cb(d) })
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
