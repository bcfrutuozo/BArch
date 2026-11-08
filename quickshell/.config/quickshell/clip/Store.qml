// Store.qml — the state of one edit: the file and what clip.py found out about it, the crop
// (in pixels of the frame as displayed: after the file's own rotation, the rotation and the flips
// chosen here), the trim, the frame being shown, and the export. Everything that touches the
// video goes through clip.py next to this file, the same code `barch clip export` runs.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    // the shell dir is a symlink into the repo; python resolves it fine, so no readlink needed
    readonly property string script: Quickshell.shellDir + "/clip.py"

    // ---------- the file ----------
    property string file: ""
    property var info: null            // clip.py probe
    property bool loading: false
    property string error: ""
    readonly property string name: file ? file.split("/").pop() : ""
    readonly property string folder: file ? file.slice(0, file.lastIndexOf("/")) : ""
    readonly property bool ready: !!info && !loading

    // ---------- the edit ----------
    property int rotate: 0             // clockwise degrees of the displayed frame
    property bool flipH: false
    property bool flipV: false
    property real cropX: 0             // in pixels of the rotated frame (rotW x rotH)
    property real cropY: 0
    property real cropW: 0
    property real cropH: 0
    property string aspect: "free"     // free | original | 1:1 | 16:9 | 9:16 | 4:3 | 3:4 | 3:2 | 2:3
    property real trimStart: 0
    property real trimEnd: 0
    property real playhead: 0

    readonly property int srcW: info ? info.width : 0
    readonly property int srcH: info ? info.height : 0
    readonly property int rotW: rotate % 180 ? srcH : srcW
    readonly property int rotH: rotate % 180 ? srcW : srcH
    readonly property real duration: info ? info.duration : 0
    readonly property real fps: info && info.fps > 0 ? info.fps : 30
    readonly property real frameStep: 1 / fps
    readonly property bool cropped: rotW > 0 && (even(cropX) > 0 || even(cropY) > 0 || even(cropW) < even(rotW) || even(cropH) < even(rotH))
    readonly property bool trimmed: duration > 0 && (trimStart > 0.0005 || trimEnd < duration - 0.0005)
    readonly property bool edited: cropped || trimmed || rotate !== 0 || flipH || flipV
    readonly property int outW: cropped ? even(cropW) : even(rotW)
    readonly property int outH: cropped ? even(cropH) : even(rotH)
    readonly property real outLength: Math.max(0, trimEnd - trimStart)
    readonly property real aspectRatio: aspectOf(aspect)

    function even(n) { return Math.max(0, Math.floor(n / 2 + 0.5) * 2) }
    function aspectOf(a) {
        if (a === "original") return srcH > 0 ? srcW / srcH : 0
        const m = /^(\d+):(\d+)$/.exec(a)
        return m ? Number(m[1]) / Number(m[2]) : 0
    }
    readonly property var aspects: [
        { id: "free",     label: "Free" },
        { id: "original", label: "Original" },
        { id: "1:1",      label: "Square" },
        { id: "16:9",     label: "16:9" },
        { id: "9:16",     label: "9:16" },
        { id: "4:3",      label: "4:3" },
        { id: "3:4",      label: "3:4" },
        { id: "3:2",      label: "3:2" },
        { id: "2:3",      label: "2:3" }
    ]

    // the --crop / --from / --to of clip.py for the state as it is
    function editArgs() {
        const a = []
        if (cropped) a.push("--crop", [even(cropW), even(cropH), even(cropX), even(cropY)].join(":"))
        if (rotate) a.push("--rotate", String(rotate))
        const flip = (flipH ? "h" : "") + (flipV ? "v" : "")
        if (flip) a.push("--flip", flip)
        if (trimmed) a.push("--from", trimStart.toFixed(3), "--to", trimEnd.toFixed(3))
        return a
    }
    readonly property string command: file ? ["barch", "clip", "export", quote(file)].concat(editArgs().map(quote)).join(" ") : ""
    function quote(s) { return /^[\w@%+=:,.\/-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'" }

    // ---------- frames ----------
    property string frameUrl: ""       // the frame at the playhead (HDR tone mapped), as a file URL
    property real frameTime: -1
    property string stripUrl: ""
    property int stripCount: 0
    property bool frameBusy: false
    property real wantedTime: -1

    // ---------- the export ----------
    property bool saving: false
    property real progress: 0
    property string speed: ""
    property string encoder: ""
    property var result: null          // clip.py's final line: {ok, file, width, height, duration, size, original}
    property string status: ""
    property bool statusBad: false
    function say(msg, bad) { status = msg; statusBad = !!bad }

    // ================================================================ processes
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
    function fileUrl(path) { return "file://" + encodeURI(path.trim()).replace(/#/g, "%23").replace(/\?/g, "%3F") }
    function pathOf(url) {
        let s = String(url)
        if (s.startsWith("file://")) s = decodeURIComponent(s.slice(7))
        return s
    }

    // ================================================================ opening
    function open(path) {
        path = pathOf(path)
        if (!path) return
        file = path
        info = null
        error = ""
        loading = true
        result = null
        frameUrl = ""; stripUrl = ""; frameTime = -1; wantedTime = -1; stripCount = 0
        say("")
        run(["python3", script, "probe", path], (out, err, code) => {
            if (store.file !== path) return
            loading = false
            if (code !== 0) { error = (err.trim().split("\n").pop() || "cannot read the file"); info = null; return }
            try { info = JSON.parse(out) } catch (e) { error = "bad answer from clip.py"; return }
            resetEdit()
            seek(Math.min(duration * 0.1, 1), true)
        })
    }
    function pick() {
        const start = folder || (Quickshell.env("HOME") + "/Videos/")
        run(["zenity", "--file-selection", "--title=Open a video",
             "--file-filter=Videos | *.mp4 *.MP4 *.mov *.MOV *.m4v *.mkv *.webm *.avi *.mts *.m2ts *.ts *.3gp *.mpg *.mpeg",
             "--file-filter=All files | *", "--filename=" + start + "/"], (out, err, code) => {
            if (code === 0 && out.trim()) open(out.trim())
        })
    }
    function resetEdit() {
        rotate = 0; flipH = false; flipV = false
        aspect = "free"
        setCropRect(0, 0, rotW, rotH)
        trimStart = 0
        trimEnd = duration
        playhead = Math.min(playhead, duration)
    }
    function reset() { resetEdit(); say("edit reset") }

    // ================================================================ the crop
    function setCropRect(x, y, w, h) {
        const W = rotW, H = rotH, min = 16
        w = Math.max(min, Math.min(w, W)); h = Math.max(min, Math.min(h, H))
        x = Math.max(0, Math.min(x, W - w)); y = Math.max(0, Math.min(y, H - h))
        cropX = x; cropY = y; cropW = w; cropH = h
    }
    // the largest rectangle of ratio r centred where the crop is now (the whole frame when r is 0)
    function fitAspect(r) {
        if (!(r > 0)) { setCropRect(0, 0, rotW, rotH); return }
        const cx = cropX + cropW / 2, cy = cropY + cropH / 2
        let w = rotW, h = w / r
        if (h > rotH) { h = rotH; w = h * r }
        setCropRect(cx - w / 2, cy - h / 2, w, h)
    }
    function setAspect(a) {
        aspect = a
        if (a === "free") return
        fitAspect(aspectOf(a))
    }
    function rotateLeft() { rotateTo((rotate + 270) % 360) }
    function rotateRight() { rotateTo((rotate + 90) % 360) }
    function rotateTo(deg) {
        // the crop turns with the picture: a rectangle in the old frame mapped into the new one
        const ox = cropX, oy = cropY, ow = cropW, oh = cropH, W = rotW, H = rotH
        const delta = ((deg - rotate) % 360 + 360) % 360
        rotate = deg
        if (delta === 90) setCropRect(H - oy - oh, ox, oh, ow)
        else if (delta === 270) setCropRect(oy, W - ox - ow, oh, ow)
        else if (delta === 180) setCropRect(W - ox - ow, H - oy - oh, ow, oh)
        if (aspect !== "free" && aspect !== "original") {
            // a fixed ratio stays as it reads (16:9 is still wide after a turn)
            const r = aspectOf(aspect)
            if (Math.abs(cropW / cropH - r) > 0.01) fitAspect(r)
        } else if (aspect === "original" && Math.abs(cropW / cropH - srcW / srcH) > 0.01) {
            fitAspect(srcW / srcH)
        }
    }
    function toggleFlipH() { flipH = !flipH; cropX = rotW - cropX - cropW }
    function toggleFlipV() { flipV = !flipV; cropY = rotH - cropY - cropH }

    // ================================================================ the trim
    function setTrim(start, end) {
        const min = Math.min(frameStep * 2, duration)
        start = Math.max(0, Math.min(start, duration - min))
        end = Math.max(start + min, Math.min(end, duration))
        trimStart = start; trimEnd = end
    }
    function setStart(t) { setTrim(t, Math.max(trimEnd, t + frameStep * 2)) }
    function setEnd(t) { setTrim(Math.min(trimStart, t - frameStep * 2), t) }
    function markStart() { setStart(playhead); say("start at " + hms(trimStart)) }
    function markEnd() { setEnd(playhead); say("end at " + hms(trimEnd)) }
    function step(n) { seek(playhead + n * frameStep) }

    // ================================================================ frames
    // the frame at t: one extraction at a time, the newest wish wins (scrubbing asks for many)
    function seek(t, force) {
        if (!info) return
        t = Math.max(0, Math.min(t, Math.max(0, duration - frameStep)))
        playhead = t
        wantedTime = t
        if (!frameBusy || force) nextFrame()
    }
    function nextFrame() {
        if (!info || wantedTime < 0) return
        const t = wantedTime, path = file
        wantedTime = -1
        if (Math.abs(t - frameTime) < frameStep / 2 && frameUrl) return
        frameBusy = true
        run(["python3", script, "frame", path, t.toFixed(3), "--height", "1440"], (out, err, code) => {
            frameBusy = false
            if (store.file !== path) return
            if (code === 0 && out.trim()) { frameUrl = fileUrl(out); frameTime = t }
            else say("frame: " + (err.trim().split("\n").pop() || "failed"), true)
            if (wantedTime >= 0) nextFrame()
        })
    }
    function loadStrip(count) {
        if (!info || count < 2 || count === stripCount) return
        const path = file
        stripCount = count
        run(["python3", script, "strip", path, "--count", String(count), "--height", "72"], (out, err, code) => {
            if (store.file !== path || store.stripCount !== count) return
            if (code === 0 && out.trim()) stripUrl = fileUrl(out)
        })
    }

    // ================================================================ preview and export
    property var previewProc: null
    function preview() {
        if (!info) return
        if (previewProc) { previewProc.running = false; previewProc = null }
        say("preview: the edit, encoded on the fly into mpv")
        previewProc = run(["python3", script, "preview", file].concat(editArgs()), (out, err, code) => {
            previewProc = null
            if (code !== 0 && code !== 4) say("preview failed: " + (err.trim().split("\n").pop() || code), true)
        })
    }

    Process {
        id: exporter
        property string target: ""
        stdout: SplitParser {
            onRead: line => {
                let o
                try { o = JSON.parse(line) } catch (e) { return }
                if (o.stage === "encoding") { store.encoder = o.encoder + (o.hwaccel ? " · cuda" : ""); store.progress = 0 }
                else if (o.stage === "retry") store.say("retrying without the GPU: " + (o.error || ""), true)
                if (o.progress !== undefined) store.progress = o.progress
                if (o.speed) store.speed = o.speed
                if (o.ok === true) {
                    store.result = o
                    store.say("saved " + o.file.split("/").pop() + " · " + o.width + "×" + o.height + " · " + store.hms(o.duration) + " · " + store.mb(o.size))
                    if (o.original) store.reopenAfterReplace.restart()      // the file under the editor changed: read it again
                }
                else if (o.ok === false) store.say("save failed: " + o.error, true)
            }
        }
        stderr: StdioCollector { onStreamFinished: if (text.trim() && !store.result) store.say("save failed: " + text.trim().split("\n").pop(), true) }
        onExited: (code, status) => {
            store.saving = false
            if (code !== 0 && !store.statusBad) store.say(code === 15 || code === 9 ? "save cancelled" : "save failed (exit " + code + ")", code !== 15 && code !== 9)
        }
    }
    function save(replace, output) {
        if (!info || saving) return
        result = null
        progress = 0; speed = ""; encoder = ""
        saving = true
        say(replace ? "replacing " + name + "…" : "saving…")
        let cmd = ["python3", script, "export", file].concat(editArgs(), ["--json"])
        if (replace) cmd.push("--replace")
        else if (output) cmd.push("-o", output)
        exporter.command = cmd
        exporter.running = true
    }
    property Timer reopenAfterReplace: Timer { interval: 300; onTriggered: { const r = store.result; store.open(store.file); store.result = r } }
    function cancelSave() { if (saving) { exporter.signal(15); say("save cancelled") } }
    function openResult() { if (result && result.file) run(["xdg-open", result.file], () => {}) }
    function showResult() { if (result && result.file) run(["xdg-open", result.file.slice(0, result.file.lastIndexOf("/"))], () => {}) }
    // the proposed name of a new file: <name>-clip.<ext> (clip.py picks -2, -3 when taken)
    readonly property string suggestedName: name ? name.replace(/(\.[^.]+)?$/, m => "-clip" + m) : ""

    // ================================================================ text
    function hms(t) {
        const tenths = Math.round(Math.max(0, t) * 10)
        const whole = Math.floor(tenths / 10), tenth = tenths % 10
        const h = Math.floor(whole / 3600), m = Math.floor(whole % 3600 / 60), s = whole % 60
        const mm = h ? String(m).padStart(2, "0") : String(m)
        return (h ? h + ":" : "") + mm + ":" + String(s).padStart(2, "0") + "." + tenth
    }
    function mb(bytes) { return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(2) + " GB" : (bytes / 1048576).toFixed(1) + " MB" }
    readonly property string infoLine: {
        if (!info) return ""
        const parts = [info.width + "×" + info.height]
        if (info.fps) parts.push((Math.round(info.fps * 100) / 100) + " fps")
        let codec = (info.codec || "").toUpperCase()
        if (codec === "HEVC") codec = "HEVC"; else if (codec === "H264") codec = "H.264"
        if (info.bits > 8) codec += " " + info.bits + "-bit"
        parts.push(codec)
        if (info.hdr) parts.push("HDR")
        parts.push(hms(info.duration))
        if (info.size) parts.push(mb(info.size))
        if (info.audio) parts.push(info.audio.codec.toUpperCase() + (info.audio.channels ? " " + info.audio.channels + "ch" : ""))
        else parts.push("no audio")
        return parts.join(" · ")
    }
}
