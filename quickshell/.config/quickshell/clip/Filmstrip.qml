// Filmstrip.qml — the trim bar of the iPhone's editor: the video as a strip of frames, a frame in
// the accent color around what is kept, with a grip at each end to drag, the rest dimmed, and a
// playhead that scrubs (the frame above follows). Dragging a grip moves the playhead with it, so
// the cut is seen while it is chosen.
pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: strip
    implicitHeight: 64

    readonly property real grip: 14
    readonly property real pad: grip
    readonly property real span: Math.max(1, width - grip * 2)
    function xOf(t) { return pad + (Store.duration > 0 ? t / Store.duration : 0) * span }
    function tOf(x) { return Store.duration * Math.max(0, Math.min(1, (x - pad) / span)) }

    onWidthChanged: ask.restart()
    Component.onCompleted: ask.restart()
    Timer { id: ask; interval: 150; onTriggered: if (Store.ready) Store.loadStrip(Math.max(8, Math.round(strip.span / 56))) }
    Connections { target: Store; function onReadyChanged() { if (Store.ready) ask.restart() } }

    Rectangle {
        id: film
        x: strip.pad; width: strip.span
        y: 4; height: parent.height - 8
        radius: 6
        color: Ui.sunken
        clip: true
        Image {
            anchors.fill: parent
            source: Store.stripUrl
            cache: false
            asynchronous: true
            fillMode: Image.Stretch
            smooth: true
        }
        // dim what is cut away
        Rectangle { x: 0; width: Math.max(0, strip.xOf(Store.trimStart) - strip.pad); height: parent.height; color: Ui.crust; opacity: 0.7 }
        Rectangle { x: strip.xOf(Store.trimEnd) - strip.pad; width: Math.max(0, parent.width - x); height: parent.height; color: Ui.crust; opacity: 0.7 }
    }
    // the kept range: a frame in the accent color with a grip at each end
    Rectangle {
        id: keep
        x: strip.xOf(Store.trimStart) - strip.grip
        width: strip.xOf(Store.trimEnd) - strip.xOf(Store.trimStart) + strip.grip * 2
        y: 0; height: parent.height
        radius: 7
        color: "transparent"
        border.width: 3
        border.color: Store.trimmed ? Ui.accent : Qt.rgba(Ui.text.r, Ui.text.g, Ui.text.b, 0.5)
        Rectangle {
            x: 0; width: strip.grip; height: parent.height; radius: 7
            color: keep.border.color
            Rectangle { anchors.right: parent.right; width: 7; height: parent.height; color: parent.color }
            Text { anchors.centerIn: parent; text: "󰅁"; color: Ui.crust; font.family: Ui.iconFont; font.pixelSize: 16 }
        }
        Rectangle {
            anchors.right: parent.right; width: strip.grip; height: parent.height; radius: 7
            color: keep.border.color
            Rectangle { anchors.left: parent.left; width: 7; height: parent.height; color: parent.color }
            Text { anchors.centerIn: parent; text: "󰅂"; color: Ui.crust; font.family: Ui.iconFont; font.pixelSize: 16 }
        }
    }
    // the playhead
    Rectangle {
        x: strip.xOf(Store.playhead) - 1.5
        width: 3; y: -3; height: parent.height + 6
        radius: 1.5
        color: "white"
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.5)
        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: -4; width: 9; height: 9; radius: 4.5; color: "white"; border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.5) }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        anchors.topMargin: -6; anchors.bottomMargin: -6
        hoverEnabled: true
        enabled: Store.ready
        property string mode: ""
        cursorShape: {
            const m = pressed ? mode : hit(mouseX)
            return m === "start" || m === "end" ? Qt.SizeHorCursor : Qt.PointingHandCursor
        }
        function hit(mx) {
            const a = strip.xOf(Store.trimStart), b = strip.xOf(Store.trimEnd)
            if (mx >= a - strip.grip - 4 && mx <= a + 4) return "start"
            if (mx >= b - 4 && mx <= b + strip.grip + 4) return "end"
            return "seek"
        }
        function apply(mx) {
            const t = strip.tOf(mx)
            if (mode === "start") { Store.setStart(t); Store.seek(Store.trimStart) }
            else if (mode === "end") { Store.setEnd(t); Store.seek(Store.trimEnd) }
            else Store.seek(t)
        }
        onPressed: mouse => { mode = hit(mouse.x); apply(mouse.x) }
        onPositionChanged: mouse => { if (pressed) apply(mouse.x) }
        onReleased: mode = ""
        onWheel: wheel => Store.step(wheel.angleDelta.y > 0 ? -1 : 1)
    }
    Tip { text: Store.ready ? "Drag the ends to trim, click or drag inside to scrub (wheel: one frame)" : ""; when: area.containsMouse && !area.pressed }
}
