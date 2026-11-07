import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// a ten-band equalizer (31 Hz to 16 kHz, one octave each, ±12 dB) and a preamp, applied in mpv as a lavfi
// filter chain (Player.eqFilter); presets, on/off, reset. The curve above the sliders is the sum of the bands.
Item {
    id: page
    readonly property var eq: Player.eq
    readonly property var freqs: Player.eqFreqs
    readonly property var presets: Player.eqPresets
    function label(f) { return f >= 1000 ? (f / 1000) + "k" : String(f) }
    function setGain(i, g) { const e = Object.assign({}, eq, { gains: eq.gains.slice() }); e.gains[i] = Math.round(g * 2) / 2; Player.setEq(e, true) }
    function commit() { Player.setEq(eq) }
    readonly property string presetName: { for (const k in presets) if (presets[k].every((g, i) => Math.abs(g - eq.gains[i]) < 0.26)) return k; return "Custom" }

    component VSlider: Item {
        id: vs
        property int band: 0
        property real value: 0
        Layout.fillHeight: true
        Layout.fillWidth: true
        implicitWidth: 44
        readonly property real frac: (value + 12) / 24
        ColumnLayout {
            anchors.fill: parent
            spacing: 6
            Text { Layout.alignment: Qt.AlignHCenter; text: (vs.value > 0 ? "+" : "") + vs.value.toFixed(1); color: Math.abs(vs.value) < 0.3 ? Ui.overlay : Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
            Item {
                id: track
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: 28
                Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 4; height: parent.height; radius: 2; color: Ui.surface }
                Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 28; height: 1; y: parent.height / 2; color: Ui.overlay; opacity: 0.5 }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 4; radius: 2; color: Ui.accent
                    y: Math.min(parent.height / 2, parent.height * (1 - vs.frac))
                    height: Math.abs(parent.height / 2 - parent.height * (1 - vs.frac))
                }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 16; height: 16; radius: 8
                    y: parent.height * (1 - vs.frac) - 8
                    color: Ui.text; border.width: 2; border.color: Ui.accent
                    scale: ma.pressed || ma.containsMouse ? 1.15 : 1
                }
                MouseArea {
                    id: ma
                    anchors.fill: parent; anchors.leftMargin: -8; anchors.rightMargin: -8
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    function at(my) { return Math.max(-12, Math.min(12, (1 - my / height) * 24 - 12)) }
                    onPressed: mouse => page.setGain(vs.band, at(mouse.y))
                    onPositionChanged: mouse => { if (pressed) page.setGain(vs.band, at(mouse.y)) }
                    onReleased: page.commit()
                    onDoubleClicked: { page.setGain(vs.band, 0); page.commit() }
                    onWheel: wheel => { page.setGain(vs.band, vs.value + (wheel.angleDelta.y > 0 ? 0.5 : -0.5)); page.commit() }
                }
            }
            Text { Layout.alignment: Qt.AlignHCenter; text: page.label(page.freqs[vs.band]); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 16; anchors.rightMargin: 16
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            UiSwitch { checked: page.eq.on; onToggled: v => Player.setEq(Object.assign({}, page.eq, { on: v })) }
            Text { text: page.eq.on ? "Equalizer on" : "Equalizer off"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true }
            Text { text: page.presetName; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            Item { Layout.fillWidth: true }
            Text { text: "Preset"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiCombo {
                entries: Object.keys(page.presets).map(k => ({ label: k, value: k })).concat([{ label: "Custom", value: "Custom" }])
                value: page.presetName
                onPicked: v => { if (page.presets[v]) Player.setEq(Object.assign({}, page.eq, { on: true, gains: page.presets[v].slice() })) }
            }
            UiButton { label: "Reset"; icon: "󰁯"; small: true; onClicked: Player.setEq(Object.assign({}, page.eq, { preamp: 0, gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] })) }
        }
        // the curve
        Canvas {
            id: curve
            Layout.fillWidth: true
            Layout.preferredHeight: 110
            Connections { target: page; function onEqChanged() { curve.requestPaint() } }
            Connections { target: Ui; function onAccentChanged() { curve.requestPaint() } }
            onPaint: {
                const ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                const g = page.eq.gains, n = g.length
                const css = (c, a) => "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
                ctx.strokeStyle = css(Ui.overlay, 0.4); ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(0, height / 2); ctx.lineTo(width, height / 2); ctx.stroke()
                // the response: each band a bell one octave wide, summed, on a log-frequency axis
                const pts = 160
                ctx.beginPath()
                for (let p = 0; p <= pts; p++) {
                    const x = p / pts, lf = Math.log2(31) + x * (Math.log2(16000) - Math.log2(31))
                    let y = 0
                    for (let i = 0; i < n; i++) { const d = (lf - Math.log2(page.freqs[i])); y += g[i] * Math.exp(-d * d / (2 * 0.5 * 0.5)) }
                    if (!page.eq.on) y = 0
                    const py = height / 2 - (y / 14) * (height / 2)
                    if (p === 0) ctx.moveTo(x * width, py); else ctx.lineTo(x * width, py)
                }
                ctx.strokeStyle = css(Ui.accent, page.eq.on ? 1 : 0.4); ctx.lineWidth = 2.5; ctx.stroke()
                ctx.lineTo(width, height / 2); ctx.lineTo(0, height / 2); ctx.closePath()
                ctx.fillStyle = css(Ui.accent, page.eq.on ? 0.15 : 0.05); ctx.fill()
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumHeight: 360
            spacing: 4
            opacity: page.eq.on ? 1 : 0.5
            // preamp
            Item {
                Layout.fillHeight: true
                Layout.preferredWidth: 64
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 6
                    Text { Layout.alignment: Qt.AlignHCenter; text: (page.eq.preamp > 0 ? "+" : "") + page.eq.preamp.toFixed(1); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    Item {
                        Layout.fillHeight: true; Layout.alignment: Qt.AlignHCenter; implicitWidth: 28
                        readonly property real frac: (page.eq.preamp + 12) / 24
                        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 4; height: parent.height; radius: 2; color: Ui.surface }
                        Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 16; height: 16; radius: 8; y: parent.height * (1 - parent.frac) - 8; color: Ui.text; border.width: 2; border.color: Ui.yellow }
                        MouseArea {
                            anchors.fill: parent; anchors.leftMargin: -8; anchors.rightMargin: -8
                            cursorShape: Qt.PointingHandCursor
                            function at(my) { return Math.round(Math.max(-12, Math.min(12, (1 - my / height) * 24 - 12)) * 2) / 2 }
                            onPressed: mouse => Player.setEq(Object.assign({}, page.eq, { preamp: at(mouse.y) }), true)
                            onPositionChanged: mouse => { if (pressed) Player.setEq(Object.assign({}, page.eq, { preamp: at(mouse.y) }), true) }
                            onReleased: page.commit()
                            onDoubleClicked: Player.setEq(Object.assign({}, page.eq, { preamp: 0 }))
                        }
                    }
                    Text { Layout.alignment: Qt.AlignHCenter; text: "pre"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface; Layout.topMargin: 20; Layout.bottomMargin: 20 }
            Repeater {
                model: 10
                VSlider { required property int index; band: index; value: page.eq.gains[index] }
            }
        }
        Text {
            Layout.fillWidth: true
            text: "Drag, scroll or double-click a band to zero it. Boosting adds level: lower the preamp by about the largest boost to keep the peaks clean. The chain runs in mpv (lavfi equalizer, one octave per band), so every output gets it, Bluetooth included."
            color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap
        }
    }
}
