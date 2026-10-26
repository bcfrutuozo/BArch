// NotificationCenter.qml — sino da barra + central de notificações.
// Na barra: sino em contorno (riscado no não perturbe) e a quantidade guardada.
// Clique: painel com o histórico (mais novas em cima), Do Not Disturb e Clear All.
// Botão direito no sino: liga/desliga o não perturbe.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "../theme"
import "."

Item {
    id: root

    // Ilha da barra onde o widget está (primeiro ancestral com "radius"); o painel se alinha a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    function glyph(cp) { return String.fromCodePoint(cp) }

    // ---------- na barra ----------
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(Notifs.dnd ? 0xF0A91 : 0xF009C)     // bell_off_outline / bell_outline
            color: Notifs.dnd ? Theme.subtext
                 : popup.visible || barMouse.containsMouse || Notifs.count > 0 ? Theme.accent : Theme.fg
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
        }

        Rectangle {
            visible: Notifs.count > 0
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 16
            implicitWidth: Math.max(16, badge.implicitWidth + 8)
            radius: 8
            color: "transparent"
            border.width: 1
            border.color: Notifs.dnd ? Theme.subtext : Theme.accent
            Text {
                id: badge
                anchors.centerIn: parent
                text: Notifs.count
                color: Notifs.dnd ? Theme.subtext : Theme.accent
                font.family: Theme.font
                font.pixelSize: 10
                font.bold: true
            }
        }
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) Notifs.setDnd(!Notifs.dnd)
            else Popups.toggle(popup)
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
        // canto inferior direito da ilha, popupGap abaixo dela
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 400
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

                // --- cabeçalho ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: "Notifications"
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }

                    // Do Not Disturb
                    Rectangle {
                        implicitWidth: dndRow.implicitWidth + 16
                        implicitHeight: 26
                        radius: 13
                        color: Notifs.dnd ? Theme.accent : (dndMouse.containsMouse ? Theme.hover : "transparent")
                        border.width: Notifs.dnd ? 0 : 1
                        border.color: Theme.border
                        Row {
                            id: dndRow
                            anchors.centerIn: parent
                            spacing: 6
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.glyph(0xF0A91)
                                color: Notifs.dnd ? Theme.crust : Theme.fg
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Do Not Disturb"
                                color: Notifs.dnd ? Theme.crust : Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                                font.bold: Notifs.dnd
                            }
                        }
                        MouseArea {
                            id: dndMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Notifs.setDnd(!Notifs.dnd)
                        }
                    }

                    // Clear All
                    Rectangle {
                        visible: Notifs.count > 0
                        implicitWidth: clearLabel.implicitWidth + 16
                        implicitHeight: 26
                        radius: 13
                        color: clearMouse.containsMouse ? Theme.hover : "transparent"
                        border.width: 1
                        border.color: clearMouse.containsMouse ? Theme.crit : Theme.border
                        Text {
                            id: clearLabel
                            anchors.centerIn: parent
                            text: "Clear All"
                            color: clearMouse.containsMouse ? Theme.crit : Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                        }
                        MouseArea {
                            id: clearMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Notifs.clearAll()
                        }
                    }
                }

                // --- histórico ---
                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 560)
                    visible: count > 0
                    clip: true
                    spacing: 4
                    boundsBehavior: Flickable.StopAtBounds
                    model: ScriptModel { values: Notifs.list.slice().reverse() }

                    delegate: NotificationCard {
                        required property var modelData
                        entry: modelData
                        width: ListView.view.width
                    }

                    remove: Transition {
                        ParallelAnimation {
                            NumberAnimation { property: "x"; to: 400; duration: 180; easing.type: Easing.InCubic }
                            NumberAnimation { property: "opacity"; to: 0; duration: 160 }
                        }
                    }
                    displaced: Transition {
                        NumberAnimation { property: "y"; duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                Text {
                    visible: Notifs.count === 0
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    Layout.bottomMargin: 6
                    horizontalAlignment: Text.AlignHCenter
                    text: Notifs.dnd ? "Do Not Disturb is on" : "No notifications"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                }
            }
        }
    }
}
