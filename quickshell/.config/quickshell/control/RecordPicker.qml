// RecordPicker.qml — what to record (Record tile): full screen or a region.
// Part of the Control Center's panel (ControlCenter.qml), shown while its tile is chosen.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../theme"
import "../record"

RowLayout {
    id: picker
    // the Control Center (control/ControlCenter.qml) whose state it shows and sets
    required property var center
    visible: picker.center.chooseRecord && !Recorder.recording
    Layout.fillWidth: true
    spacing: 8
    Repeater {
        model: [
            { mode: "full",   icon: 0xF0379, label: "Full Screen" },   // monitor
            { mode: "region", icon: 0xF0A6D, label: "Region" }        // selection_drag
        ]
        Rectangle {
            id: opt
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: 36
            radius: Theme.buttonRadius
            color: optMouse.containsMouse ? Theme.hover : "transparent"
            border.width: 1
            border.color: Theme.accent
            Row {
                anchors.centerIn: parent
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: picker.center.glyph(opt.modelData.icon)
                    color: Theme.accent
                    font.family: Theme.iconFont
                    font.pixelSize: Theme.fontSize + 2
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: opt.modelData.label
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                }
            }
            MouseArea {
                id: optMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: picker.center.record(opt.modelData.mode)
            }
        }
    }
}
