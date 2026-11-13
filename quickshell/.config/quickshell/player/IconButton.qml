pragma ComponentBehavior: Bound
import QtQuick

// a round icon button for the transport and the rows
Item {
    id: btn
    property string icon: ""
    property int size: 30
    property int glyphSize: Ui.fontSize + 4
    property bool active: false        // painted in the accent (shuffle on, liked)
    property bool primary: false       // filled (play/pause)
    property bool enabledBtn: true
    property string tooltip: ""
    property color tint: Ui.text
    signal clicked()

    implicitWidth: size
    implicitHeight: size
    opacity: enabledBtn ? 1 : 0.35

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: btn.primary ? Ui.accent : (m.containsMouse ? Ui.surface : "transparent")
        Behavior on color { ColorAnimation { duration: 100 } }
    }
    Text {
        anchors.centerIn: parent
        text: btn.icon
        color: btn.primary ? Ui.crust : (btn.active ? Ui.accent : (m.containsMouse ? Ui.text : btn.tint))
        font.family: Ui.iconFont
        font.pixelSize: btn.glyphSize
        Behavior on color { ColorAnimation { duration: 100 } }
    }
    MouseArea {
        id: m
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabledBtn
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
    Tip { text: btn.tooltip; when: m.containsMouse }
}
