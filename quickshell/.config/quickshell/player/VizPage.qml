import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

// the spectrum of what plays, drawn five ways (bars, mirror, wave, radial, dots), in the palette's colors,
// over the cover if wanted; sensitivity, bands, trails and the small version in the bottom bar are settings
Item {
    id: page
    property bool active: false            // the window shows this page
    onActiveChanged: Viz.wanted += active ? 1 : -1
    readonly property var s: Viz.settings
    readonly property var t: Player.current
    readonly property var album: t ? Store.albumByKey[t.albumKey] : null
    property var peaks: []                 // falling peak marks (dots mode)

    function colorFor(i, n, v) {
        const mode = s.color
        if (mode === "accent") return Ui.accent
        if (mode === "heat") return v < 0.5 ? mix(Ui.accent, Ui.yellow, v * 2) : mix(Ui.yellow, Ui.red, (v - 0.5) * 2)
        const x = n > 1 ? i / (n - 1) : 0           // palette: accent -> green -> yellow -> red across the bands
        return x < 1 / 3 ? mix(Ui.accent, Ui.green, x * 3) : x < 2 / 3 ? mix(Ui.green, Ui.yellow, (x - 1 / 3) * 3) : mix(Ui.yellow, Ui.red, (x - 2 / 3) * 3)
    }
    function mix(a, b, f) { f = Math.max(0, Math.min(1, f)); return Qt.rgba(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 1) }
    function css(c, alpha) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + (alpha === undefined ? 1 : alpha) + ")" }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16
            spacing: 10
            Text { text: page.t ? page.t.title + "  ·  " + page.t.artist : "Nothing playing"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
            Text { text: "Mode"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiCombo {
                entries: [{ label: "Bars", value: "bars" }, { label: "Mirror", value: "mirror" }, { label: "Wave", value: "wave" }, { label: "Radial", value: "radial" }, { label: "Dots", value: "dots" }]
                value: page.s.mode; onPicked: v => Viz.set("mode", v)
            }
            Text { text: "Bands"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiCombo {
                entries: [{ label: "24", value: 24 }, { label: "32", value: 32 }, { label: "48", value: 48 }, { label: "64", value: 64 }, { label: "96", value: 96 }, { label: "128", value: 128 }]
                value: page.s.bands; onPicked: v => Viz.set("bands", parseInt(v))
            }
            Text { text: "Color"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiCombo {
                entries: [{ label: "Palette", value: "palette" }, { label: "Accent", value: "accent" }, { label: "Heat", value: "heat" }]
                value: page.s.color; onPicked: v => Viz.set("color", v)
            }
            Text { text: "Sensitivity"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiSlider { Layout.preferredWidth: 110; from: 35; to: 90; step: 1; value: page.s.sensitivity; onMoved: v => Viz.set("sensitivity", v); onReleased: v => Viz.set("sensitivity", v) }
            Text { text: "Cover"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiSwitch { checked: page.s.cover; onToggled: v => Viz.set("cover", v) }
            Text { text: "Trails"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiSwitch { checked: page.s.trails; onToggled: v => Viz.set("trails", v) }
            Text { text: "In the bar"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiSwitch { checked: page.s.mini; onToggled: v => Viz.set("mini", v) }
        }
        Rectangle {
            id: stage
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 12
            radius: Ui.cardRadius
            color: Ui.sunken
            clip: true

            // the cover, blurred, as the ground
            Image {
                id: bg
                anchors.fill: parent
                source: page.s.cover ? Store.coverUrl(page.album) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: false
                sourceSize.width: 400; sourceSize.height: 400
            }
            MultiEffect {
                anchors.fill: parent
                source: bg
                visible: page.s.cover && bg.status === Image.Ready
                blurEnabled: true
                blur: 1.0
                blurMax: 64
                opacity: Ui.dark ? 0.45 : 0.35
                saturation: 0.2
            }
            Canvas {
                id: canvas
                anchors.fill: parent
                renderStrategy: Canvas.Cooperative
                Connections { target: Viz; function onFrameChanged() { canvas.requestPaint() } }
                onPaint: {
                    const ctx = getContext("2d")
                    const w = width, h = height
                    const b = Viz.bands, n = b.length
                    if (page.s.trails) {
                        ctx.globalCompositeOperation = "destination-out"
                        ctx.fillStyle = "rgba(0,0,0,0.22)"
                        ctx.fillRect(0, 0, w, h)
                        ctx.globalCompositeOperation = "source-over"
                    } else ctx.clearRect(0, 0, w, h)
                    if (!n) return
                    const mode = page.s.mode
                    const pad = 24
                    if (mode === "bars" || mode === "mirror") {
                        const gap = n > 64 ? 1 : 2
                        const bw = (w - pad * 2) / n
                        for (let i = 0; i < n; i++) {
                            const v = b[i]
                            const c = page.colorFor(i, n, v)
                            ctx.fillStyle = page.css(c, 0.95)
                            const x = pad + i * bw
                            if (mode === "bars") {
                                const bh = Math.max(2, v * (h - pad * 2))
                                page.roundRect(ctx, x + gap / 2, h - pad - bh, bw - gap, bh, Math.min(4, bw / 2))
                            } else {
                                const bh = Math.max(1, v * (h / 2 - pad))
                                page.roundRect(ctx, x + gap / 2, h / 2 - bh, bw - gap, bh * 2, Math.min(4, bw / 2))
                            }
                        }
                    } else if (mode === "wave") {
                        const step = (w - pad * 2) / (n - 1)
                        const amp = h / 2 - pad
                        for (const side of [1, -1]) {
                            ctx.beginPath()
                            ctx.moveTo(pad, h / 2)
                            for (let i = 0; i < n; i++) {
                                const x = pad + i * step, y = h / 2 - side * b[i] * amp
                                if (i === 0) ctx.lineTo(x, y)
                                else { const px = pad + (i - 1) * step, py = h / 2 - side * b[i - 1] * amp; ctx.quadraticCurveTo(px, py, (px + x) / 2, (py + y) / 2) }
                            }
                            ctx.lineTo(pad + (n - 1) * step, h / 2)
                            ctx.closePath()
                            const g = ctx.createLinearGradient(0, h / 2 - side * amp, 0, h / 2)
                            g.addColorStop(0, page.css(page.colorFor(n - 1, n, 1), 0.85))
                            g.addColorStop(1, page.css(page.colorFor(0, n, 0), 0.25))
                            ctx.fillStyle = g
                            ctx.fill()
                            ctx.strokeStyle = page.css(Ui.accent, 0.9); ctx.lineWidth = 2; ctx.stroke()
                        }
                    } else if (mode === "radial") {
                        const cx = w / 2, cy = h / 2
                        const r0 = Math.min(w, h) * 0.2, rmax = Math.min(w, h) * 0.46 - r0
                        const bw = Math.max(1.5, (2 * Math.PI * r0) / n - 2)
                        ctx.lineCap = "round"
                        for (let i = 0; i < n; i++) {
                            const v = b[i], a = -Math.PI / 2 + (i / n) * 2 * Math.PI
                            const len = 4 + v * rmax
                            ctx.strokeStyle = page.css(page.colorFor(i, n, v), 0.95)
                            ctx.lineWidth = bw
                            ctx.beginPath()
                            ctx.moveTo(cx + Math.cos(a) * (r0 + 6), cy + Math.sin(a) * (r0 + 6))
                            ctx.lineTo(cx + Math.cos(a) * (r0 + 6 + len), cy + Math.sin(a) * (r0 + 6 + len))
                            ctx.stroke()
                        }
                        ctx.strokeStyle = page.css(Ui.accent, 0.5 + Viz.level * 0.5); ctx.lineWidth = 2
                        ctx.beginPath(); ctx.arc(cx, cy, r0 + 2 + Viz.level * 6, 0, 2 * Math.PI); ctx.stroke()
                    } else {       // dots with falling peaks
                        if (page.peaks.length !== n) page.peaks = new Array(n).fill(0)
                        const bw = (w - pad * 2) / n
                        for (let i = 0; i < n; i++) {
                            const v = b[i]
                            page.peaks[i] = v >= page.peaks[i] ? v : Math.max(v, page.peaks[i] - 0.012)
                            const x = pad + i * bw + bw / 2
                            const rr = Math.max(1.5, Math.min(bw / 2 - 1, 3 + v * 5))
                            ctx.fillStyle = page.css(page.colorFor(i, n, v), 0.95)
                            for (let k = 0; k <= Math.floor(v * 24); k++) {
                                ctx.beginPath(); ctx.arc(x, h - pad - k * ((h - pad * 2) / 24), rr * 0.8, 0, 2 * Math.PI); ctx.fill()
                            }
                            ctx.fillStyle = page.css(Ui.text, 0.9)
                            ctx.beginPath(); ctx.arc(x, h - pad - page.peaks[i] * (h - pad * 2), rr, 0, 2 * Math.PI); ctx.fill()
                        }
                    }
                }
            }
            // the cover in the middle of the radial mode
            Cover {
                visible: page.s.mode === "radial"
                anchors.centerIn: parent
                album: page.album
                size: Math.round(Math.min(stage.width, stage.height) * 0.4)
                radius: size / 2
                scale: 1 + Viz.level * 0.03
            }
            Text {
                anchors.centerIn: parent
                visible: !Player.hasTrack
                text: "Play something to see it."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2
            }
        }
    }
    function roundRect(ctx, x, y, w, h, r) {
        r = Math.min(r, w / 2, h / 2)
        ctx.beginPath()
        ctx.moveTo(x + r, y); ctx.lineTo(x + w - r, y); ctx.quadraticCurveTo(x + w, y, x + w, y + r)
        ctx.lineTo(x + w, y + h - r); ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
        ctx.lineTo(x + r, y + h); ctx.quadraticCurveTo(x, y + h, x, y + h - r)
        ctx.lineTo(x, y + r); ctx.quadraticCurveTo(x, y, x + r, y)
        ctx.closePath(); ctx.fill()
    }
}
