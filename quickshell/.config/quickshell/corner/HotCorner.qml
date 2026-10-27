// HotCorner.qml — canto quente: encostar o mouse no canto superior direito do monitor
// principal abre a visão geral dos workspaces (a mesma do Super+Tab).
// É o canto direito porque o esquerdo faz divisa com o monitor vertical (o mouse passaria
// por ele ao trocar de monitor). Espera um instante antes de abrir e não age com uma
// janela em tela cheia (jogos).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Scope {
    id: root
    property string output: "HDMI-A-2"
    property int dwell: 180                 // ms parado no canto antes de abrir

    PanelWindow {
        screen: Quickshell.screens.find(s => s.name === root.output) || Quickshell.screens[0]
        anchors { top: true; right: true }
        implicitWidth: 3
        implicitHeight: 3
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-hotcorner"

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: dwellTimer.restart()
            onExited: dwellTimer.stop()
        }
    }

    Timer { id: dwellTimer; interval: root.dwell; onTriggered: fsCheck.running = true }

    Process {
        id: fsCheck
        command: ["hyprctl", "activewindow", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let w = {}
                try { w = JSON.parse(text) } catch (e) {}
                if (w && (w.fullscreen === true || w.fullscreen > 0)) return
                Quickshell.execDetached(["qs", "ipc", "call", "overview", "toggle"])
            }
        }
    }
}
