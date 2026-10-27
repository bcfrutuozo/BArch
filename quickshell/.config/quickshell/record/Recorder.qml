// Recorder.qml — estado da gravação de tela (record.sh), compartilhado pela barra
// (RecordWidget) e pelo Control Center.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool recording: false
    property real startedAt: 0          // ms desde 1970
    property real now: Date.now()
    readonly property string elapsed: {
        const s = Math.max(0, Math.floor((now - startedAt) / 1000))
        const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, ss = s % 60
        const two = n => (n < 10 ? "0" : "") + n
        return (h > 0 ? h + ":" + two(m) : m) + ":" + two(ss)
    }
    readonly property string script: Quickshell.shellDir + "/record/record.sh"

    function start(mode) {
        Quickshell.execDetached(["bash", script, "start", mode])
        poll.interval = 600
        refresh()
    }
    function stop() {
        Quickshell.execDetached(["bash", script, "stop"])
        recording = false
        later.restart()
    }
    function refresh() { if (!proc.running) proc.running = true }

    Process {
        id: proc
        command: ["bash", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.trim().match(/^recording (\d+)/)
                root.recording = m !== null
                if (m) { root.startedAt = Number(m[1]) * 1000; poll.interval = 3000 }
            }
        }
    }

    // enquanto espera o início (a seleção da área pode demorar), confere mais rápido
    Timer { id: poll; interval: 3000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { id: later; interval: 1500; onTriggered: root.refresh() }
    Timer { interval: 1000; running: root.recording; repeat: true; onTriggered: root.now = Date.now() }
    Timer { id: slowDown; interval: 30000; running: poll.interval < 3000; onTriggered: poll.interval = 3000 }
}
