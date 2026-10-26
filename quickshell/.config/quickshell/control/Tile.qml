// Tile.qml — bloco de liga/desliga da central de controle (em contorno, coerente com o OLED).

import QtQuick
import QtQuick.Layouts
import "../theme"

Rectangle {
    id: tile

    property string icon: ""
    property string label: ""
    property string sublabel: ""
    property bool active: false
    property bool available: true
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: 58
    radius: Theme.cardRadius
    color: mouse.containsMouse && available ? Theme.hover : "transparent"
    border.width: active ? 1.5 : 1
    border.color: active ? Theme.accent : Theme.border
    opacity: available ? 1 : 0.45
    Behavior on border.color { ColorAnimation { duration: 150 } }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 12

        Text {
            text: tile.icon
            color: tile.active ? Theme.accent : Theme.fg
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 6
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
                Layout.fillWidth: true
                text: tile.label
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 1
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: tile.sublabel
                color: tile.active ? Theme.accent : Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 3
                elide: Text.ElideRight
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: tile.available
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.clicked()
    }
}
