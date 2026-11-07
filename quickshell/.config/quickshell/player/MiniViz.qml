import QtQuick

// a few spectrum bars for the bottom bar (Viz.settings.mini)
Item {
    id: mini
    property int bars: 20
    implicitWidth: 110
    implicitHeight: 28
    onVisibleChanged: Viz.wanted += visible ? 1 : -1
    Component.onCompleted: if (visible) Viz.wanted++
    Component.onDestruction: if (visible) Viz.wanted--

    Canvas {
        id: c
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        Connections { target: Viz; function onFrameChanged() { c.requestPaint() } }
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const b = Viz.bands, n = b.length
            if (!n) return
            const bw = width / mini.bars
            ctx.fillStyle = "rgba(" + Math.round(Ui.accent.r * 255) + "," + Math.round(Ui.accent.g * 255) + "," + Math.round(Ui.accent.b * 255) + ",0.9)"
            for (let i = 0; i < mini.bars; i++) {
                // each bar takes the loudest of its share of the bands
                const from = Math.floor(i * n / mini.bars), to = Math.max(from + 1, Math.floor((i + 1) * n / mini.bars))
                let v = 0
                for (let k = from; k < to; k++) v = Math.max(v, b[k])
                const h = Math.max(2, v * height)
                ctx.fillRect(i * bw + 1, height - h, bw - 2, h)
            }
        }
    }
}
