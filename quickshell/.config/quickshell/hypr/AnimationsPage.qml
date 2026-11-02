import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// the animation tree (hyprctl animations) and the curves, both editable
Item {
    id: page

    property bool addingCurve: false
    property var curveDraft: ({ name: "", type: "bezier", x0: 0.25, y0: 0.1, x1: 0.25, y1: 1, mass: 1, stiffness: 200, damping: 20 })

    function animObj(a, changes) {
        const saved = Store.animationSettings(a.name) || {}
        const o = { enabled: a.enabled, speed: a.speed, style: a.style || "" }
        const curve = saved.spring || saved.bezier || a.bezier || ""
        if (curve) { if (springNames.indexOf(curve) !== -1) o.spring = curve; else o.bezier = curve }
        for (const k in changes) o[k] = changes[k]
        if (o.bezier !== undefined && springNames.indexOf(o.bezier) !== -1) { o.spring = o.bezier; delete o.bezier }
        if (o.style === "") delete o.style
        return o
    }
    readonly property var springNames: Object.keys(Store.settings.curves || {}).filter(n => (Store.settings.curves[n] || {}).type === "spring")
    readonly property var curveEntries: [{ label: "(default)", value: "" }].concat(Store.curveNames.map(n => ({ label: n, value: n })))

    function saveCurve() {
        const d = curveDraft
        if (!/^[A-Za-z_][\w-]*$/.test(d.name)) { Store.say("a curve needs a name (letters, digits, _)", true); return }
        const obj = d.type === "spring"
            ? { type: "spring", mass: Number(d.mass), stiffness: Number(d.stiffness), damping: Number(d.damping) }
            : { type: "bezier", points: [[Number(d.x0), Number(d.y0)], [Number(d.x1), Number(d.y1)]] }
        Store.setCurve(d.name, obj)
        addingCurve = false
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12

            // ---------- animations ----------
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: "Animations"
                subtitle: "Each leaf inherits from its parent (global → windows → windowsIn…). A row changed here is saved as hl.animation on top of conf/look.lua."
                headerItems: [ UiSwitch { checked: Store.current["animations:enabled"] === true; onToggled: v => Store.setOption("animations:enabled", v) } ]
                Repeater {
                    model: Store.animations.slice().sort((a, b) => a.name.localeCompare(b.name))
                    RowLayout {
                        id: ar
                        required property var modelData
                        readonly property var a: modelData
                        readonly property bool set: !!Store.animationSettings(a.name)
                        Layout.fillWidth: true
                        spacing: 10
                        Text { Layout.preferredWidth: 150; text: ar.a.name; color: ar.a.overridden ? Ui.text : Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                        UiSwitch { checked: ar.a.enabled; onToggled: v => Store.setAnimation(ar.a.name, page.animObj(ar.a, { enabled: v })) }
                        Text { text: "speed"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiNumber { value: ar.a.speed; min: 0; max: 20; integer: false; step: 0.1
                            onChanged: v => Store.setAnimation(ar.a.name, page.animObj(ar.a, { speed: v })) }
                        Text { text: "curve"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiCombo { Layout.preferredWidth: 150; entries: page.curveEntries; value: (Store.animationSettings(ar.a.name) || {}).spring || ar.a.bezier || ""
                            onPicked: v => Store.setAnimation(ar.a.name, page.animObj(ar.a, { bezier: v })) }
                        Text { text: "style"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiField { Layout.preferredWidth: 130; text: ar.a.style || ""; placeholderText: "slide, popin 80%, fade…"
                            onCommitted: v => Store.setAnimation(ar.a.name, page.animObj(ar.a, { style: v })) }
                        Badge { visible: ar.set; text: "app"; tint: Ui.accent; tip: "saved by this app" }
                        Badge { visible: !ar.set && ar.a.overridden; text: "files"; tint: Ui.subtext; tip: "set in conf/look.lua (not inherited)" }
                        UiButton { icon: "󰦛"; small: true; tooltip: "back to the files"; opacity: ar.set ? 1 : 0; enabledBtn: ar.set; onClicked: Store.resetAnimation(ar.a.name) }
                    }
                }
            }

            // ---------- curves ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Curves"
                subtitle: "Beziers Hyprland knows right now; springs saved here (hl.curve type = spring) are listed too."
                headerItems: [ UiButton { label: "Add curve"; icon: "󰐕"; small: true; onClicked: page.addingCurve = !page.addingCurve } ]
                // new curve
                ColumnLayout {
                    visible: page.addingCurve
                    Layout.fillWidth: true
                    spacing: 8
                    RowLayout {
                        spacing: 8
                        UiField { Layout.preferredWidth: 160; placeholderText: "name"; text: page.curveDraft.name; onTextChanged: page.curveDraft.name = text }
                        UiCombo { entries: [{ label: "bezier", value: "bezier" }, { label: "spring", value: "spring" }]; value: page.curveDraft.type
                            onPicked: v => { const d = Object.assign({}, page.curveDraft); d.type = v; page.curveDraft = d } }
                        Repeater {
                            model: page.curveDraft.type === "spring" ? ["mass", "stiffness", "damping"] : ["x0", "y0", "x1", "y1"]
                            UiField {
                                required property var modelData
                                Layout.preferredWidth: 80; mono: true
                                placeholderText: modelData
                                text: String(page.curveDraft[modelData])
                                onTextChanged: page.curveDraft[modelData] = text
                            }
                        }
                        UiButton { label: "Save"; primary: true; small: true; onClicked: page.saveCurve() }
                    }
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 10
                    Repeater {
                        model: Store.curves
                        Rectangle {
                            id: cv
                            required property var modelData
                            readonly property bool own: modelData.name in (Store.settings.curves || {})
                            width: 200; height: 150; radius: Ui.radius
                            color: Ui.sunken; border.width: 1; border.color: Ui.surface
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    Text { Layout.fillWidth: true; text: cv.modelData.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; font.bold: true; elide: Text.ElideRight }
                                    Badge { visible: cv.own; text: "app"; tint: Ui.accent }
                                    UiButton { visible: cv.own; icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: Store.removeCurve(cv.modelData.name) }
                                }
                                Canvas {
                                    Layout.fillWidth: true; Layout.fillHeight: true
                                    property var pts: [cv.modelData.X0, cv.modelData.Y0, cv.modelData.X1, cv.modelData.Y1]
                                    onPtsChanged: requestPaint()
                                    onPaint: {
                                        const ctx = getContext("2d"), w = width, h = height
                                        ctx.clearRect(0, 0, w, h)
                                        ctx.strokeStyle = Ui.surface; ctx.lineWidth = 1
                                        ctx.strokeRect(0.5, 0.5, w - 1, h - 1)
                                        ctx.strokeStyle = Ui.accent; ctx.lineWidth = 2
                                        ctx.beginPath(); ctx.moveTo(0, h)
                                        ctx.bezierCurveTo(pts[0] * w, h - pts[1] * h, pts[2] * w, h - pts[3] * h, w, 0)
                                        ctx.stroke()
                                    }
                                }
                                RowLayout {
                                    spacing: 3
                                    Repeater {
                                        model: ["X0", "Y0", "X1", "Y1"]
                                        UiField {
                                            required property var modelData
                                            Layout.fillWidth: true; mono: true; implicitHeight: 22; leftPadding: 4; rightPadding: 4
                                            text: H.fmt(cv.modelData[modelData], 0.001)
                                            onCommitted: v => {
                                                const p = { X0: cv.modelData.X0, Y0: cv.modelData.Y0, X1: cv.modelData.X1, Y1: cv.modelData.Y1 }
                                                p[modelData] = Number(v) || 0
                                                Store.setCurve(cv.modelData.name, { type: "bezier", points: [[p.X0, p.Y0], [p.X1, p.Y1]] })
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Repeater {
                        model: page.springNames
                        Rectangle {
                            id: sp
                            required property var modelData
                            readonly property var c: Store.settings.curves[modelData] || ({})
                            width: 200; height: 150; radius: Ui.radius
                            color: Ui.sunken; border.width: 1; border.color: Ui.surface
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    Text { Layout.fillWidth: true; text: sp.modelData + "  (spring)"; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; font.bold: true; elide: Text.ElideRight }
                                    UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: Store.removeCurve(sp.modelData) }
                                }
                                Repeater {
                                    model: ["mass", "stiffness", "damping"]
                                    RowLayout {
                                        required property var modelData
                                        Text { Layout.preferredWidth: 70; text: modelData; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                                        UiField { Layout.fillWidth: true; mono: true; implicitHeight: 22; text: String(sp.c[parent.modelData])
                                            onCommitted: v => { const o = Object.assign({}, sp.c); o[parent.modelData] = Number(v) || 0; Store.setCurve(sp.modelData, o) } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Item { height: 12 }
        }
    }
}
