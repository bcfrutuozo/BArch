// Store.qml — the library and what the player remembers about it.
//   catalog: every album of /music with its tracks, read by the pipeline on the NAS (server/music/catalog.py)
//            and fetched once from its API (~/.config/barch/music.json), kept in ~/.cache/barch/player/catalog.json
//            and asked again with ?since=<version> (nothing moves over the wire when nothing changed)
//   files:   played from the NAS share when it is mounted (/mnt/nasfrutuozo/media/music), else streamed from the API
//   state:   likes, play counts, the listening history, playlists (hand-made and smart), volume, shuffle, repeat
//            and the last queue, in ~/.local/state/barch/player/state.json (one JSON, like omaTUNES)
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string home: Quickshell.env("HOME")
    readonly property string confPath: home + "/.config/barch/music.json"
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/barch/player"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/barch/player"
    readonly property string mount: Quickshell.env("BARCH_MUSIC_MOUNT") || "/mnt/nasfrutuozo/media/music"
    property string url: ""
    property string token: ""
    readonly property bool configured: url !== ""
    property bool mounted: false
    property bool mountChecked: false     // nothing is asked for before the share was looked at
    property bool reachable: true
    property bool loading: false
    property string statusText: ""
    property bool statusBad: false
    function say(msg, bad) { statusText = msg; statusBad = !!bad }

    // ---------- the catalog ----------
    property var albums: []          // [{ key, folder, artist, album, date, year, genre, cover, length, discs, added, tracks: [track] }]
    property var tracks: []          // every track: { key, folder, file, title, artist, albumArtist, album, genre, date, year, disc, pos, n, length, rate, bits, lyrics, albumKey }
    property var byKey: ({})         // track key (folder/file) -> track
    property var albumByKey: ({})    // folder -> album
    property var artists: []         // [{ name, albums: [album], tracks, length }]
    property var artistByName: ({})
    property var genres: []          // [{ name, albums: [album], tracks }]
    property int version: 0
    property real scanned: 0
    property bool scanning: false
    readonly property int albumCount: albums.length
    readonly property int trackCount: tracks.length
    readonly property real totalLength: albums.reduce((a, x) => a + x.length, 0)

    function fold(s) { return (s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "") }
    function year(d) { const m = /^(\d{4})/.exec(d || ""); return m ? parseInt(m[1]) : 0 }
    function time(s) {
        s = Math.max(0, Math.floor(s || 0))
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
        return (h > 0 ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(r).padStart(2, "0")
    }
    function hours(s) { s = s || 0; return s >= 3600 ? (s / 3600).toFixed(s >= 36000 ? 0 : 1) + " h" : Math.round(s / 60) + " min" }
    function when(t) { return t ? Qt.formatDateTime(new Date(t * 1000), "dd/MM HH:mm") : "" }
    function sortName(s) { return fold(s).replace(/^(the|a|an|os|as|o|a)\s+/, "") }

    function applyCatalog(d) {
        const albs = [], trs = [], bk = {}, ak = {}, art = {}, gen = {}
        for (const a of d.albums || []) {
            const alb = { key: a.folder, folder: a.folder, artist: a.artist, album: a.album, date: a.date || "", year: year(a.date),
                          genre: a.genre || "", cover: !!a.cover, length: a.length || 0, discs: a.discs || 1, added: a.added || 0, tracks: [] }
            alb.s = fold(alb.artist + " " + alb.album)
            alb.sortKey = sortName(alb.artist) + "\u0001" + String(alb.year).padStart(4, "0") + "\u0001" + fold(alb.album)
            for (const t of a.tracks || []) {
                const tr = { key: a.folder + "/" + t.file, folder: a.folder, file: t.file, title: t.title, artist: t.artist || a.artist,
                             albumArtist: a.artist, album: a.album, genre: alb.genre, date: alb.date, year: alb.year, disc: t.disc || 1,
                             pos: t.pos || 0, n: (alb.discs > 1 ? (t.disc || 1) + "." : "") + String(t.pos || 0).padStart(2, "0"),
                             length: t.length || 0, rate: t.rate || 0, bits: t.bits || 0, lyrics: !!t.lyrics, albumKey: a.folder, error: t.error || "" }
                tr.s = fold(tr.title + " " + tr.artist + " " + alb.album)
                alb.tracks.push(tr); trs.push(tr); bk[tr.key] = tr
            }
            albs.push(alb); ak[alb.key] = alb
            const an = art[alb.artist] || (art[alb.artist] = { name: alb.artist, albums: [], tracks: 0, length: 0, s: fold(alb.artist) })
            an.albums.push(alb); an.tracks += alb.tracks.length; an.length += alb.length
            if (alb.genre) {
                const g = gen[alb.genre] || (gen[alb.genre] = { name: alb.genre, albums: [], tracks: 0 })
                g.albums.push(alb); g.tracks += alb.tracks.length
            }
        }
        albs.sort((a, b) => a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0)
        const arts = Object.values(art).sort((a, b) => sortName(a.name) < sortName(b.name) ? -1 : 1)
        for (const a of arts) a.albums.sort((x, y) => x.year - y.year || (x.album < y.album ? -1 : 1))
        const gens = Object.values(gen).sort((a, b) => b.albums.length - a.albums.length || (a.name < b.name ? -1 : 1))
        const an = {}; for (const a of arts) an[a.name] = a
        byKey = bk; albumByKey = ak; artistByName = an
        albums = albs; tracks = trs; artists = arts; genres = gens
        version = d.version || 0; scanned = d.scanned || 0; scanning = !!d.scanning
    }

    // the cached copy opens the app at once; the API is asked for what changed since
    FileView {
        id: cacheFile
        path: store.cacheDir + "/catalog.json"
        blockLoading: true
        printErrors: false
        onLoaded: { try { const d = JSON.parse(text()); if (d.albums) store.applyCatalog(d) } catch (e) {} }
    }
    FileView {
        path: store.confPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try { const c = JSON.parse(text()); store.url = (c.url || "").replace(/\/$/, ""); store.token = c.token || "" } catch (e) {}
            store.fetchCatalog()
        }
    }
    Process {
        id: fetcher
        property string out: ""
        running: false
        environment: ({ T: store.token })
        command: ["sh", "-c",
            'mkdir -p "$(dirname "$2")" && curl -sS --compressed --max-time 300 -H "X-Barch-Token: $T" -o "$2.tmp" "$1" || exit 3; ' +
            'if jq -e \'.ok == true and .changed == true and (.albums | type == "array")\' "$2.tmp" >/dev/null 2>&1; then mv "$2.tmp" "$2" && cat "$2"; else cat "$2.tmp"; rm -f "$2.tmp"; fi',
            "sh", store.url + "/api/catalog?since=" + store.version, store.cacheDir + "/catalog.json"]
        stdout: StdioCollector { onStreamFinished: fetcher.out = text }
        stderr: StdioCollector { onStreamFinished: fetcher.err = text }
        property string err: ""
        onExited: (code, status) => {
            store.loading = false
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (code !== 0 || !d || !d.ok) {
                store.reachable = false
                if (store.albums.length === 0) store.say("library not reachable at " + store.url + (err.trim() ? " (" + err.trim().split("\n").pop() + ")" : ""), true)
                return
            }
            store.reachable = true
            if (d.changed === false) { store.scanning = !!d.scanning; return }
            store.applyCatalog(d)
            store.say(store.albums.length + " albums, " + store.tracks.length + " tracks")
        }
    }
    function fetchCatalog() {
        if (!configured || fetcher.running) return
        loading = true
        fetcher.command = ["sh", "-c", fetcher.command[2], "sh", url + "/api/catalog?since=" + version, cacheDir + "/catalog.json"]
        fetcher.running = true
    }
    Timer { interval: 300000; running: store.configured; repeat: true; onTriggered: store.fetchCatalog() }   // what the pipeline delivered meanwhile

    // the API, for the small calls (lyrics, refresh)
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
    function api(method, path, cb) {
        if (!configured) { if (cb) cb(null); return }
        run(["curl", "-sS", "--max-time", "60", "-X", method, "-H", "X-Barch-Token: " + token, url + path], (out, err, code) => {
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (cb) cb(code === 0 ? d : null)
        })
    }
    function refreshCatalog(full) {
        api("POST", "/api/catalog/refresh" + (full ? "?full=1" : ""), d => { say(d && d.ok ? "the NAS is reading the library again" : "could not ask the NAS", !(d && d.ok)); scanning = true; retry.start() })
    }
    Timer { id: retry; interval: 20000; onTriggered: store.fetchCatalog() }

    // ---------- the files: the share when mounted, the API otherwise ----------
    Process {
        id: mountCheck
        command: ["sh", "-c", '[ -n "$(ls -A "$1" 2>/dev/null)" ]', "sh", store.mount]
        running: true
        onExited: (code, status) => { store.mounted = code === 0; store.mountChecked = true }
    }
    Timer { interval: 60000; running: true; repeat: true; onTriggered: mountCheck.running = true }
    function enc(s) { return encodeURIComponent(s) }
    function trackUrl(t) {
        if (!t) return ""
        return mounted ? mount + "/" + t.folder + "/" + t.file
                       : url + "/api/catalog/stream?folder=" + enc(t.folder) + "&file=" + enc(t.file)
    }
    function coverUrl(album) {
        if (!album || !album.cover || !mountChecked) return ""
        return mounted ? "file://" + mount + "/" + album.folder + "/cover.jpg"
                       : url + "/api/catalog/cover?folder=" + enc(album.folder) + "&token=" + enc(token)
    }
    function coverOf(t) { return t ? coverUrl(albumByKey[t.albumKey]) : "" }

    // ---------- state ----------
    property var state: ({ likes: {}, plays: {}, history: [], playlists: [], volume: 70, shuffle: false, repeat: "off", queue: [], index: -1, position: 0, lastPlayed: {} })
    property string lastWritten: ""
    FileView {
        id: stateFile
        path: store.stateDir + "/state.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            let text = ""
            try { text = stateFile.text() } catch (e) { return }
            if (text === store.lastWritten || text.trim() === "") return
            try { store.state = Object.assign({}, store.state, JSON.parse(text)) } catch (e) { store.say("state.json cannot be read: " + e, true) }
        }
    }
    Process { command: ["mkdir", "-p", store.stateDir, store.cacheDir + "/lyrics"]; running: true }
    Timer { id: saveTimer; interval: 800; onTriggered: store.saveNow() }
    function save() { saveTimer.restart() }
    Component.onDestruction: if (saveTimer.running) saveNow()     // the window closing with a write pending
    function saveNow() {
        const text = JSON.stringify(state) + "\n"
        lastWritten = text
        stateFile.setText(text)
    }
    function edit(fn) { const s = Object.assign({}, state); fn(s); state = s; save() }

    // likes and plays
    function liked(key) { return !!(state.likes || {})[key] }
    function toggleLike(key) {
        edit(s => { const l = Object.assign({}, s.likes || {}); if (l[key]) delete l[key]; else l[key] = Math.floor(Date.now() / 1000); s.likes = l })
        say(liked(key) ? "liked" : "like removed")
    }
    function plays(key) { return (state.plays || {})[key] || 0 }
    function lastPlayed(key) { return (state.lastPlayed || {})[key] || 0 }
    function countPlay(key) {
        const now = Math.floor(Date.now() / 1000)
        edit(s => {
            const p = Object.assign({}, s.plays || {}); p[key] = (p[key] || 0) + 1; s.plays = p
            const l = Object.assign({}, s.lastPlayed || {}); l[key] = now; s.lastPlayed = l
            s.history = (s.history || []).concat([[now, key]]).slice(-50000)
        })
    }
    readonly property var likedTracks: {
        const l = state.likes || {}
        return Object.keys(l).map(k => byKey[k]).filter(t => t).sort((a, b) => l[b.key] - l[a.key])
    }
    readonly property var recentTracks: {
        const l = state.lastPlayed || {}
        return Object.keys(l).map(k => byKey[k]).filter(t => t).sort((a, b) => l[b.key] - l[a.key]).slice(0, 100)
    }
    readonly property var recentAlbums: albums.slice().sort((a, b) => b.added - a.added).slice(0, 60)

    // playlists: { id, name, tracks: [key], smart: null | rules }
    readonly property var playlists: state.playlists || []
    function playlist(id) { return playlists.filter(p => p.id === id)[0] || null }
    function newPlaylist(name, smart) {
        const id = "p" + Date.now().toString(36)
        edit(s => { s.playlists = (s.playlists || []).concat([{ id: id, name: name || "New playlist", tracks: [], smart: smart || null }]) })
        return id
    }
    function updatePlaylist(id, fn) { edit(s => { s.playlists = (s.playlists || []).map(p => { if (p.id !== id) return p; const c = Object.assign({}, p, { tracks: p.tracks.slice() }); fn(c); return c }) }) }
    function deletePlaylist(id) { edit(s => { s.playlists = (s.playlists || []).filter(p => p.id !== id) }) }
    function addToPlaylist(id, keys) {
        updatePlaylist(id, p => { for (const k of keys) if (!p.tracks.includes(k)) p.tracks.push(k) })
        const p = playlist(id); say(keys.length + (keys.length === 1 ? " track" : " tracks") + " added to " + (p ? p.name : "the playlist"))
    }
    function movePlaylist(from, to) {
        edit(s => { const l = (s.playlists || []).slice(); const [x] = l.splice(from, 1); l.splice(to, 0, x); s.playlists = l })
    }
    function playlistTracks(p) {
        if (!p) return []
        if (p.smart) return smartTracks(p.smart)
        return p.tracks.map(k => byKey[k]).filter(t => t)
    }
    // smart rules: { artist, album, genre, title, yearFrom, yearTo, liked, minPlays, maxPlays, playedDays, notPlayedDays, sort, limit }
    function smartTracks(r) {
        r = r || {}
        const now = Math.floor(Date.now() / 1000)
        const fa = fold(r.artist), fb = fold(r.album), fg = fold(r.genre), ft = fold(r.title)
        let out = tracks.filter(t => {
            if (fa && !fold(t.artist).includes(fa) && !fold(t.albumArtist).includes(fa)) return false
            if (fb && !fold(t.album).includes(fb)) return false
            if (fg && !fold(t.genre).includes(fg)) return false
            if (ft && !fold(t.title).includes(ft)) return false
            if (r.yearFrom && (!t.year || t.year < r.yearFrom)) return false
            if (r.yearTo && (!t.year || t.year > r.yearTo)) return false
            if (r.liked && !liked(t.key)) return false
            if (r.minPlays && plays(t.key) < r.minPlays) return false
            if (r.maxPlays !== undefined && r.maxPlays !== null && r.maxPlays !== "" && plays(t.key) > r.maxPlays) return false
            if (r.playedDays && now - lastPlayed(t.key) > r.playedDays * 86400) return false
            if (r.notPlayedDays && lastPlayed(t.key) && now - lastPlayed(t.key) < r.notPlayedDays * 86400) return false
            return true
        })
        const sorts = {
            title: (a, b) => fold(a.title) < fold(b.title) ? -1 : 1,
            artist: (a, b) => a.sortKey < b.sortKey ? -1 : 1,
            album: (a, b) => (fold(a.album) + a.n) < (fold(b.album) + b.n) ? -1 : 1,
            year: (a, b) => b.year - a.year,
            plays: (a, b) => plays(b.key) - plays(a.key),
            recent: (a, b) => lastPlayed(b.key) - lastPlayed(a.key),
            added: (a, b) => (albumByKey[b.albumKey] || {}).added - (albumByKey[a.albumKey] || {}).added,
            random: null
        }
        const s = r.sort || "artist"
        if (s === "random") { for (let i = out.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); const x = out[i]; out[i] = out[j]; out[j] = x } }
        else if (sorts[s]) out = out.slice().sort(s === "artist" ? (a, b) => (sortName(a.artist) + a.album + a.n) < (sortName(b.artist) + b.album + b.n) ? -1 : 1 : sorts[s])
        if (r.limit) out = out.slice(0, r.limit)
        return out
    }

    // ---------- search ----------
    function search(q) {
        const f = fold(q).trim()
        if (!f) return { albums: [], artists: [], tracks: [] }
        const words = f.split(/\s+/)
        const hit = s => words.every(w => s.includes(w))
        return {
            artists: artists.filter(a => hit(a.s)).slice(0, 30),
            albums: albums.filter(a => hit(a.s)).slice(0, 60),
            tracks: tracks.filter(t => hit(t.s)).slice(0, 300)
        }
    }

    // ---------- statistics: what was listened to, from the history ----------
    function stats(rangeS) {
        const since = rangeS > 0 ? Math.floor(Date.now() / 1000) - rangeS : 0
        const art = {}, alb = {}, gen = {}, trk = {}
        let plays = 0, seconds = 0
        const h = state.history || []
        for (let i = h.length - 1; i >= 0; i--) {
            const [t, key] = h[i]
            if (t < since) break
            const tr = byKey[key]
            if (!tr) continue
            plays++; seconds += tr.length
            const bump = (m, k, label, extra) => { const e = m[k] || (m[k] = Object.assign({ key: k, name: label, plays: 0, seconds: 0 }, extra || {})); e.plays++; e.seconds += tr.length }
            bump(art, tr.albumArtist, tr.albumArtist)
            bump(alb, tr.albumKey, tr.album, { artist: tr.albumArtist })
            if (tr.genre) bump(gen, tr.genre, tr.genre)
            bump(trk, tr.key, tr.title, { artist: tr.artist, album: tr.album })
        }
        const top = m => Object.values(m).sort((a, b) => b.seconds - a.seconds)
        return { plays: plays, seconds: seconds, artists: top(art), albums: top(alb), genres: top(gen), tracks: top(trk) }
    }

    // ---------- navigation (the window listens) ----------
    signal navigate(string page, var arg)
    signal askNewPlaylist(var keys)
    function goPage(p) { navigate(p, null) }
    function goAlbum(key) { navigate("album", key) }
    function goArtist(name) { navigate("artists", name) }
    function goPlaylist(id) { navigate("playlist", id) }
    function newPlaylistWith(keys) { askNewPlaylist(keys || []) }

    function openUrl(u) { if (u) Quickshell.execDetached(["xdg-open", u]) }
    function openFolder(album) { if (album && mounted) Quickshell.execDetached(["xdg-open", mount + "/" + album.folder]) }
}
