import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// input devices (hyprctl devices) with per-device settings (hl.device)
Item {
    id: page

    readonly property var list: {
        const out = []
        const d = Store.devices || {}
        for (const m of d.mice || []) out.push({ kind: "mouse", name: m.name, info: "speed " + m.defaultSpeed + "  ·  scroll factor " + m.scrollFactor })
        for (const k of d.keyboards || []) out.push({ kind: "keyboard", name: k.name, info: (k.active_keymap || "") + (k.layout ? "  ·  " + k.layout + (k.variant ? " (" + k.variant + ")" : "") : "") + (k.main ? "  ·  main" : "") })
        for (const t of d.tablets || []) out.push({ kind: "tablet", name: t.name, info: "" })
        for (const t of d.touch || []) out.push({ kind: "touch", name: t.name, info: "" })
        for (const s of d.switches || []) out.push({ kind: "switch", name: s.name, info: "" })
        for (const n in (Store.settings.devices || {})) if (!out.some(x => x.name === n)) out.push({ kind: "not connected", name: n, info: "" })
        return out
    }
    readonly property var fieldEntries: H.DEVICE_FIELDS.map(f => ({ label: f.id, value: f.id }))
    function fieldOf(id) { return H.DEVICE_FIELDS.filter(f => f.id === id)[0] || { id: id, kind: "string" } }
    function fromFiles() {
        const out = []
        for (const path of Store.fileNames) for (const c of H.findCalls(Store.files[path], "hl.device")) out.push({ file: Store.shortPath(path), line: c.line, spec: H.parseLuaTable(c.args) })
        return out
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12
            Text {
                Layout.margins: 12; Layout.bottomMargin: 0; Layout.fillWidth: true
                text: "Per-device settings (hl.device) win over the input section. Pick a field to set it; a field left empty is forgotten."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
            }
            Repeater {
                model: page.list
                Card {
                    id: card
                    required property var modelData
                    readonly property string name: modelData.name
                    readonly property var saved: Store.deviceSettings(name)
                    readonly property var setFields: Object.keys(saved)
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    title: name
                    subtitle: modelData.kind + (modelData.info ? "  ·  " + modelData.info : "")
                    headerItems: [
                        UiCombo { id: adder; Layout.preferredWidth: 200; entries: [{ label: "add a setting…", value: "" }].concat(page.fieldEntries.filter(e => card.setFields.indexOf(e.value) === -1)); value: ""
                            onPicked: v => { if (v) { const f = page.fieldOf(v); Store.setDevice(card.name, v, f.kind === "bool" ? true : f.kind === "int" || f.kind === "float" ? (f.min || 0) : ""); adder.value = "" } } }
                    ]
                    Repeater {
                        model: card.setFields
                        RowLayout {
                            id: fr
                            required property var modelData
                            readonly property var f: page.fieldOf(modelData)
                            readonly property var value: card.saved[modelData]
                            spacing: 8
                            Text { Layout.preferredWidth: 180; text: fr.modelData; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                            Loader {
                                Layout.fillWidth: true
                                sourceComponent: fr.f.kind === "bool" ? boolC : (fr.f.kind === "int" || fr.f.kind === "float") ? numC : fr.f.kind === "choice" ? choiceC : textC
                                Component { id: boolC; UiSwitch { checked: fr.value === true; onToggled: v => Store.setDevice(card.name, fr.modelData, v) } }
                                Component { id: numC; UiNumber { value: Number(fr.value) || 0; min: fr.f.min; max: fr.f.max; integer: fr.f.kind === "int"; step: fr.f.step || (fr.f.kind === "int" ? 1 : 0.01)
                                    onChanged: v => Store.setDevice(card.name, fr.modelData, v) } }
                                Component { id: choiceC; UiCombo { editable: true; entries: fr.f.choices.map(c => ({ label: c === "" ? "(empty)" : c, value: c })); value: String(fr.value)
                                    onPicked: v => Store.setDevice(card.name, fr.modelData, String(v)) } }
                                Component { id: textC; UiField { text: String(fr.value); onCommitted: v => Store.setDevice(card.name, fr.modelData, v) } }
                            }
                            UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "forget"; onClicked: Store.resetDeviceField(card.name, fr.modelData) }
                        }
                    }
                }
            }
            Text { visible: page.fromFiles().length > 0; Layout.leftMargin: 12; text: "hl.device in the files (read-only)"; color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
            Repeater {
                model: page.fromFiles()
                Card {
                    id: fd
                    required property var modelData
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    title: (modelData.spec.name || "?") + "   ·   " + modelData.file + ":" + modelData.line
                    subtitle: Object.keys(modelData.spec).filter(k => k !== "name").map(k => k + " = " + JSON.stringify(modelData.spec[k])).join("  ·  ")
                    headerItems: [ UiButton { icon: "󰏫"; small: true; tooltip: "open the file"; onClicked: Store.openFile(Store.hyprDir + "/" + fd.modelData.file) } ]
                }
            }
            Item { height: 12 }
        }
    }
}
