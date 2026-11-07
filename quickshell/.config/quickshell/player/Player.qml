// Player.qml — playback: an mpv started by the app (mpv.sh: audio only, idle, no config of its own), driven
// over its JSON IPC socket. mpv holds the queue (its playlist: gapless, prev/next), this mirrors it from the
// `playlist` property it observes; shuffle and repeat are mpv's playlist order and loop modes. MPRIS comes
// from mpv-mpris when it is installed (mpv.sh loads it), so the bar's media island and playerctl see it.
// A play is counted (Store.countPlay) once a track passes half its length or four minutes.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: pl

    readonly property string sock: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/barch-player.sock"
    property bool ready: false
    property bool mpris: false
    property var queue: []           // track keys, in mpv's playlist order
    property int index: -1
    property bool paused: true
    property bool idle: true
    property real position: 0
    property real duration: 0
    property real volume: 70
    property bool muted: false
    property bool shuffle: false
    property string repeat: "off"    // off | all | one
    property var originalOrder: []   // the queue before shuffle, to put it back
    readonly property var current: index >= 0 && index < queue.length ? (Store.byKey[queue[index]] || null) : null
    readonly property bool hasTrack: current !== null && !idle
    readonly property bool playing: hasTrack && !paused
    readonly property string currentKey: current ? current.key : ""
    property var urlToKey: ({})
    property bool counted: false
    property string restoreKey: ""

    // ---------- mpv ----------
    Process {
        id: mpv
        command: [Quickshell.shellDir + "/mpv.sh", pl.sock]
        running: false
        onExited: (code, status) => { pl.ready = false; ipc.connected = false; relaunch.start() }
    }
    Timer { id: relaunch; interval: 2000; onTriggered: pl.start() }
    Timer { id: connectTimer; interval: 300; repeat: true; running: false; onTriggered: { if (!ipc.connected) ipc.connected = true } }
    Socket {
        id: ipc
        path: pl.sock
        connected: false
        parser: SplitParser { onRead: line => pl.handle(line) }
        onConnectedChanged: {
            if (connected) { connectTimer.stop(); pl.hello() }
            else if (mpv.running) connectTimer.start()
        }
    }
    function start() {
        if (mpv.running) return
        mpv.running = true
        connectTimer.start()
    }
    Component.onCompleted: start()

    property int reqId: 1
    property var pending: ({})
    function send(cmd, cb) {
        if (!ipc.connected) return
        const id = reqId++
        if (cb) pending[id] = cb
        ipc.write(JSON.stringify({ command: cmd, request_id: id }) + "\n")
    }
    function set(prop, value) { send(["set_property", prop, value]) }

    function hello() {
        const props = ["playlist", "playlist-pos", "pause", "time-pos", "duration", "volume", "mute", "idle-active", "loop-playlist", "loop-file"]
        props.forEach((p, i) => send(["observe_property", i + 1, p]))
        if (Store.token) set("http-header-fields", ["X-Barch-Token: " + Store.token])
        volume = Store.state.volume !== undefined ? Store.state.volume : 70
        set("volume", volume)
        setRepeat(Store.state.repeat || "off", true)
        shuffle = !!Store.state.shuffle
        send(["get_property", "property-list"], d => { pl.mpris = Array.isArray(d) && d.some(p => p === "user-data") && true })
        send(["script-binding", "ignore"], null)   // nothing: just proves the channel is two-way
        ready = true
        restoreQueue()
    }
    // the queue of the last session, paused where it was
    function restoreQueue() {
        const keys = (Store.state.queue || []).filter(k => Store.byKey[k])
        if (!keys.length || queue.length) return
        const idx = Math.max(0, Math.min(keys.length - 1, Store.state.index || 0))
        set("pause", true)
        send(["stop"]); send(["playlist-clear"])
        keys.forEach((k, i) => {
            const u = url(k)
            send(i === idx && Store.state.position > 5 ? ["loadfile", u, "append", -1, "start=" + Math.floor(Store.state.position)] : ["loadfile", u, "append"])
        })
        send(["playlist-play-index", idx])
        restoreKey = keys[idx]
    }

    function url(key) {
        const u = Store.trackUrl(Store.byKey[key])
        const m = Object.assign({}, urlToKey); m[u] = key; urlToKey = m
        return u
    }
    function handle(line) {
        let m = null
        try { m = JSON.parse(line) } catch (e) { return }
        if (m.request_id !== undefined && pending[m.request_id]) { const cb = pending[m.request_id]; delete pending[m.request_id]; cb(m.data, m.error); return }
        if (m.event !== "property-change") {
            if (m.event === "file-loaded") counted = false
            return
        }
        const d = m.data
        switch (m.name) {
        case "playlist": {
            const q = [], map = urlToKey
            let idx = -1
            ;(d || []).forEach((e, i) => { q.push(map[e.filename] || e.filename); if (e.current) idx = i })
            queue = q; index = idx
            saveQueue.restart()
            break
        }
        case "playlist-pos": index = d === undefined || d === null ? -1 : d; counted = false; saveQueue.restart(); break
        case "pause": paused = !!d; saveQueue.restart(); break
        case "time-pos":
            position = d || 0
            if (!counted && duration > 0 && current && position >= Math.min(duration / 2, 240)) { counted = true; Store.countPlay(current.key) }
            break
        case "duration": duration = d || 0; break
        case "volume": if (d !== undefined && d !== null) volume = d; break
        case "mute": muted = !!d; break
        case "idle-active": idle = !!d; if (idle) { position = 0; duration = 0 }; break
        case "loop-playlist": if (d === "inf" || d === true) repeat = "all"; else if (repeat === "all") repeat = "off"; break
        case "loop-file": if (d === "inf" || d === true) repeat = "one"; else if (repeat === "one") repeat = "off"; break
        }
    }
    Timer {
        id: saveQueue
        interval: 1500
        onTriggered: Store.edit(s => { s.queue = pl.queue; s.index = pl.index; s.position = Math.floor(pl.position) })
    }
    Timer { interval: 30000; running: pl.playing; repeat: true; onTriggered: Store.edit(s => { s.position = Math.floor(pl.position) }) }

    // ---------- the queue ----------
    function keysOf(list) { return list.map(t => typeof t === "string" ? t : t.key) }
    function shuffled(keys, firstKey) {
        const rest = keys.filter(k => k !== firstKey)
        for (let i = rest.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); const x = rest[i]; rest[i] = rest[j]; rest[j] = x }
        return firstKey ? [firstKey].concat(rest) : rest
    }
    // play these tracks, starting at `at` (an index into the list); with shuffle on the rest comes in a random order
    function playList(list, at) {
        let keys = keysOf(list)
        if (!keys.length) return
        at = Math.max(0, Math.min(keys.length - 1, at || 0))
        originalOrder = keys
        let start = at
        if (shuffle) { keys = shuffled(keys, keys[at]); start = 0 }
        send(["stop"]); send(["playlist-clear"])
        keys.forEach(k => send(["loadfile", url(k), "append"]))
        send(["playlist-play-index", start])
        set("pause", false)
    }
    function playShuffled(list) {
        const keys = keysOf(list)
        if (!keys.length) return
        if (!shuffle) setShuffle(true)
        playList(keys, Math.floor(Math.random() * keys.length))
    }
    function enqueue(list) {
        const keys = keysOf(list)
        if (!keys.length) return
        const empty = idle && queue.length === 0
        keys.forEach(k => send(["loadfile", url(k), "append"]))
        if (empty) { send(["playlist-play-index", 0]); set("pause", false) }
        originalOrder = originalOrder.concat(keys)
        Store.say(keys.length + (keys.length === 1 ? " track" : " tracks") + " added to the queue")
    }
    function playNext(list) {
        const keys = keysOf(list)
        if (!keys.length) return
        if (idle || index < 0) { enqueue(keys); return }
        keys.forEach((k, i) => send(["loadfile", url(k), "insert-at", index + 1 + i]))
        Store.say(keys.length === 1 ? "playing next" : keys.length + " tracks playing next")
    }
    function removeAt(i) { send(["playlist-remove", i]) }
    function clearQueue() { send(["stop"]); send(["playlist-clear"]); originalOrder = [] }
    function jumpTo(i) { send(["playlist-play-index", i]); set("pause", false) }
    // mpv's playlist-move takes the target entry, so a move down lands one short
    function move(from, to) { if (from === to) return; send(["playlist-move", from, from < to ? to + 1 : to]) }

    // ---------- transport ----------
    function toggle() {
        if (idle && queue.length) { send(["playlist-play-index", Math.max(0, index)]); set("pause", false); return }
        if (idle) return
        set("pause", !paused)
    }
    function play() { if (idle && queue.length) send(["playlist-play-index", Math.max(0, index)]); set("pause", false) }
    function pause() { set("pause", true) }
    function stop() { send(["stop"]); send(["playlist-clear"]) }
    function next() { send(["playlist-next", "force"]) }
    function prev() { if (position > 4) seek(0); else send(["playlist-prev", "weak"]) }
    function seek(s) { send(["seek", Math.max(0, s), "absolute"]) }
    function seekBy(d) { send(["seek", d, "relative"]) }
    function setVolume(v) { v = Math.max(0, Math.min(100, Math.round(v))); volume = v; set("volume", v); Store.edit(s => { s.volume = v }) }
    function toggleMute() { set("mute", !muted) }
    function setRepeat(mode, quiet) {
        repeat = mode
        set("loop-playlist", mode === "all" ? "inf" : "no")
        set("loop-file", mode === "one" ? "inf" : "no")
        Store.edit(s => { s.repeat = mode })
        if (!quiet) Store.say(mode === "off" ? "repeat off" : mode === "all" ? "repeat the queue" : "repeat this track")
    }
    function cycleRepeat() { setRepeat(repeat === "off" ? "all" : repeat === "all" ? "one" : "off") }
    // shuffle: the tracks after the current one in a random order (the original order comes back when it goes off)
    function setShuffle(on) {
        shuffle = on
        Store.edit(s => { s.shuffle = on })
        if (idle || index < 0 || queue.length < 2) { Store.say(on ? "shuffle on" : "shuffle off"); return }
        const cur = queue[index]
        let order
        if (on) {
            if (!originalOrder.length) originalOrder = queue
            order = [cur].concat(shuffled(queue.filter(k => k !== cur)))
        } else {
            const base = originalOrder.length ? originalOrder.filter(k => queue.includes(k)) : queue
            order = base
        }
        rebuild(order, cur)
        Store.say(on ? "shuffle on" : "shuffle off")
    }
    // the playlist rebuilt around the track playing (playlist-clear keeps it)
    function rebuild(order, cur) {
        send(["playlist-clear"])
        const ci = order.indexOf(cur)
        order.forEach((k, i) => {
            if (k === cur) return
            if (i < ci) send(["loadfile", url(k), "insert-at", i])
            else send(["loadfile", url(k), "append"])
        })
    }
    function toggleShuffle() { setShuffle(!shuffle) }
    function likeCurrent() { if (current) Store.toggleLike(current.key) }

    function status() {
        return { playing: playing, paused: paused, idle: idle, track: current ? { key: current.key, title: current.title, artist: current.artist, album: current.album } : null,
                 position: Math.floor(position), duration: Math.floor(duration), volume: volume, shuffle: shuffle, repeat: repeat, queue: queue.length, index: index }
    }
}
