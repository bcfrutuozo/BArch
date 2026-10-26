// DetailRow.qml — linha de detalhe dos widgets de rede.
// Rótulo à esquerda, valor à direita; clique copia o valor.

import QtQuick
import QtQuick.Layouts
import "../theme"

Rectangle {
    id: dr

    // O widget que usa a linha: precisa ter a função copy(label, value)
    required property var widget
    property string label: ""
    property string value: ""
    property string copyValue: value   // o que vai para a área de transferência

    visible: value !== ""
    Layout.fillWidth: true
    implicitHeight: 24
    radius: 6
    color: drMouse.containsMouse ? Theme.hover : "transparent"

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 8

        Text {
            text: dr.label
            Layout.preferredWidth: 78
            font.family: Theme.font
            font.pixelSize: Theme.fontSize - 2
            color: Theme.dim
        }
        Text {
            Layout.fillWidth: true
            text: dr.value
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            font.family: Theme.font
            font.pixelSize: Theme.fontSize - 1
            color: Theme.fg
        }
    }

    MouseArea {
        id: drMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: dr.widget.copy(dr.label, dr.copyValue)
    }
}
