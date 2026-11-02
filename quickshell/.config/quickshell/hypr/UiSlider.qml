import QtQuick

// a slider for a bounded number; `moved` while dragging, `released` at the end
Item {
    id: s
    property real from: 0
    property real to: 1
    property real step: 0
    property real value: 0
    property bool enabledSl: true
    signal moved(real v)
    signal released(real v)

    implicitWidth: 140
    implicitHeight: 20
    opacity: enabledSl ? 1 : 0.4

    readonly property real frac: to > from ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0

    function snap(v) {
        if (step > 0) v = Math.round(v / step) * step
        return Math.max(from, Math.min(to, v))
    }
    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 4
        radius: 2
        color: Ui.surface
        Rectangle { width: track.width * s.frac; height: parent.height; radius: 2; color: Ui.accent }
    }
    Rectangle {
        width: 14; height: 14; radius: 7
        x: track.width * s.frac - width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: Ui.text
        border.width: 2
        border.color: Ui.accent
        scale: area.pressed || area.containsMouse ? 1.15 : 1
        Behavior on scale { NumberAnimation { duration: 80 } }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        anchors.topMargin: -4; anchors.bottomMargin: -4
        hoverEnabled: true
        enabled: s.enabledSl
        cursorShape: Qt.PointingHandCursor
        function at(mx) { return s.snap(s.from + Math.max(0, Math.min(1, mx / width)) * (s.to - s.from)) }
        onPressed: mouse => s.moved(at(mouse.x))
        onPositionChanged: mouse => { if (pressed) s.moved(at(mouse.x)) }
        onReleased: mouse => s.released(at(mouse.x))
        onWheel: wheel => {
            const st = s.step > 0 ? s.step : (s.to - s.from) / 100
            const v = s.snap(s.value + (wheel.angleDelta.y > 0 ? st : -st))
            s.moved(v); s.released(v)
        }
    }
}
