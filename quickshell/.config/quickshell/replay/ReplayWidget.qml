// ReplayWidget.qml — indicador do replay (gpu-screen-recorder, serviço gsr-replay).
// Na barra: círculo de gravação em contorno quando o replay está ligado (apagado quando desligado);
// pisca em destaque quando um replay é salvo. Some se o serviço não estiver instalado.
// Clique: salva os últimos 30 s · Botão direito: liga/desliga o replay (amarelo pulsando = ligando/desligando).

import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"

Item {
    id: root

    property string unit: "gsr-replay.service"
    property bool installed: false
    property bool active: false
    property bool busy: false               // ligando ou desligando
    property bool flash: false

    function glyph(cp) { return String.fromCodePoint(cp) }

    function refresh() { if (!stateProc.running) stateProc.running = true }

    function save() {
        if (!active || busy) return
        Quickshell.execDetached(["systemctl", "--user", "kill", "--kill-whom=main", "-s", "SIGUSR1", unit])
        flash = true
        flashTimer.restart()
    }

    function toggle() {
        if (busy) return
        busy = true
        Quickshell.execDetached(["systemctl", "--user", "--no-block", active ? "stop" : "start", unit])
        recheck.restart()
    }

    // "active" | "inactive" | "failed" …  e se o arquivo do serviço existe
    Process {
        id: stateProc
        command: ["sh", "-c", 'systemctl --user cat "$1" >/dev/null 2>&1 && echo installed; systemctl --user is-active "$1"', "sh", root.unit]
        stdout: StdioCollector {
            onStreamFinished: {
                root.installed = text.includes("installed")
                root.active = /(^|\n)active/.test(text)
                root.busy = /activating|deactivating|reloading/.test(text)
                if (root.busy) recheck.restart()
            }
        }
    }

    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { id: recheck; interval: 700; onTriggered: root.refresh() }
    Timer { id: flashTimer; interval: 900; onTriggered: root.flash = false }

    // ---------- na barra ----------
    visible: installed
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    Text {
        id: icon
        anchors.centerIn: parent
        text: root.glyph(0xF0EC3)       // record_circle_outline
        color: root.flash ? Theme.accent
             : root.busy ? Theme.warn
             : !root.active ? Theme.overlay
             : mouse.containsMouse ? Theme.accent : Theme.crit
        font.family: Theme.iconFont
        font.pixelSize: Theme.fontSize + 2
        scale: root.flash ? 1.25 : 1
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
        Behavior on color { ColorAnimation { duration: 150 } }
        // pulsa enquanto liga/desliga
        SequentialAnimation on opacity {
            running: root.busy
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 450 }
            NumberAnimation { to: 1; duration: 450 }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => m.button === Qt.RightButton ? root.toggle() : root.save()
    }

    // o atalho do Hyprland também avisa a barra, para piscar junto: qs ipc call replay save
    IpcHandler {
        target: "replay"
        function save(): void { root.save() }
        function toggle(): void { root.toggle() }
    }
}
