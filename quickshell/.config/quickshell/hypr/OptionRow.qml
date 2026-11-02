import QtQuick
import QtQuick.Layouts
import "hypr.js" as H

// one option: name, description, the editor its type asks for, and where it comes from
Rectangle {
    id: row
    required property var opt            // Store.options entry
    property bool showSection: false     // search results: prefix the section

    readonly property var cur: Store.current[opt.name]
    readonly property bool overridden: opt.name in Store.overrides
    readonly property bool isDefault: Store.isDefault(opt.name)
    readonly property bool locked: opt.themed
    readonly property var sources: Store.optionSource(opt.name)

    Layout.fillWidth: true
    implicitHeight: content.implicitHeight + 20
    radius: Ui.cardRadius
    color: hover.containsMouse ? Ui.faint : "transparent"

    MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

    RowLayout {
        id: content
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
        spacing: 16

        // ---------- name + description ----------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 220
            spacing: 3
            RowLayout {
                spacing: 8
                Text {
                    text: (row.showSection ? row.opt.section + (row.opt.group ? " › " + row.opt.group : "") + " › " : "") + row.opt.key
                    color: Ui.text
                    font.family: Ui.monoFont
                    font.pixelSize: Ui.fontSize
                    font.bold: true
                }
                Badge { visible: row.overridden; text: "app"; tint: Ui.accent; tip: "value saved by this app (settings.json)" }
                Badge { visible: !row.overridden && !row.isDefault; text: "files"; tint: Ui.subtext; tip: "set by your conf/*.lua" + (row.sources.length ? ": " + row.sources.join(", ") : "") }
                Badge { visible: row.locked; text: "theme"; tint: Ui.yellow; tip: "applied by the bar from the palette in use (theme/Theme.qml); change it in the palette editor" }
            }
            Text {
                Layout.fillWidth: true
                text: row.opt.desc
                color: Ui.subtext
                font.family: Ui.font
                font.pixelSize: Ui.fontSize - 1
                wrapMode: Text.Wrap
            }
            Text {
                visible: row.opt.kind !== "bool" || !row.isDefault
                text: "default: " + H.valueText(row.opt.kind, row.opt.def) + (row.sources.length && !row.overridden ? "   ·   " + row.sources.join(", ") : "")
                color: Ui.overlay
                font.family: Ui.monoFont
                font.pixelSize: Ui.fontSize - 3
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        // ---------- the editor ----------
        Loader {
            id: editor
            Layout.alignment: Qt.AlignVCenter
            sourceComponent: {
                switch (row.opt.kind) {
                case "bool": return boolComp
                case "int": return row.opt.map.length ? enumComp : numberComp
                case "float": return numberComp
                case "color": return colorComp
                case "gradient": return gradientComp
                case "gaps": return gapsComp
                case "vec2": return vec2Comp
                default: return row.opt.choices.length ? choiceComp : stringComp
                }
            }
        }

        // ---------- reset ----------
        UiButton {
            icon: "󰦛"
            small: true
            tooltip: row.overridden ? "back to what the files set" : (row.isDefault ? "" : "set Hyprland's default")
            enabledBtn: row.overridden || (!row.isDefault && !row.locked)
            opacity: enabledBtn ? 1 : 0
            onClicked: row.overridden ? Store.resetOption(row.opt.name) : Store.setOption(row.opt.name, row.opt.def)
        }
    }

    function set(v) { Store.setOption(opt.name, v) }

    Component {
        id: boolComp
        UiSwitch { checked: row.cur === true; enabledSw: !row.locked; onToggled: v => row.set(v) }
    }
    Component {
        id: enumComp
        UiCombo { entries: row.opt.map; value: row.cur; enabled: !row.locked; onPicked: v => row.set(v) }
    }
    Component {
        id: numberComp
        UiNumber {
            value: Number(row.cur)
            min: row.opt.min; max: row.opt.max
            integer: row.opt.kind === "int"
            enabledNum: !row.locked
            onChanged: v => row.set(v)
            onDragged: v => Store.setOption(row.opt.name, v)
        }
    }
    Component {
        id: choiceComp
        UiCombo {
            editable: true
            entries: row.opt.choices.map(c => ({ label: c, value: c }))
            value: H.displayString(row.cur)
            enabled: !row.locked
            onPicked: v => row.set(String(v))
        }
    }
    Component {
        id: stringComp
        UiField {
            implicitWidth: 260
            text: H.displayString(row.cur)
            placeholderText: "empty"
            enabled: !row.locked
            onCommitted: v => row.set(v)
        }
    }
    Component {
        id: colorComp
        RowLayout {
            spacing: 8
            readonly property bool unset: String(row.cur) === "-1"
            ColorButton {
                visible: !parent.unset
                value: H.HEX8.test(String(row.cur)) ? H.argbToQt(String(row.cur)) : "#ffffffff"
                enabledCb: !row.locked
                onPicked: q => row.set(H.qtToRgba(q))
                onPreviewed: q => row.set(H.qtToRgba(q))
            }
            Text { visible: parent.unset; text: "inherits"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiButton { visible: parent.unset; label: "set"; small: true; onClicked: row.set("rgba(ffffffff)") }
            UiButton { visible: !parent.unset && String(row.opt.def) === "-1"; label: "inherit"; small: true; onClicked: row.set(-1) }
        }
    }
    Component {
        id: gradientComp
        ColumnLayout {
            id: g
            spacing: 6
            property var grad: H.parseGradient(String(row.cur))
            Connections { target: row; function onCurChanged() { g.grad = H.parseGradient(String(row.cur)) } }
            function push(live) {
                const v = H.gradientValue(grad)
                Store.setOption(row.opt.name, v)
            }
            RowLayout {
                spacing: 6
                Repeater {
                    model: g.grad.colors
                    ColorButton {
                        required property int index
                        required property var modelData
                        value: modelData
                        enabledCb: !row.locked
                        onPicked: q => { const c = g.grad.colors.slice(); c[index] = q; g.grad = { colors: c, angle: g.grad.angle }; g.push() }
                        onPreviewed: q => { const c = g.grad.colors.slice(); c[index] = q; g.grad = { colors: c, angle: g.grad.angle }; g.push() }
                    }
                }
            }
            RowLayout {
                spacing: 6
                UiButton { icon: "󰐕"; small: true; tooltip: "add a stop"; enabledBtn: !row.locked && g.grad.colors.length < 10
                    onClicked: { const c = g.grad.colors.slice(); c.push(c[c.length - 1]); g.grad = { colors: c, angle: g.grad.angle }; g.push() } }
                UiButton { icon: "󰍴"; small: true; tooltip: "remove the last stop"; enabledBtn: !row.locked && g.grad.colors.length > 1
                    onClicked: { const c = g.grad.colors.slice(0, -1); g.grad = { colors: c, angle: g.grad.angle }; g.push() } }
                Text { text: "angle"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                UiNumber { value: g.grad.angle; min: 0; max: 360; enabledNum: !row.locked
                    onChanged: v => { g.grad = { colors: g.grad.colors, angle: v }; g.push() }
                    onDragged: v => { g.grad = { colors: g.grad.colors, angle: v }; g.push() } }
            }
        }
    }
    Component {
        id: gapsComp
        RowLayout {
            id: gaps
            spacing: 6
            property var p: H.parseGaps(String(row.cur))
            property bool linked: p[0] === p[1] && p[1] === p[2] && p[2] === p[3]
            Connections { target: row; function onCurChanged() { gaps.p = H.parseGaps(String(row.cur)) } }
            Repeater {
                model: ["top", "right", "bottom", "left"]
                UiField {
                    required property int index
                    required property var modelData
                    visible: index === 0 || !gaps.linked
                    implicitWidth: 56
                    mono: true
                    horizontalAlignment: Text.AlignRight
                    text: String(gaps.p[index])
                    placeholderText: modelData
                    enabled: !row.locked
                    onCommitted: v => {
                        const n = Math.max(0, parseInt(v, 10) || 0)
                        const q = gaps.p.slice()
                        if (gaps.linked) q[0] = q[1] = q[2] = q[3] = n; else q[index] = n
                        gaps.p = q
                        row.set(H.gapsValue(q))
                    }
                }
            }
            UiButton {
                icon: gaps.linked ? "󰌾" : "󰌿"
                small: true
                tooltip: gaps.linked ? "one value for all sides (click: top right bottom left)" : "four values (click: make them equal)"
                enabledBtn: !row.locked
                onClicked: { if (!gaps.linked) { const q = [gaps.p[0], gaps.p[0], gaps.p[0], gaps.p[0]]; gaps.p = q; row.set(H.gapsValue(q)) } else gaps.linked = false }
            }
        }
    }
    Component {
        id: vec2Comp
        RowLayout {
            id: vec
            spacing: 6
            property var p: Array.isArray(row.cur) ? row.cur : [0, 0]
            Repeater {
                model: ["x", "y"]
                UiField {
                    required property int index
                    required property var modelData
                    implicitWidth: 64
                    mono: true
                    horizontalAlignment: Text.AlignRight
                    text: String(vec.p[index])
                    placeholderText: modelData
                    enabled: !row.locked
                    onCommitted: v => { const q = vec.p.slice(); q[index] = Number(v) || 0; row.set(q) }
                }
            }
        }
    }
}
