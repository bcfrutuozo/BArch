// Screens.qml — Quickshell.screens, but settled: the list only changes 250 ms after the last
// output change.
//
// Why: a Variants whose model is bound straight to Quickshell.screens crashes quickshell 0.3.2
// when the outputs change while it is creating its windows (use-after-free in
// Variants::updateVariants, src/core/variants.cpp). Creating a PanelWindow dispatches Wayland
// events, so at boot and on resume (DPMS, HDR kick) the binding re-evaluates mid-loop and the
// model is freed under its feet. Seen 2026-10-28 (boot) and 2026-10-29 (resume from suspend).
// Here a change only restarts the timer; the list is assigned later, from the event loop,
// never from inside the loop that is creating windows.
pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root

    property var list: []

    function current() { return Quickshell.screens.slice() }

    Timer {
        id: settle
        interval: 250
        onTriggered: root.list = root.current()
    }

    Connections {
        target: Quickshell
        function onScreensChanged() { settle.restart() }
    }

    Component.onCompleted: root.list = root.current()
}
