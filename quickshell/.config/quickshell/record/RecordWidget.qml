// RecordWidget.qml — indicador de gravação de tela na barra.
// Só aparece gravando: ponto vermelho pulsando + tempo. Clique para parar e salvar.

import QtQuick
import Quickshell
import "../theme"

Item {
    id: root
    visible: Recorder.recording
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        spacing: 5
        Text {
            id: dot
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF044A)   // record
            color: Theme.red
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 1
            SequentialAnimation on opacity {
                running: Recorder.recording
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Recorder.elapsed
            color: mouse.containsMouse ? Theme.red : Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
            font.features: { "tnum": 1 }      // números de largura fixa: o tempo não "dança"
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Recorder.stop()
    }
}
