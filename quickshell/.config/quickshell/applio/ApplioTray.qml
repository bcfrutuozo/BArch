// ApplioTray.qml — Applio's web server (applio/applio.sh) while it runs: a button next to the tray,
// in the right island. Click: open it in the browser · right click: stop the server.
// Dim while it starts, accent once it answers; gone when stopped. applio.sh pokes `refresh`
// over IPC on every change, the poll only covers a server started or killed some other way.

import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"

Item {
    id: root
    readonly property string script: Quickshell.shellDir + "/applio/applio.sh"
    property string phase: "stopped"      // stopped | starting | running
    property string url: ""
    visible: phase !== "stopped"
    implicitWidth: visible ? 22 : 0
    implicitHeight: 22

    function refresh() { if (proc.running) again.restart(); else proc.running = true }

    Process {
        id: proc
        command: ["bash", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                const m = t.match(/^running (\S+)/)
                root.phase = m ? "running" : (t === "starting" ? "starting" : "stopped")
                root.url = m ? m[1] : ""
            }
        }
    }
    // quick while starting (the first answer takes ~10-20 s), slow otherwise
    Timer { interval: root.phase === "starting" ? 1500 : 10000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { id: again; interval: 300; onTriggered: root.refresh() }

    IpcHandler {
        target: "applio"
        function refresh(): string { root.refresh(); return JSON.stringify({ ok: true }) }
        function status(): string { return JSON.stringify({ ok: true, state: root.phase, url: root.url }) }
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: mouse.containsMouse ? Theme.hover : "transparent"
    }
    Text {
        anchors.centerIn: parent
        text: String.fromCodePoint(0xF05CB)   // account-voice
        color: root.phase === "running" ? Theme.accent : Theme.dim
        font.family: Theme.iconFont
        font.pixelSize: Theme.fontSize + 3
        Behavior on color { ColorAnimation { duration: 200 } }
        SequentialAnimation on opacity {
            running: root.phase === "starting"
            loops: Animation.Infinite
            onRunningChanged: if (!running) parent.opacity = 1
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: ev => {
            if (ev.button === Qt.RightButton) { Quickshell.execDetached(["bash", root.script, "stop"]); root.phase = "stopped" }
            else Quickshell.execDetached(["bash", root.script, "open"])
        }
    }

    PopupWindow {
        visible: mouse.containsMouse
        anchor.item: root
        anchor.rect.x: root.width / 2
        anchor.rect.y: root.height + 12
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Bottom
        implicitWidth: tip.implicitWidth + 20
        implicitHeight: tip.implicitHeight + 12
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            radius: Theme.buttonRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            Text {
                id: tip
                anchors.centerIn: parent
                text: "Applio" + (root.phase === "running" ? "  ·  " + root.url : "  ·  starting…") + "\nclick: open · right: stop the server"
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 2
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
