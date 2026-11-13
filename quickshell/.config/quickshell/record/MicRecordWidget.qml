// MicRecordWidget.qml — microphone recording indicator (Super+R).
// Only visible while recording: pulsing red microphone + time. Click stops and saves.

import QtQuick
import Quickshell
import "../theme"

Item {
    id: root
    visible: MicRecorder.recording
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        spacing: 5
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF036C)   // microphone
            color: Theme.red
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 1
            SequentialAnimation on opacity {
                running: MicRecorder.recording
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: MicRecorder.elapsed
            color: mouse.containsMouse ? Theme.red : Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
            font.features: { "tnum": 1 }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: MicRecorder.stop()
    }
}
