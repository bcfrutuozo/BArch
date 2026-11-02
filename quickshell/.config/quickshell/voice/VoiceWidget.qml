// VoiceWidget.qml — o microfone do controle por voz na barra: só aparece com o serviço
// barch-voice ligado. Apagado enquanto só escuta, na cor de destaque pulsando quando ouviu
// "barch" e espera a frase, fixo enquanto entende ou pergunta ao Claude, verde enquanto fala,
// vermelho quando falta algo (whisper.cpp, microfone). Ao lado, por alguns segundos, o que
// entendeu. Clique pausa e retoma a escuta; botão direito abre um painel com a última frase e a
// resposta, pausa e desligar. Estado no singleton Voice (voice/Voice.qml).

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }
    function glyph(cp) { return String.fromCodePoint(cp) }

    visible: Voice.running
    onVisibleChanged: if (!visible) Popups.hide(popup)
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    // a frase entendida fica visível 5 s depois de cada mudança
    property bool showHeard: false
    Timer { id: hide; interval: 5000; onTriggered: root.showHeard = false }
    Connections {
        target: Voice
        function onChangedChanged() {
            if (Voice.heard !== "" && (Voice.state === "processing" || Voice.state === "thinking" || Voice.state === "speaking" || Voice.state === "listening")) {
                root.showHeard = Voice.heard !== ""
                hide.restart()
            }
        }
    }

    readonly property color tone: Voice.degraded ? Theme.red
                                : Voice.paused ? Theme.overlay
                                : Voice.speaking ? Theme.good
                                : Voice.awake ? Theme.accent
                                : Theme.subtext

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5
        Text {
            id: mic
            anchors.verticalCenter: parent.verticalCenter
            text: Voice.paused ? root.glyph(0xF036D) : Voice.degraded ? root.glyph(0xF036D) : root.glyph(0xF036C)   // microphone_off / microphone
            color: root.tone
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
            SequentialAnimation on opacity {
                running: Voice.state === "wake" || Voice.state === "hearing" || Voice.state === "followup"; loops: Animation.Infinite
                NumberAnimation { to: Voice.state === "followup" ? 0.55 : 0.25; duration: Voice.state === "followup" ? 900 : 500 }
                NumberAnimation { to: 1; duration: Voice.state === "followup" ? 900 : 500 }
                onRunningChanged: if (!running) mic.opacity = 1
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: Voice.state === "wake" ? "listening…"
                : Voice.state === "thinking" ? "asking Claude…"
                : root.showHeard ? Voice.heard : ""
            color: Theme.subtext
            font.family: Theme.font
            font.pixelSize: Theme.fontSize - 1
            elide: Text.ElideRight
            width: Math.min(implicitWidth, 260)
        }
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) Popups.toggle(popup)
            else Voice.togglePause()
        }
    }

    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 300
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        HyprlandFocusGrab { windows: [popup]; active: popup.visible; onCleared: Popups.hide(popup) }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    spacing: 10
                    Text {
                        text: mic.text
                        color: root.tone
                        font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 6
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: "Voice control"
                            color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: true
                        }
                        Text {
                            text: Voice.label + (Voice.model ? "  ·  " + Voice.model.replace(/^ggml-|\.bin$/g, "") : "")
                            color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }
                Repeater {
                    model: [
                        { k: "Heard", v: Voice.heard || "—" },
                        { k: "Said", v: Voice.said || "—" }
                    ]
                    ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 0
                        Text { text: parent.modelData.k; color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3 }
                        Text {
                            text: parent.modelData.v; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                            wrapMode: Text.Wrap; Layout.fillWidth: true; maximumLineCount: 3; elide: Text.ElideRight
                        }
                    }
                }
                Text {
                    visible: !Voice.tts
                    text: "piper-tts not installed: answers go to notifications"
                    color: Theme.warn; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { label: Voice.paused ? "Resume" : "Pause", act: () => Voice.togglePause() },
                            { label: "Turn off", act: () => { Popups.hide(popup); Voice.stop() } }
                        ]
                        Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 30
                            radius: 8
                            color: bm.containsMouse ? Theme.hover : "transparent"
                            border.color: Theme.border; border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData.label
                                color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                            }
                            MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; onClicked: parent.modelData.act() }
                        }
                    }
                }
            }
        }
    }
}
