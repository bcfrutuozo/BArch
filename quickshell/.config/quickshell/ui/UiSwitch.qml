import QtQuick

// an on/off switch
Item {
    id: sw
    property bool checked: false
    property bool enabledSw: true
    signal toggled(bool value)

    implicitWidth: 40
    implicitHeight: 22
    opacity: enabledSw ? 1 : 0.4

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: sw.checked ? Ui.accent : Ui.surface
        border.width: 1
        border.color: sw.checked ? Ui.accent : Ui.overlay
        Behavior on color { ColorAnimation { duration: 120 } }
        Rectangle {
            width: 16; height: 16; radius: 8
            y: 3
            x: sw.checked ? parent.width - width - 3 : 3
            color: sw.checked ? Ui.crust : Ui.text
            Behavior on x { NumberAnimation { duration: 120 } }
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: sw.enabledSw
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled(!sw.checked)
    }
}
