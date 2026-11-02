import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// a color swatch with its hex ("#aarrggbb") and a popup with hue / saturation / lightness / alpha
Item {
    id: cb
    property string value: "#ffffffff"      // Qt form: #AARRGGBB (what hyprctl prints, with a #)
    property bool enabledCb: true
    signal picked(string qt)                // committed
    signal previewed(string qt)             // while a slider moves

    implicitWidth: row.implicitWidth
    implicitHeight: 30
    opacity: enabledCb ? 1 : 0.4

    readonly property color c: value

    RowLayout {
        id: row
        spacing: 6
        height: parent.height
        Rectangle {
            width: 30; height: 24; radius: 6
            border.width: 1; border.color: Ui.overlay
            // checkerboard under translucent colors
            Canvas {
                anchors.fill: parent; anchors.margins: 1
                onPaint: {
                    const ctx = getContext("2d")
                    for (let y = 0; y < height; y += 6) for (let x = 0; x < width; x += 6)
                        { ctx.fillStyle = ((x / 6 + y / 6) % 2 === 0) ? "#bbbbbb" : "#777777"; ctx.fillRect(x, y, 6, 6) }
                }
            }
            Rectangle { anchors.fill: parent; anchors.margins: 1; radius: 5; color: cb.c }
            MouseArea { anchors.fill: parent; enabled: cb.enabledCb; cursorShape: Qt.PointingHandCursor; onClicked: pop.open() }
        }
        UiField {
            Layout.preferredWidth: 104
            mono: true
            enabled: cb.enabledCb
            text: cb.value
            bad: !/^#[0-9a-fA-F]{8}$/.test(text) && !/^#[0-9a-fA-F]{6}$/.test(text)
            onCommitted: v => {
                let t = v.trim().replace(/^#?/, "#")
                if (/^#[0-9a-fA-F]{6}$/.test(t)) t = "#ff" + t.slice(1)
                if (/^#[0-9a-fA-F]{8}$/.test(t)) cb.picked(t.toLowerCase())
            }
        }
    }

    Popup {
        id: pop
        y: cb.height + 4
        width: 300
        padding: 12
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { color: Ui.raised; border.width: 1; border.color: Ui.surface; radius: Ui.cardRadius }

        property real h: 0
        property real s: 0
        property real l: 0
        property real a: 1
        onOpened: { const q = cb.c; h = Math.max(0, q.hslHue); s = q.hslSaturation; l = q.hslLightness; a = q.a }
        function qt() {
            const q = Qt.hsla(h, s, l, a)
            const hx = v => Math.round(v * 255).toString(16).padStart(2, "0")
            return "#" + hx(q.a) + hx(q.r) + hx(q.g) + hx(q.b)
        }
        function live() { cb.previewed(qt()) }
        function done() { cb.picked(qt()) }

        contentItem: ColumnLayout {
            spacing: 8
            Rectangle { Layout.fillWidth: true; height: 28; radius: 6; color: Qt.hsla(pop.h, pop.s, pop.l, pop.a); border.width: 1; border.color: Ui.overlay }
            Repeater {
                model: {
                    const seven = f => [0, 1, 2, 3, 4, 5, 6].map(i => f(i / 6))
                    return [
                        { name: "Hue",        key: "h", stops: seven(x => Qt.hsla(x, 1, 0.5, 1)) },
                        { name: "Saturation", key: "s", stops: seven(x => Qt.hsla(pop.h, x, pop.l, 1)) },
                        { name: "Lightness",  key: "l", stops: seven(x => Qt.hsla(pop.h, pop.s, x, 1)) },
                        { name: "Alpha",      key: "a", stops: seven(x => Qt.hsla(pop.h, pop.s, pop.l, x)) }
                    ]
                }
                ColumnLayout {
                    id: sl
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2
                    RowLayout {
                        Text { text: sl.modelData.name; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; Layout.fillWidth: true }
                        Text { text: (pop[sl.modelData.key] * (sl.modelData.key === "h" ? 360 : 100)).toFixed(0) + (sl.modelData.key === "h" ? "°" : "%"); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    }
                    Item {
                        Layout.fillWidth: true
                        height: 18
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 10; radius: 5
                            border.width: 1; border.color: Ui.surface
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.00; color: sl.modelData.stops[0] }
                                GradientStop { position: 0.17; color: sl.modelData.stops[1] }
                                GradientStop { position: 0.33; color: sl.modelData.stops[2] }
                                GradientStop { position: 0.50; color: sl.modelData.stops[3] }
                                GradientStop { position: 0.67; color: sl.modelData.stops[4] }
                                GradientStop { position: 0.83; color: sl.modelData.stops[5] }
                                GradientStop { position: 1.00; color: sl.modelData.stops[6] }
                            }
                        }
                        Rectangle {
                            width: 14; height: 14; radius: 7
                            x: parent.width * pop[sl.modelData.key] - 7
                            anchors.verticalCenter: parent.verticalCenter
                            color: Qt.hsla(pop.h, pop.s, pop.l, 1)
                            border.width: 2; border.color: Ui.text
                        }
                        MouseArea {
                            anchors.fill: parent
                            function at(mx) { return Math.max(0, Math.min(1, mx / width)) }
                            onPressed: mouse => { pop[sl.modelData.key] = at(mouse.x); pop.live() }
                            onPositionChanged: mouse => { if (pressed) { pop[sl.modelData.key] = at(mouse.x); pop.live() } }
                            onReleased: pop.done()
                        }
                    }
                }
            }
            RowLayout {
                Layout.topMargin: 4
                Text { text: pop.qt(); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; Layout.fillWidth: true }
                UiButton { label: "Done"; small: true; primary: true; onClicked: { pop.done(); pop.close() } }
            }
        }
    }
}
