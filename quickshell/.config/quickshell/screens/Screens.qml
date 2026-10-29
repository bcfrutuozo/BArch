// Screens.qml — the monitors as a settled list of *names*, for Variants that create one
// window per monitor (bars, wallpaper).
//
// Why not Quickshell.screens straight into Variants.model: quickshell 0.3.2 crashes in
// Variants::updateVariants when the outputs change while it is creating windows (use-after-
// free: the model holds the screen objects, and those die under its feet during a hotplug;
// creating a PanelWindow dispatches Wayland events, so the change lands mid-loop). Seen at
// boot (2026-10-28), on resume and on a monitor power cycle (2026-10-29).
//
// Two things fix that here:
// - the model is a list of names (plain strings): nothing in it can dangle, and Variants
//   only recreates a window when a name appears or disappears;
// - it changes 250 ms after the last output change, from the event loop, never from inside
//   the loop that is creating windows.
// A delegate gets its live screen object with Screens.byName(modelData); that binding
// follows Quickshell.screens directly, so it is null for the moment a monitor is gone.
pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    property var names: []

    function current() { return Quickshell.screens.map(s => s.name) }

    function byName(name) {
        return Quickshell.screens.find(s => s.name === name) || null
    }

    Timer {
        id: settle
        interval: 250
        onTriggered: {
            const n = root.current()
            if (JSON.stringify(n) !== JSON.stringify(root.names)) root.names = n
        }
    }

    Connections {
        target: Quickshell
        function onScreensChanged() { settle.restart() }
    }

    Component.onCompleted: root.names = root.current()
}
