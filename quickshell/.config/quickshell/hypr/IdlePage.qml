import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// hypridle.conf: what happens when the machine idles (lock, screen off, suspend) and around sleep
Item {
    id: page

    readonly property var items: Store.idleItems
    readonly property var general: H.blocksOf(items, "general")[0] || null
    readonly property var listeners: H.blocksOf(items, "listener")

    function edited() { return H.clone(items) }
    function setGeneral(key, value) {
        const it = edited()
        let g = H.blocksOf(it, "general")[0]
        if (!g) { g = { kind: "block", name: "general", items: [] }; it.unshift(g) }
        H.blockSet(g, key, value)
        Store.saveIdle(it)
    }
    function setListener(index, key, value) {
        const it = edited()
        H.blockSet(H.blocksOf(it, "listener")[index], key, value)
        Store.saveIdle(it)
    }
    function addListener(preset) {
        const it = edited()
        const b = { kind: "block", name: "listener", items: [{ kind: "kv", key: "timeout", value: String(preset.timeout) }, { kind: "kv", key: "on-timeout", value: preset.on }] }
        if (preset.resume) b.items.push({ kind: "kv", key: "on-resume", value: preset.resume })
        it.push({ kind: "blank" }, { kind: "comment", text: "# " + preset.label }, b)
        Store.saveIdle(it)
    }
    function removeListener(index) {
        const it = edited()
        const b = H.blocksOf(it, "listener")[index]
        const i = it.indexOf(b)
        it.splice(i, 1)
        // the comment and blank line that introduced it
        while (i > 0 && it[i - 1] && (it[i - 1].kind === "comment" || it[i - 1].kind === "blank")) { if (it[i - 1].kind === "blank" && (i - 2 < 0 || it[i - 2].kind !== "comment")) { it.splice(i - 1, 1); break } it.splice(i - 1, 1); i-- }
        Store.saveIdle(it)
    }
    function listenerComment(b) {
        const i = items.indexOf(b)
        for (let k = i - 1; k >= 0; k--) { if (items[k].kind === "comment") return items[k].text.replace(/^#\s*/, ""); if (items[k].kind !== "blank") break }
        return ""
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
                text: "hypridle.conf, edited in place (blocks and comments kept). Every change restarts hypridle. Timeouts count from the last input; a listener's on-resume runs at the first input after it fired."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
            }

            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: "General"
                subtitle: "lock, sleep and inhibitors"
                headerItems: [ UiButton { icon: "󰏫"; small: true; tooltip: "open the file"; onClicked: Store.openFile(Store.idlePath) } ]
                Repeater {
                    model: H.IDLE_GENERAL
                    RowLayout {
                        id: gr
                        required property var modelData
                        readonly property var value: page.general ? H.blockGet(page.general, modelData.key) : undefined
                        spacing: 8
                        Text {
                            Layout.preferredWidth: 190
                            text: gr.modelData.key; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1
                            MouseArea { id: gm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            Tip { text: gr.modelData.hint; when: gm.containsMouse }
                        }
                        UiSwitch { visible: !!gr.modelData.bool; checked: gr.value === "true"; onToggled: v => page.setGeneral(gr.modelData.key, v ? "true" : "") }
                        UiField { visible: !gr.modelData.bool; Layout.fillWidth: true; mono: true; text: gr.value === undefined ? "" : gr.value; placeholderText: gr.modelData.hint; onCommitted: v => page.setGeneral(gr.modelData.key, v) }
                        Item { visible: !!gr.modelData.bool; Layout.fillWidth: true }
                    }
                }
            }

            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Listeners"
                subtitle: "one block per timeout, in order"
                headerItems: [
                    UiCombo {
                        id: preset
                        Layout.preferredWidth: 230
                        entries: [{ label: "add a listener…", value: "" }].concat(H.IDLE_PRESETS.map((p, i) => ({ label: p.label + "  (" + H.humanSeconds(p.timeout) + ")", value: String(i) })))
                        value: ""
                        onPicked: v => { if (v !== "") { page.addListener(H.IDLE_PRESETS[Number(v)]); preset.value = "" } }
                    }
                ]
                Repeater {
                    model: page.listeners
                    Rectangle {
                        id: lc
                        required property int index
                        required property var modelData
                        readonly property var b: modelData
                        readonly property string timeout: H.blockGet(b, "timeout") || "0"
                        Layout.fillWidth: true
                        implicitHeight: col.implicitHeight + 20
                        radius: Ui.radius
                        color: Ui.sunken
                        border.width: 1; border.color: Ui.surface
                        ColumnLayout {
                            id: col
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                            spacing: 6
                            RowLayout {
                                spacing: 8
                                Text { text: "after"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                                UiNumber { value: Number(lc.timeout); min: 1; max: 86400; onChanged: v => page.setListener(lc.index, "timeout", String(v)) }
                                Text { text: "s  =  " + H.humanSeconds(lc.timeout); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
                                Text { Layout.fillWidth: true; text: page.listenerComment(lc.b); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight }
                                UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove this listener"; onClicked: page.removeListener(lc.index) }
                            }
                            RowLayout {
                                spacing: 8
                                Text { Layout.preferredWidth: 90; text: "on-timeout"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                                UiField { Layout.fillWidth: true; mono: true; text: H.blockGet(lc.b, "on-timeout") || ""; placeholderText: "command"; onCommitted: v => page.setListener(lc.index, "on-timeout", v) }
                            }
                            RowLayout {
                                spacing: 8
                                Text { Layout.preferredWidth: 90; text: "on-resume"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                                UiField { Layout.fillWidth: true; mono: true; text: H.blockGet(lc.b, "on-resume") || ""; placeholderText: "command at the first input after it fired (optional)"; onCommitted: v => page.setListener(lc.index, "on-resume", v) }
                                Text { text: "ignore inhibit"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                                UiSwitch { checked: H.blockGet(lc.b, "ignore_inhibit") === "true"; onToggled: v => page.setListener(lc.index, "ignore_inhibit", v ? "true" : "") }
                            }
                        }
                    }
                }
                Text { visible: page.listeners.length === 0; text: "no listeners: nothing happens when idle"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
            Item { height: 12 }
        }
    }
}
