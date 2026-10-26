// PrivacyWidget.qml — indicador de microfone, câmera e tela em uso.
// Na barra: só aparece quando algo está em uso; um ícone por recurso
// (microfone em amarelo, câmera em verde, tela em vermelho).
// Clique: painel com os apps que estão usando cada um.
// Depende do privacy-info.sh (nesta pasta): pipewire (pw-dump) e jq.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    // Ilha da barra onde o widget está (primeiro ancestral com "radius"); o painel se alinha a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property int interval: 3000

    property var mic: []
    property var cam: []
    property var shared: []
    readonly property bool anyActive: mic.length + cam.length + shared.length > 0

    readonly property var kinds: [
        { key: "mic",    glyph: 0xF036E, label: "Microphone", color: Theme.warn },   // microphone_outline
        { key: "cam",    glyph: 0xF0D5D, label: "Camera",     color: Theme.good },   // camera_outline
        { key: "screen", glyph: 0xF1483, label: "Screen",     color: Theme.crit }    // monitor_share
    ]
    function appsOf(key) { return key === "mic" ? mic : key === "cam" ? cam : shared }

    function glyph(cp) { return String.fromCodePoint(cp) }

    Process {
        id: proc
        command: ["bash", Quickshell.shellDir + "/privacy/privacy-info.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text)
                    root.mic = d.mic || []
                    root.cam = d.cam || []
                    root.shared = d.screen || []
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: root.interval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!proc.running) proc.running = true
    }

    onAnyActiveChanged: if (!anyActive) Popups.hide(popup)

    // ---------- na barra ----------
    visible: anyActive
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Repeater {
            model: root.kinds
            Text {
                required property var modelData
                visible: root.appsOf(modelData.key).length > 0
                text: root.glyph(modelData.glyph)
                color: modelData.color
                font.family: Theme.iconFont
                font.pixelSize: Theme.fontSize + 2
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.PointingHandCursor
        onClicked: Popups.toggle(popup)
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
        // canto inferior direito da ilha, popupGap abaixo dela
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

        HyprlandFocusGrab {
            windows: [popup]
            active: popup.visible
            onCleared: Popups.hide(popup)
        }

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
                spacing: 10

                Text {
                    text: "Privacy"
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                Repeater {
                    model: root.kinds

                    RowLayout {
                        id: kindRow
                        required property var modelData
                        readonly property var apps: root.appsOf(modelData.key)
                        visible: apps.length > 0
                        Layout.fillWidth: true
                        spacing: 12

                        Text {
                            Layout.alignment: Qt.AlignTop
                            text: root.glyph(kindRow.modelData.glyph)
                            color: kindRow.modelData.color
                            font.family: Theme.iconFont
                            font.pixelSize: Theme.fontSize + 4
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text {
                                text: kindRow.modelData.label
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 1
                                font.bold: true
                            }
                            Text {
                                Layout.fillWidth: true
                                text: kindRow.modelData.key === "screen" ? "Being shared"
                                      : kindRow.apps.join(", ")
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }
            }
        }
    }
}
