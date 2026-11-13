pragma ComponentBehavior: Bound
import QtQuick

// a bar chart on a Canvas, one bar per bucket of time: points = [{ t, v }], `kind` says what a bucket
// is (hour, day, week, month) for the labels, `format` (v => text) writes the axis and the readout.
// One series (the card's title names it); the bar under the pointer is read out at the top.
// `markT` draws a dashed line at a moment with `markLabel` (where the data begins: the buckets before
// it are not zero, they are unknown).
Item {
    id: bars
    property var points: []
    property string kind: "day"
    property color tint: Ui.accent
    property var format: null
    property string emptyText: "nothing in this range"
    property real markT: NaN
    property string markLabel: ""
    implicitHeight: 190

    readonly property real padL: 58
    readonly property real padR: 10
    readonly property real padT: 18
    readonly property real padB: 22
    property int hover: -1

    readonly property real peak: {
        let hi = 0
        for (const p of points) if (p.v > hi) hi = p.v
        return hi
    }
    onPointsChanged: { hover = -1; canvas.requestPaint() }
    onTintChanged: canvas.requestPaint()
    onHoverChanged: canvas.requestPaint()
    onMarkTChanged: canvas.requestPaint()
    Connections { target: Ui; function onThemeChanged() { canvas.requestPaint() } }

    function css(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + (a === undefined ? c.a : a) + ")" }
    function fmt(v) { return format ? format(v) : (Math.abs(v) >= 100 ? String(Math.round(v)) : v.toFixed(1)) }
    function label(t, long) {
        const d = new Date(t * 1000)
        if (kind === "hour") return Qt.formatDateTime(d, long ? "dd/MM HH:00" : "HH:00")
        if (kind === "month") return Qt.formatDateTime(d, "MMM yyyy")
        return (long && kind === "week" ? "week of " : "") + Qt.formatDateTime(d, "dd/MM")
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            const n = bars.points.length
            const w = width - bars.padL - bars.padR, h = height - bars.padT - bars.padB
            ctx.font = "10px '" + Ui.font + "'"
            ctx.textBaseline = "middle"
            if (!n || w <= 0 || h <= 0) {
                ctx.fillStyle = bars.css(Ui.overlay)
                ctx.textAlign = "center"
                ctx.fillText("loading…", width / 2, height / 2)
                return
            }
            const hi = (bars.peak > 0 ? bars.peak : 1) * 1.08
            const y = v => bars.padT + (1 - v / hi) * h
            // grid + y labels (recessive)
            ctx.strokeStyle = bars.css(Ui.text, 0.08)
            ctx.fillStyle = bars.css(Ui.subtext)
            ctx.textAlign = "right"
            ctx.lineWidth = 1
            for (let i = 0; i <= 4; i++) {
                const v = hi * i / 4
                const yy = Math.round(y(v)) + 0.5
                ctx.beginPath(); ctx.moveTo(bars.padL, yy); ctx.lineTo(width - bars.padR, yy); ctx.stroke()
                if (bars.peak > 0 || i === 0) ctx.fillText(bars.fmt(bars.peak > 0 ? v : 0), bars.padL - 6, yy)
            }
            if (bars.peak <= 0) {
                ctx.fillStyle = bars.css(Ui.overlay)
                ctx.textAlign = "center"
                ctx.fillText(bars.emptyText, bars.padL + w / 2, bars.padT + h / 2)
            }
            // bars: a 2 px gap between neighbours, rounded at the data end, square on the baseline
            const slot = w / n
            const bw = Math.max(1, Math.min(slot - 2, 26))
            const base = bars.padT + h
            // where the data begins: inside the bucket that holds that moment
            if (!isNaN(bars.markT) && bars.markT > bars.points[0].t) {
                let i = n - 1
                while (i > 0 && bars.points[i].t > bars.markT) i--
                const len = i < n - 1 ? bars.points[i + 1].t - bars.points[i].t : (n > 1 ? bars.points[i].t - bars.points[i - 1].t : 3600)
                const mx = Math.round(bars.padL + slot * (i + Math.min(1, (bars.markT - bars.points[i].t) / len))) + 0.5
                ctx.save()
                ctx.strokeStyle = bars.css(Ui.text, 0.3)
                ctx.setLineDash([3, 3])
                ctx.beginPath(); ctx.moveTo(mx, bars.padT); ctx.lineTo(mx, base); ctx.stroke()
                ctx.restore()
                ctx.fillStyle = bars.css(Ui.overlay)
                ctx.textAlign = mx > bars.padL + w / 2 ? "right" : "left"
                ctx.fillText(bars.markLabel, mx + (mx > bars.padL + w / 2 ? -6 : 6), bars.padT + 8)
            }
            for (let i = 0; i < n; i++) {
                const v = bars.points[i].v
                if (!(v > 0)) continue
                const x = bars.padL + slot * i + (slot - bw) / 2
                const top = Math.min(y(v), base - 1)
                const r = Math.min(4, bw / 2, base - top)
                ctx.fillStyle = bars.css(bars.tint, bars.hover === -1 || bars.hover === i ? 1 : 0.45)
                ctx.beginPath()
                ctx.moveTo(x, base); ctx.lineTo(x, top + r)
                ctx.arcTo(x, top, x + r, top, r); ctx.lineTo(x + bw - r, top)
                ctx.arcTo(x + bw, top, x + bw, top + r, r); ctx.lineTo(x + bw, base)
                ctx.closePath(); ctx.fill()
            }
            // x labels: as many as fit
            ctx.fillStyle = bars.css(Ui.subtext)
            ctx.textAlign = "center"
            const every = Math.max(1, Math.ceil(n / Math.max(1, Math.floor(w / 62))))
            for (let i = 0; i < n; i += every) ctx.fillText(bars.label(bars.points[i].t, false), bars.padL + slot * (i + 0.5), height - bars.padB / 2)
            // readout of the bar under the pointer
            if (bars.hover >= 0 && bars.hover < n) {
                const p = bars.points[bars.hover]
                const cx = bars.padL + slot * (bars.hover + 0.5)
                ctx.fillStyle = bars.css(Ui.text)
                ctx.textAlign = cx > width * 0.7 ? "right" : cx < width * 0.3 ? "left" : "center"
                ctx.fillText(bars.label(p.t, true) + "   " + bars.fmt(p.v), cx, bars.padT / 2)
            }
        }
    }
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: m => {
            const n = bars.points.length, w = width - bars.padL - bars.padR
            const i = n && w > 0 ? Math.floor((m.x - bars.padL) / (w / n)) : -1
            bars.hover = i >= 0 && i < n ? i : -1
        }
        onExited: bars.hover = -1
    }
}
