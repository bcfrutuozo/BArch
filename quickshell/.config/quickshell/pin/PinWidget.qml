// PinWidget.qml — indicador de janelas "sempre por cima" (Super+Shift+P).
// Aparece só quando há janela fixada: alfinete + quantidade. Passar o mouse lista as janelas;
// clique desafixa todas (as que estavam no tiling voltam para ele).

import QtQuick
import Quickshell
import "../theme"

Item {
    id: root
    visible: Pinned.windows.length > 0
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        spacing: 3
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(mouse.containsMouse ? 0xF0930 : 0xF0931)   // pin_off_outline / pin_outline
            color: mouse.containsMouse ? Theme.accent : Theme.fg
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
        }
        Text {
            visible: Pinned.windows.length > 1
            anchors.verticalCenter: parent.verticalCenter
            text: Pinned.windows.length
            color: Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Pinned.unpinAll()
    }

    PopupWindow {
        visible: mouse.containsMouse
        anchor.item: root
        anchor.rect.x: root.width / 2
        anchor.rect.y: root.height + 14
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Bottom
        implicitWidth: Math.min(380, col.implicitWidth + 24)
        implicitHeight: col.implicitHeight + 16
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            radius: Theme.buttonRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            Column {
                id: col
                anchors.centerIn: parent
                spacing: 3
                Repeater {
                    model: Pinned.windows
                    Text {
                        required property var modelData
                        width: Math.min(implicitWidth, 350)
                        text: modelData.title
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 2
                        elide: Text.ElideRight
                    }
                }
                Text {
                    text: "Click to unpin all"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 3
                }
            }
        }
    }
}
