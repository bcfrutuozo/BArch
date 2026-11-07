// PlayerTray.qml — o BArch Player (quickshell/player) quando está tocando sem janela: um botão ao lado do
// tray, na ilha da direita, enquanto ~/.local/state/barch/player/window.json diz "hidden" e a instância
// responde. Clique: a janela volta · clique do meio: pausa/continua · clique direito: encerra o player.
// Some sozinho quando a janela abre ou o processo termina.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "../theme"

Item {
    id: root
    readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/barch/player/window.json"
    readonly property string cfg: Quickshell.env("HOME") + "/.config/quickshell/player"
    property bool hidden: false
    property bool alive: false
    property string track: ""
    // playing or paused comes live from MPRIS (mpv-mpris, identity "barch-player"), wherever the change came from
    readonly property var mpris: Mpris.players.values.find(p => /barch-player/i.test(p.identity || "")) || null
    readonly property bool playing: mpris ? mpris.isPlaying : false
    readonly property string mprisTrack: mpris && mpris.trackTitle ? mpris.trackTitle + (mpris.trackArtist ? " · " + mpris.trackArtist : "") : ""
    visible: hidden && alive
    implicitWidth: visible ? 22 : 0
    implicitHeight: 22

    function read() {
        try {
            const d = JSON.parse(stateFile.text())
            hidden = !!d.hidden && !d.quit
            track = d.track || ""
        } catch (e) { hidden = false }
        if (hidden) check.running = true; else alive = false
    }
    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.read()
    }
    // a instância ainda está lá? (o arquivo pode ficar para trás se o processo morrer)
    Process {
        id: check
        command: ["sh", "-c", 'out=$(qs -p "$1" ipc call app status 2>/dev/null) || exit 1; printf %s "$out"', "sh", root.cfg]
        stdout: StdioCollector { onStreamFinished: { try { const s = JSON.parse(text); if (s.track) root.track = s.track.title + " · " + s.track.artist } catch (e) {} } }
        onExited: (code, status) => root.alive = code === 0
    }
    Timer { interval: 20000; running: root.hidden; repeat: true; onTriggered: check.running = true }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: mouse.containsMouse ? Theme.hover : "transparent"
    }
    Text {
        anchors.centerIn: parent
        text: root.playing ? "󰝚" : "󰏤"
        color: root.playing ? Theme.accent : Theme.dim
        font.family: Theme.iconFont
        font.pixelSize: Theme.fontSize + 3
        Behavior on color { ColorAnimation { duration: 200 } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: ev => {
            if (ev.button === Qt.MiddleButton) { if (root.mpris && root.mpris.canTogglePlaying) root.mpris.togglePlaying(); else Quickshell.execDetached(["qs", "-p", root.cfg, "ipc", "call", "app", "toggle"]) }
            else if (ev.button === Qt.RightButton) Quickshell.execDetached(["qs", "-p", root.cfg, "ipc", "call", "app", "quit"])
            else Quickshell.execDetached(["qs", "-p", root.cfg, "ipc", "call", "app", "window"])
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
        implicitWidth: Math.min(360, tip.implicitWidth + 20)
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
                width: Math.min(implicitWidth, 340)
                text: "Player" + ((root.mprisTrack || root.track) ? "  ·  " + (root.mprisTrack || root.track) : "") + (root.playing ? "" : "  ·  paused") + "\nclick: open · middle: play/pause · right: quit"
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 2
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }
    }
}
