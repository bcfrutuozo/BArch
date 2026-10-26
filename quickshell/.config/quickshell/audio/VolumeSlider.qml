// VolumeSlider.qml — controle deslizante usado pelo VolumeWidget.
// Arraste ou clique para definir; roda do mouse ajusta de 5 em 5% (Shift: de 1 em 1%).

import QtQuick

Item {
    id: s

    required property var widget      // o VolumeWidget (cores)
    property real value: 0            // 0..1
    property bool muted: false
    signal moved(real v)

    implicitWidth: 120
    implicitHeight: 18

    readonly property real clamped: Math.max(0, Math.min(1, value))

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 4
        radius: 2
        color: s.widget.track

        Rectangle {
            width: track.width * s.clamped
            height: parent.height
            radius: 2
            color: s.muted ? s.widget.dim : s.widget.accent
            Behavior on color { ColorAnimation { duration: 150 } }
        }
    }

    Rectangle {
        width: 12
        height: 12
        radius: 6
        x: track.width * s.clamped - width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: s.muted ? s.widget.dim : s.widget.fg
        scale: area.pressed || area.containsMouse ? 1.2 : 1
        Behavior on scale { NumberAnimation { duration: 100 } }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.topMargin: -4
        anchors.bottomMargin: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor

        function setFrom(mx) { s.moved(Math.max(0, Math.min(1, mx / width))) }

        onPressed: mouse => setFrom(mouse.x)
        onPositionChanged: mouse => { if (pressed) setFrom(mouse.x) }
        onWheel: wheel => {
            // com Shift, o Qt às vezes manda a rolagem no eixo horizontal
            const d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
            const step = (wheel.modifiers & Qt.ShiftModifier) ? 0.01 : 0.05
            s.moved(Math.max(0, Math.min(1, s.value + (d > 0 ? step : -step))))
        }
    }
}
