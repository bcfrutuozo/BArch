import QtQuick
import QtQuick.Layouts

// a number: optional slider (bounded ranges) + a field with - / + buttons
RowLayout {
    id: num
    property real value: 0
    property var min: undefined
    property var max: undefined
    property bool integer: true
    property real step: integer ? 1 : 0.01
    property bool enabledNum: true
    signal changed(real v)          // committed (field, buttons, slider release)
    signal dragged(real v)          // slider while dragging

    function fmt(n, step) {
        if (step && step < 1) { const d = Math.max(0, Math.ceil(-Math.log10(step))); return Number(n).toFixed(d).replace(/\.?0+$/, "") }
        return String(n)
    }
    readonly property bool bounded: min !== undefined && max !== undefined && max > min
    readonly property bool sliderOk: bounded && (integer ? (max - min) <= 2000 : true)
    spacing: 8
    opacity: enabledNum ? 1 : 0.4

    function clamp(v) {
        if (isNaN(v)) return value
        if (integer) v = Math.round(v)
        if (min !== undefined) v = Math.max(min, v)
        if (max !== undefined) v = Math.min(max, v)
        return integer ? v : Number(v.toFixed(4))
    }
    UiSlider {
        visible: num.sliderOk
        Layout.preferredWidth: 150
        from: num.min !== undefined ? num.min : 0
        to: num.max !== undefined ? num.max : 1
        step: num.integer ? 1 : 0
        value: num.value
        enabledSl: num.enabledNum
        onMoved: v => num.dragged(num.clamp(v))
        onReleased: v => num.changed(num.clamp(v))
    }
    UiField {
        id: field
        Layout.preferredWidth: 78
        mono: true
        enabled: num.enabledNum
        horizontalAlignment: Text.AlignRight
        text: num.fmt(num.value, num.integer ? 1 : num.step)
        onCommitted: v => { const n = num.clamp(Number(v)); text = num.fmt(n, num.integer ? 1 : num.step); num.changed(n) }
    }
    Column {
        spacing: 2
        Repeater {
            model: [{ t: "󰅃", d: 1 }, { t: "󰅀", d: -1 }]
            Rectangle {
                required property var modelData
                width: 18; height: 13; radius: 4
                color: m.containsMouse ? Ui.surface : "transparent"
                Text { anchors.centerIn: parent; text: parent.modelData.t; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: 11 }
                MouseArea {
                    id: m
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: num.enabledNum
                    onClicked: num.changed(num.clamp(num.value + parent.modelData.d * num.step))
                }
            }
        }
    }
}
