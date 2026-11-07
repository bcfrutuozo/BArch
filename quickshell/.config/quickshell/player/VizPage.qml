import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

// the spectrum of what plays, drawn on the GPU: the bands go into a one-pixel-high texture (a row of
// rectangles the scene graph animates between frames, so the picture is smooth at the display's rate, not
// at viz.py's), viz.frag draws bars, mirror, wave, radial or dots from it, in the palette's colors, over the
// cover if wanted; trails feed the previous frame back into the shader
Item {
    id: page
    property bool active: false            // the window shows this page
    onActiveChanged: Viz.wanted += active ? 1 : -1
    readonly property var s: Viz.settings
    readonly property var t: Player.current
    readonly property var album: t ? Store.albumByKey[t.albumKey] : null
    readonly property int n: Viz.bandCount
    readonly property var modes: ["bars", "mirror", "wave", "radial", "dots"]

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

            // the spectrum as a texture: one rectangle per band, its grey the level, eased between frames
            Row {
                id: bandRow
                width: page.n
                height: 1
                visible: false
                Repeater {
                    model: page.n
                    Rectangle {
                        required property int index
                        width: 1; height: 1
                        readonly property real v: index < Viz.bands.length ? Viz.bands[index] : 0
                        color: Qt.rgba(v, v, v, 1)
                        Behavior on color { ColorAnimation { duration: 70 } }
                    }
                }
            }
            ShaderEffectSource {
                id: bandTex
                sourceItem: bandRow
                live: true
                hideSource: true
                textureSize: Qt.size(page.n, 1)
                smooth: true
                wrapMode: ShaderEffectSource.ClampToEdge
            }
            ShaderEffectSource {
                id: feedback
                sourceItem: effect
                live: page.s.trails
                recursive: true
                hideSource: false
                smooth: true
            }
            ShaderEffect {
                id: effect
                anchors.fill: parent
                visible: Player.hasTrack
                property variant bands: bandTex
                property variant prev: page.s.trails ? feedback : null
                property real aspect: width / Math.max(1, height)
                property real bandsN: page.n
                property real mode: Math.max(0, page.modes.indexOf(page.s.mode))
                property real colorMode: page.s.color === "accent" ? 1 : page.s.color === "heat" ? 2 : 0
                property real decay: page.s.trails ? 0.86 : 0
                property real level: Viz.level
                Behavior on level { NumberAnimation { duration: 70 } }
                property real time: 0
                property color c0: Ui.accent
                property color c1: Ui.green
                property color c2: Ui.yellow
                property color c3: Ui.red
                fragmentShader: Qt.resolvedUrl("viz.frag.qsb")
                onStatusChanged: if (status === ShaderEffect.Error) console.warn("viz shader:", log)
            }
            // the cover in the middle of the radial mode
            Cover {
                visible: page.s.mode === "radial" && Player.hasTrack
                anchors.centerIn: parent
                album: page.album
                size: Math.round(Math.min(stage.width, stage.height) * 0.4)
                radius: size / 2
                scale: 1 + Viz.level * 0.025
                Behavior on scale { NumberAnimation { duration: 70 } }
            }
            Text {
                anchors.centerIn: parent
                visible: !Player.hasTrack
                text: "Play something to see it."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2
            }
        }
    }
}
