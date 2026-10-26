// MediaWidget.qml — player de mídia (MPRIS) para a ilha do relógio
// Na barra: aparece ao lado da data só quando algo está tocando ou pausado,
// e a ilha do relógio cresce para acomodá-lo (como uma "ilha dinâmica").
//   Clique: painel com capa, progresso e controles · Clique do meio: tocar/pausar
// Funciona com Spotify, navegadores, mpv e qualquer app que fale MPRIS.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import "../theme"

Item {
    id: root

    // ilha onde o widget está (a do relógio); o painel se centraliza nela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    // ---------- aparência (o shell.qml passa as cores do tema) ----------
    property color fg: Theme.fg
    property color dim: Theme.dim
    property color accent: Theme.accent
    property color bg: Theme.bg
    property color border: Theme.border
    property color hover: Theme.hover
    property color track: Theme.track
    property string fontFamily: Theme.font
    property string iconFont: Theme.iconFont
    property int fontSize: Theme.fontSize
    property int maxTitleWidth: 260     // largura máxima do título na barra

    // ---------- escolha do player ----------
    readonly property var players: Mpris.players.values
    property var lastPlaying: null      // o último que estava tocando
    property var pinned: null           // escolhido à mão no painel

    readonly property var player: {
        if (pinned && players.includes(pinned)) return pinned
        const playing = players.find(p => p.isPlaying)
        if (playing) return playing
        if (lastPlaying && players.includes(lastPlaying)) return lastPlaying
        return players.length > 0 ? players[0] : null
    }
    readonly property bool hasTrack: player !== null && (player.trackTitle || "") !== ""
    readonly property bool playing: hasTrack && player.isPlaying

    // Se o player fecha com o painel aberto, o widget some da barra e o painel
    // ficaria órfão (sem âncora e sem ícone para fechá-lo). Fecha junto.
    onHasTrackChanged: if (!hasTrack) Popups.hide(popup)
    onPlayersChanged: if (pinned && !players.includes(pinned)) pinned = null

    // lembra quem tocou por último, para continuar mostrando ao pausar
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            const p = root.players.find(p => p.isPlaying)
            if (p) root.lastPlaying = p
        }
    }

    // o MPRIS não avisa o progresso sozinho; pede a posição a cada segundo com o painel aberto
    Timer {
        interval: 1000
        running: popup.visible && root.playing
        repeat: true
        onTriggered: root.player.positionChanged()
    }

    // ---------- utilidades ----------
    function glyph(cp) { return String.fromCodePoint(cp) }
    function time(s) {
        s = Math.max(0, Math.floor(s || 0))
        const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
        const mm = h > 0 ? String(m).padStart(2, "0") : String(m)
        return (h > 0 ? h + ":" : "") + mm + ":" + String(r).padStart(2, "0")
    }
    function barText() {
        if (!hasTrack) return ""
        const a = player.trackArtist || ""
        return a ? player.trackTitle + "  ·  " + a : player.trackTitle
    }

    visible: hasTrack
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    // ---------- na barra ----------
    Row {
        id: barRow
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8

        // divisória discreta entre data e música
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: 14
            color: root.border
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(0xF0F74)   // nf-md-music_note_outline
            color: root.playing ? root.accent : root.dim
            font.family: root.iconFont
            font.pixelSize: root.fontSize + 1
            Behavior on color { ColorAnimation { duration: 200 } }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, root.maxTitleWidth)
            text: root.barText()
            elide: Text.ElideRight
            color: root.playing ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            Behavior on color { ColorAnimation { duration: 200 } }
        }
    }

    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) {
                if (root.player && root.player.canTogglePlaying) root.player.togglePlaying()
            } else {
                Popups.toggle(popup)
            }
        }
    }

    // ---------- painel ----------
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        // só um painel aberto por vez na barra
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        // centralizado embaixo da ilha do relógio, popupGap abaixo dela (como o calendário)
        anchor.item: root.island
        anchor.rect.x: root.island.width / 2
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Bottom
        implicitWidth: 360
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        onVisibleChanged: if (visible && root.player) root.player.positionChanged()

        HyprlandFocusGrab {
            windows: [popup]
            active: popup.visible
            onCleared: Popups.hide(popup)
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: root.bg
            border.color: root.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // --- capa + informações ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    ClippingRectangle {
                        Layout.preferredWidth: 84
                        Layout.preferredHeight: 84
                        radius: 10
                        color: root.hover

                        Image {
                            id: art
                            anchors.fill: parent
                            source: root.hasTrack ? (root.player.trackArtUrl || "") : ""
                            sourceSize.width: 168
                            sourceSize.height: 168
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: art.status !== Image.Ready
                            text: root.glyph(0xF0F74)
                            color: root.dim
                            font.family: root.iconFont
                            font.pixelSize: 32
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3

                        Text {
                            Layout.fillWidth: true
                            text: root.hasTrack ? root.player.trackTitle : ""
                            color: root.fg
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize + 1
                            font.bold: true
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: root.hasTrack ? (root.player.trackArtist || "") : ""
                            color: root.fg
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 1
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: root.hasTrack ? (root.player.trackAlbum || "") : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 2
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.topMargin: 2
                            text: root.player ? (root.player.identity || "") : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 3
                        }
                    }
                }

                // --- progresso (clique para pular, quando o app permite) ---
                ColumnLayout {
                    id: progress
                    visible: root.hasTrack && root.player.lengthSupported && root.player.length > 0
                    Layout.fillWidth: true
                    spacing: 4

                    readonly property real frac: root.hasTrack && root.player.length > 0
                        ? Math.max(0, Math.min(1, root.player.position / root.player.length)) : 0

                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 12

                        Rectangle {
                            id: seekTrack
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 4
                            radius: 2
                            color: root.track

                            Rectangle {
                                width: seekTrack.width * progress.frac
                                height: parent.height
                                radius: 2
                                color: root.accent
                                Behavior on width { NumberAnimation { duration: 900 } }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: root.hasTrack && root.player.canSeek
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: mouse => {
                                root.player.position = (mouse.x / width) * root.player.length
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: root.hasTrack ? root.time(root.player.position) : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 3
                        }
                        Text {
                            text: root.hasTrack ? root.time(root.player.length) : ""
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 3
                        }
                    }
                }

                // --- controles ---
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 22

                    // anterior
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        readonly property bool ok: root.player !== null && root.player.canGoPrevious
                        text: root.glyph(0xF04AE)   // skip_previous
                        color: !ok ? root.border : prevMouse.containsMouse ? root.accent : root.fg
                        font.family: root.iconFont
                        font.pixelSize: 22
                        MouseArea {
                            id: prevMouse
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            enabled: parent.ok
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.player.previous()
                        }
                    }

                    // tocar / pausar (círculo em contorno)
                    Rectangle {
                        width: 46
                        height: 46
                        radius: 23
                        color: playMouse.containsMouse ? root.hover : "transparent"
                        border.width: 1.5
                        border.color: root.accent

                        Text {
                            anchors.centerIn: parent
                            text: root.playing ? root.glyph(0xF03E4) : root.glyph(0xF040A)   // pause / play
                            color: root.accent
                            font.family: root.iconFont
                            font.pixelSize: 24
                        }
                        MouseArea {
                            id: playMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (root.player && root.player.canTogglePlaying) root.player.togglePlaying()
                        }
                    }

                    // próxima
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        readonly property bool ok: root.player !== null && root.player.canGoNext
                        text: root.glyph(0xF04AD)   // skip_next
                        color: !ok ? root.border : nextMouse.containsMouse ? root.accent : root.fg
                        font.family: root.iconFont
                        font.pixelSize: 22
                        MouseArea {
                            id: nextMouse
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            enabled: parent.ok
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.player.next()
                        }
                    }
                }

                // --- outros players (só aparece com mais de um) ---
                Flow {
                    visible: root.players.length > 1
                    Layout.fillWidth: true
                    spacing: 6

                    Repeater {
                        model: root.players

                        Rectangle {
                            id: chip
                            required property var modelData
                            readonly property bool current: modelData === root.player
                            width: chipText.implicitWidth + 20
                            height: 24
                            radius: 12
                            color: chipMouse.containsMouse ? root.hover : "transparent"
                            border.width: 1
                            border.color: current ? root.accent : root.border

                            Text {
                                id: chipText
                                anchors.centerIn: parent
                                text: chip.modelData.identity || "Player"
                                color: chip.current ? root.accent : root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 3
                            }
                            MouseArea {
                                id: chipMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.pinned = chip.modelData
                            }
                        }
                    }
                }
            }
        }
    }
}
