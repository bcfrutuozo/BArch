// Store.qml — PipeWire through Quickshell.Services.Pipewire (devices, streams, volumes, links)
// plus the few things it does not expose: moving a stream to another device (pactl, with the
// object serials PipeWire gives), the clock settings (pw-metadata) and the Bluetooth codec
// (node properties).
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

Singleton {
    id: store

    // PwNodeType flags: Audio 1, Video 2, Stream 4, Source 8, Sink 16 (a playing app is Audio|Stream|Sink,
    // a recording one Audio|Stream|Source). Properties only arrive once a node is tracked, so every
    // audio node is tracked and the lists go by type, not by media.class.
    readonly property var nodes: Pipewire.nodes.values
    readonly property var audioNodes: nodes.filter(n => n.type & 1)
    readonly property var sinks: audioNodes.filter(n => (n.type & 16) && !(n.type & 4))
    readonly property var sources: audioNodes.filter(n => (n.type & 8) && !(n.type & 4))
    // (the peak meters of this window are capture streams named quickshell: left out)
    readonly property var playback: audioNodes.filter(n => (n.type & 4) && (n.type & 16) && n.name !== "quickshell")
    readonly property var recording: audioNodes.filter(n => (n.type & 4) && (n.type & 8) && n.name !== "quickshell")
    readonly property var bluetooth: nodes.filter(n => n.name && (n.name.startsWith("bluez_output.") || n.name.startsWith("bluez_input.")))
    readonly property var links: Pipewire.links.values
    readonly property var defaultSink: Pipewire.defaultAudioSink
    readonly property var defaultSource: Pipewire.defaultAudioSource

    PwObjectTracker { objects: store.audioNodes }

    property string status: ""
    property bool statusBad: false
    function say(msg, bad) { status = msg; statusBad = !!bad }

    function prop(n, k) { return n && n.properties ? (n.properties[k] || "") : "" }
    function cls(n) { return prop(n, "media.class") }
    function serial(n) { return String(prop(n, "object.serial") || n.id) }
    function title(n) { return n ? (n.description || n.nickname || n.name || "") : "" }
    function appName(n) { return prop(n, "application.name") || prop(n, "node.name") || n.name || "Application" }
    function appDetail(n) { return [prop(n, "media.name"), prop(n, "application.process.binary")].filter(x => x).join("  ·  ") }
    function appIcon(n) {
        const name = prop(n, "application.icon-name") || prop(n, "application.name") || ""
        return name ? Quickshell.iconPath(name.toLowerCase(), true) || Quickshell.iconPath(name, true) || "" : ""
    }
    // the device a stream is connected to (through its links)
    function peerOf(stream) {
        for (const l of links) {
            if (!l.source || !l.target) continue
            if (l.source === stream && !l.target.isStream) return l.target
            if (l.target === stream && !l.source.isStream) return l.source
        }
        return null
    }
    function setVolume(n, v) { if (n && n.audio) { n.audio.volume = Math.round(Math.max(0, Math.min(1.5, v)) * 100) / 100; if (v > 0 && n.audio.muted) n.audio.muted = false } }
    function toggleMute(n) { if (n && n.audio) n.audio.muted = !n.audio.muted }
    function setDefaultSink(n) { Pipewire.preferredDefaultAudioSink = n; say("default output: " + title(n)) }
    function setDefaultSource(n) { Pipewire.preferredDefaultAudioSource = n; say("default input: " + title(n)) }

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
    function run(cmd, cb) { const p = procComp.createObject(store, { command: cmd, cb: cb }); p.running = true }

    // ---------- routing (pactl: a sink-input index is the PipeWire object serial) ----------
    function moveStream(stream, device) {
        const input = !!(stream.type & 8)
        run(["pactl", input ? "move-source-output" : "move-sink-input", serial(stream), device.name], (out, err, code) => {
            say(code === 0 ? appName(stream) + " → " + title(device) : "move failed: " + err.trim(), code !== 0)
        })
    }

    // ---------- clock settings (pw-metadata -n settings) ----------
    property var settings: ({})
    property var deviceFormats: ({})     // sink/source name -> "s32le 2ch 192000Hz"
    function refreshSettings() {
        run(["pw-metadata", "-n", "settings"], out => {
            const s = {}
            for (const line of out.split("\n")) { const m = /key:'([^']+)' value:'([^']*)'/.exec(line); if (m) s[m[1]] = m[2] }
            settings = s
        })
        run(["sh", "-c", "pactl list short sinks; pactl list short sources"], out => {
            const f = {}
            for (const line of out.split("\n")) { const c = line.split("\t"); if (c.length >= 4) f[c[1]] = c[3] }
            deviceFormats = f
        })
    }
    function setSetting(key, value) {
        run(["pw-metadata", "-n", "settings", "0", key, String(value)], (out, err, code) => { say(code === 0 ? key + " = " + value : err.trim(), code !== 0); refreshSettings() })
    }
    readonly property var allowedRates: {
        const m = /\[([^\]]*)\]/.exec(settings["clock.allowed-rates"] || "")
        return m ? m[1].split(",").map(x => Number(x.trim())).filter(x => x) : [44100, 48000, 96000, 192000]
    }
    Component.onCompleted: refreshSettings()
    Timer { interval: 5000; running: true; repeat: true; onTriggered: store.refreshSettings() }

    function has(cmd, cb) { run(["sh", "-c", "command -v " + cmd], (out, err, code) => cb(code === 0)) }
    function launch(cmd) { Quickshell.execDetached(["sh", "-c", "exec uwsm app -- " + cmd]) }
}
