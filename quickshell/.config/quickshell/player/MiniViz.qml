import QtQuick

// a few spectrum bars for the bottom bar (Viz.settings.mini): plain rectangles the scene graph animates
Item {
    id: mini
    property int bars: 20
    implicitWidth: 110
    implicitHeight: 28
    onVisibleChanged: Viz.wanted += visible ? 1 : -1
    Component.onCompleted: if (visible) Viz.wanted++
    Component.onDestruction: if (visible) Viz.wanted--

    Row {
        anchors.fill: parent
        spacing: 2
        Repeater {
            model: mini.bars
            Item {
                required property int index
                width: (mini.width - (mini.bars - 1) * 2) / mini.bars
                height: mini.height
                // each bar takes the loudest of its share of the bands
                readonly property real v: {
                    const b = Viz.bands, n = b.length
                    if (!n) return 0
                    const from = Math.floor(index * n / mini.bars), to = Math.max(from + 1, Math.floor((index + 1) * n / mini.bars))
                    let m = 0
                    for (let k = from; k < to; k++) m = Math.max(m, b[k])
                    return m
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(2, parent.v * parent.height)
                    radius: 1
                    color: Ui.accent
                    opacity: 0.9
                    Behavior on height { NumberAnimation { duration: 70 } }
                }
            }
        }
    }
}
