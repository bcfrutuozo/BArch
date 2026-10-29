// PanelButton.qml — botão em contorno dos painéis da VPN (largura da linha, cor em `tint`).

import QtQuick
import QtQuick.Layouts
import "../theme"

Rectangle {
    id: button
    property string label
    property color tint: Theme.accent
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: 34
    radius: Theme.buttonRadius
    color: mouse.containsMouse ? Theme.hover : "transparent"
    border.width: 1
    border.color: tint

    Text {
        anchors.centerIn: parent
        text: button.label
        color: button.tint
        font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: true
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
