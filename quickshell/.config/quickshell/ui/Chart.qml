import QtQuick
import QtQuick.Layouts

// a line chart on a Canvas: series = [{ label, color, points: [{ t, v }] }], theme colors, hover readout.
// `format` (v => text) replaces the number + unit of the axis and the readout (bytes, rates).
Item {
    id: chart
    property var series: []
    property string unit: ""
    property real fixedMin: NaN          // set both to pin the y axis (percentages: 0..100)
    property real fixedMax: NaN
    property int decimals: 1
    property var format: null
    implicitHeight: 190

    property real padL: 46
    readonly property real padR: 10
    readonly property real padT: 8
    readonly property real padB: 22
    property int hoverX: -1

    readonly property var bounds: {
        let lo = Infinity, hi = -Infinity, t0 = Infinity, t1 = -Infinity
        for (const s of series) for (const p of (s.points || [])) {
            if (p.v < lo) lo = p.v
            if (p.v > hi) hi = p.v
            if (p.t < t0) t0 = p.t
            if (p.t > t1) t1 = p.t
        }
        if (!isFinite(lo)) return null
        if (!isNaN(fixedMin) && !isNaN(fixedMax)) { lo = fixedMin; hi = fixedMax }
        else {
            const span = (hi - lo) || Math.max(1, Math.abs(hi) * 0.1)
            lo = lo - span * 0.08; hi = hi + span * 0.08
            if (lo < 0 && Math.min(...series.map(s => Math.min(...(s.points || []).map(p => p.v)))) >= 0) lo = 0
        }
        if (t1 === t0) t1 = t0 + 60
        return { lo: lo, hi: hi, t0: t0, t1: t1 }
    }
    onSeriesChanged: canvas.requestPaint()
    onBoundsChanged: canvas.requestPaint()
    onHoverXChanged: canvas.requestPaint()
    Connections { target: Ui; function onThemeChanged() { canvas.requestPaint() } }

    function css(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + (a === undefined ? c.a : a) + ")" }
    function fmt(v) {
        if (v === undefined || v === null) return ""
        if (format) return format(v)
        return (Math.abs(v) >= 100 ? Math.round(v) : v.toFixed(decimals)) + (unit ? " " + unit : "")
    }
    function timeLabel(t, span) {
        const d = new Date(t * 1000)
        return span > 2 * 86400 ? Qt.formatDateTime(d, "dd/MM") : Qt.formatDateTime(d, "HH:mm")
    }
    function nearest(s, t) {
        const pts = s.points || []
        if (!pts.length) return null
        let best = pts[0]
        for (const p of pts) if (Math.abs(p.t - t) < Math.abs(best.t - t)) best = p
        return best
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            const b = chart.bounds
            const w = width - chart.padL - chart.padR, h = height - chart.padT - chart.padB
            ctx.font = "10px '" + Ui.font + "'"
            ctx.textBaseline = "middle"
            if (!b || w <= 0 || h <= 0) {
                ctx.fillStyle = chart.css(Ui.overlay)
                ctx.textAlign = "center"
                ctx.fillText(chart.series.length ? "no data in this range" : "loading…", width / 2, height / 2)
                return
            }
            const x = t => chart.padL + (t - b.t0) / (b.t1 - b.t0) * w
            const y = v => chart.padT + (1 - (v - b.lo) / (b.hi - b.lo)) * h
            // grid + y labels
            ctx.strokeStyle = chart.css(Ui.text, 0.08)
            ctx.fillStyle = chart.css(Ui.subtext)
            ctx.textAlign = "right"
            ctx.lineWidth = 1
            for (let i = 0; i <= 4; i++) {
                const v = b.lo + (b.hi - b.lo) * i / 4
                const yy = Math.round(y(v)) + 0.5
                ctx.beginPath(); ctx.moveTo(chart.padL, yy); ctx.lineTo(width - chart.padR, yy); ctx.stroke()
                ctx.fillText(chart.fmt(v), chart.padL - 6, yy)
            }
            // x labels
            ctx.textAlign = "center"
            const span = b.t1 - b.t0
            for (let i = 0; i <= 5; i++) {
                const t = b.t0 + span * i / 5
                ctx.textAlign = i === 5 ? "right" : "center"       // the last one would be cut by the edge
                ctx.fillText(chart.timeLabel(t, span), x(t) + (i === 5 ? chart.padR : 0), height - chart.padB / 2)
            }
            // series
            for (const s of chart.series) {
                const pts = (s.points || []).filter(p => p.v !== null && p.v !== undefined)
                if (!pts.length) continue
                const col = s.color || Ui.accent
                ctx.strokeStyle = chart.css(col)
                ctx.lineWidth = 1.6
                ctx.lineJoin = "round"
                ctx.beginPath()
                pts.forEach((p, i) => { if (i === 0) ctx.moveTo(x(p.t), y(p.v)); else ctx.lineTo(x(p.t), y(p.v)) })
                ctx.stroke()
                if (pts.length === 1) {                       // one sample is a dot, not an invisible line
                    ctx.fillStyle = chart.css(col)
                    ctx.beginPath(); ctx.arc(x(pts[0].t), y(pts[0].v), 3, 0, 2 * Math.PI); ctx.fill()
                } else if (chart.series.length === 1) {
                    ctx.lineTo(x(pts[pts.length - 1].t), chart.padT + h)
                    ctx.lineTo(x(pts[0].t), chart.padT + h)
                    ctx.closePath()
                    ctx.fillStyle = chart.css(col, 0.12)
                    ctx.fill()
                }
            }
            // hover
            if (chart.hoverX >= chart.padL && chart.hoverX <= width - chart.padR) {
                const t = b.t0 + (chart.hoverX - chart.padL) / w * (b.t1 - b.t0)
                ctx.strokeStyle = chart.css(Ui.text, 0.25)
                ctx.beginPath(); ctx.moveTo(chart.hoverX + 0.5, chart.padT); ctx.lineTo(chart.hoverX + 0.5, chart.padT + h); ctx.stroke()
                let line = chart.timeLabel(t, 0) + (span > 2 * 86400 ? " " + chart.timeLabel(t, span * 2) : "")
                let i = 0
                for (const s of chart.series) {
                    const p = chart.nearest(s, t)
                    if (!p) continue
                    ctx.fillStyle = chart.css(s.color || Ui.accent)
                    ctx.beginPath(); ctx.arc(x(p.t), y(p.v), 3, 0, 2 * Math.PI); ctx.fill()
                    line += "   " + (s.label ? s.label + " " : "") + chart.fmt(p.v)
                    i++
                }
                ctx.fillStyle = chart.css(Ui.text)
                ctx.textAlign = chart.hoverX > width / 2 ? "right" : "left"
                ctx.fillText(line, chart.hoverX + (chart.hoverX > width / 2 ? -8 : 8), chart.padT + 8)
            }
        }
    }
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: m => chart.hoverX = m.x
        onExited: chart.hoverX = -1
    }
}
