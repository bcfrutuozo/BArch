// DialogButton.qml — botão do diálogo polkit (primary: preenchido com a cor de destaque).

import QtQuick
import "../theme"

Rectangle {
    id: button
    property string label
    property bool primary: false
    signal clicked()

    implicitWidth: lbl.implicitWidth + 28
    implicitHeight: 32
    radius: 10
    color: primary ? Theme.accent : mouse.containsMouse ? Theme.surface : "transparent"
    border.width: primary ? 0 : 1
    border.color: Theme.border

    Text {
        id: lbl
        anchors.centerIn: parent
        text: button.label
        color: button.primary ? Theme.crust : Theme.text
        font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: button.primary
    }
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: button.clicked() }
}
