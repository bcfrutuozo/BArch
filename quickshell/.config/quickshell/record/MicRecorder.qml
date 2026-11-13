// MicRecorder.qml — state of the microphone recording (mic.sh), for the bar's MicRecordWidget.
// Super+R and `barch mic` run mic.sh and then `qs ipc call micrec refresh`, so the indicator
// follows at once; the slow poll covers a recording started while the bar was down.
pragma Singleton

pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool recording: false
    property real startedAt: 0          // ms since 1970
    property string file: ""
    property real now: Date.now()
    readonly property string elapsed: {
        const s = Math.max(0, Math.floor((now - startedAt) / 1000))
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, ss = s % 60
        const two = n => (n < 10 ? "0" : "") + n
        return (h > 0 ? h + ":" + two(m) : m) + ":" + two(ss)
    }
    readonly property string script: Quickshell.shellDir + "/record/mic.sh"

    function toggle() { Quickshell.execDetached(["bash", script, "toggle"]) }
    function stop() { Quickshell.execDetached(["bash", script, "stop"]); recording = false }
    function refresh() { if (proc.running) again.restart(); else proc.running = true }

    Process {
        id: proc
        command: ["bash", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.trim().match(/^recording (\d+) ?(.*)$/)
                root.recording = m !== null
                if (m) { root.startedAt = Number(m[1]) * 1000; root.file = m[2]; root.now = Date.now() }
                else root.file = ""
            }
        }
    }

    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { id: again; interval: 300; onTriggered: root.refresh() }
    Timer { interval: 1000; running: root.recording; repeat: true; onTriggered: root.now = Date.now() }

    IpcHandler {
        target: "micrec"
        function refresh(): string { root.refresh(); return JSON.stringify({ ok: true }) }
        function status(): string {
            return JSON.stringify({ ok: true, recording: root.recording, file: root.file,
                                    seconds: root.recording ? Math.floor((Date.now() - root.startedAt) / 1000) : 0 })
        }
    }
}
