// Viz.qml — the spectrum of what plays, for the Visualizer page and the small bars of the bottom bar:
// viz.py captures the player's own PipeWire stream (never the microphone) and prints one line of band
// levels per frame; it only runs while something wants the frames (`wanted` > 0) and a track is loaded.
// Settings live in Store.state.viz: { mode, bands, sensitivity, color, cover, trails, mini }.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: viz

    property int wanted: 0
    readonly property var settings: Object.assign({ mode: "bars", bands: 64, sensitivity: 60, color: "palette", cover: true, trails: false, mini: true }, Store.state.viz || {})
    readonly property int bandCount: settings.bands
    readonly property real sensitivity: settings.sensitivity        // the dB floor: 40 = loud only, 80 = everything
    property var bands: []                                           // 0..1 per band, the latest frame
    property real level: 0
    property int frame: 0
    readonly property bool running: wanted > 0 && Player.hasTrack

    function set(k, v) { Store.edit(s => { s.viz = Object.assign({}, s.viz || {}, { [k]: v }) }) }

    Process {
        id: proc
        command: ["python3", "-u", Quickshell.shellDir + "/viz.py", "--bands", String(viz.bandCount), "--fps", "30", "--floor", String(viz.sensitivity)]
        running: viz.running
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                const parts = line.trim().split(" ")
                if (parts.length < 2) return
                viz.level = parseInt(parts[0]) / 1000
                const b = new Array(parts.length - 1)
                for (let i = 1; i < parts.length; i++) b[i - 1] = parseInt(parts[i]) / 1000
                viz.bands = b
                viz.frame++
            }
        }
        onExited: (code, status) => { if (viz.running) restart.start() }
    }
    Timer { id: restart; interval: 1500; onTriggered: if (viz.running && !proc.running) proc.running = true }
    onBandCountChanged: if (proc.running) { proc.running = false; restart.start() }
    onSensitivityChanged: if (proc.running) proc.write(viz.sensitivity + "\n")
    onRunningChanged: if (!running) { bands = []; level = 0; frame++ }
}
