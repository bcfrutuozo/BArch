import QtQuick

// a button in the style of the bar
Rectangle {
    id: btn
    property string label: ""
    property string icon: ""         // Nerd Font glyph
    property bool primary: false
    property bool danger: false
    property bool enabledBtn: true
    property bool small: false
    property string tooltip: ""
    signal clicked()

    implicitWidth: row.implicitWidth + (small ? 16 : 24)
    implicitHeight: small ? 24 : 30
    radius: Ui.radius
    opacity: enabledBtn ? 1 : 0.4
    color: primary ? Ui.accent : danger ? (mouse.containsMouse ? Ui.red : "transparent") : (mouse.containsMouse ? Ui.surface : "transparent")
    border.width: primary ? 0 : 1
    border.color: danger ? Ui.red : Ui.surface

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Text {
            visible: btn.icon !== ""
            text: btn.icon
            color: btn.primary ? Ui.crust : (btn.danger ? (mouse.containsMouse ? Ui.crust : Ui.red) : Ui.text)
            font.family: Ui.iconFont
            font.pixelSize: Ui.fontSize + 1
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: btn.label !== ""
            text: btn.label
            color: btn.primary ? Ui.crust : (btn.danger ? (mouse.containsMouse ? Ui.crust : Ui.red) : Ui.text)
            font.family: Ui.font
            font.pixelSize: btn.small ? Ui.fontSize - 1 : Ui.fontSize
            font.bold: btn.primary
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabledBtn
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
    Tip { text: btn.tooltip; when: mouse.containsMouse }
}
