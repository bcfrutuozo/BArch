import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// every key bind Hyprland has right now (hyprctl binds), the ones this app added (editable),
// and the ones of the files turned off here (hl.unbind)
Item {
    id: page

    property string filter: ""
    property int editing: -2            // -2 closed, -1 new, >= 0 index in Store.ownBinds
    property var draft: ({})

    function norm(k) { return String(k).toUpperCase().replace(/\s+/g, "") }
    function ownIndex(keys) {
        const k = norm(keys)
        for (let i = 0; i < Store.ownBinds.length; i++) if (norm(Store.ownBinds[i].keys) === k) return i
        return -1
    }
    function startEdit(i) {
        editing = i
        draft = i >= 0 ? H.clone(Store.ownBinds[i]) : { keys: "", command: "", lua: "", description: "" }
        draft.mode = draft.lua ? "lua" : "command"
    }
    function saveDraft() {
        const b = H.clone(draft)
        delete b.mode
        if (draft.mode === "lua") delete b.command; else delete b.lua
        if (!b.keys || (!b.command && !b.lua)) { Store.say("a bind needs keys and a command or dispatcher", true); return }
        const list = Store.ownBinds.slice()
        if (editing >= 0) list[editing] = b; else list.push(b)
        Store.setBinds(list)
        editing = -2
    }
    function removeOwn(i) { const list = Store.ownBinds.slice(); list.splice(i, 1); Store.setBinds(list) }
    function disableFile(keys) { if (Store.unbinds.indexOf(keys) === -1) Store.setUnbinds(Store.unbinds.concat([keys])) }
    function enableFile(keys) { Store.setUnbinds(Store.unbinds.filter(k => k !== keys)) }

    readonly property var rows: {
        const q = filter.trim().toLowerCase()
        const out = []
        for (const b of Store.binds) {
            const keys = H.bindKeys(b)
            const text = (keys + " " + (b.description || "") + " " + H.dispatcherName(b)).toLowerCase()
            if (q && text.indexOf(q) === -1) continue
            out.push({ bind: b, keys: keys, own: ownIndex(keys) })
        }
        out.sort((a, b) => (a.bind.description || "~").localeCompare(b.bind.description || "~"))
        return out
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            UiField { Layout.fillWidth: true; placeholderText: "filter binds (keys, description, dispatcher)"; onTextChanged: page.filter = text }
            UiButton { label: "Add bind"; icon: "󰐕"; primary: true; onClicked: page.startEdit(-1) }
        }

        // ---------- editor ----------
        Card {
            visible: page.editing !== -2
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 12
            title: page.editing >= 0 ? "Edit bind" : "New bind"
            subtitle: "Keys as in the Lua config: SUPER + SHIFT + T, ALT + Tab, XF86AudioPlay, mouse:272. Description \"Group|Name\" puts it in the shortcut sheet (Super+/); group Hidden keeps it out."
            GridLayout {
                columns: 2; columnSpacing: 12; rowSpacing: 8
                Layout.fillWidth: true
                Text { text: "Keys"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                UiField { Layout.fillWidth: true; mono: true; text: page.draft.keys || ""; placeholderText: "SUPER + T"; onTextChanged: page.draft.keys = text }
                Text { text: "Action"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                RowLayout {
                    UiCombo {
                        entries: [{ label: "run a command", value: "command" }, { label: "dispatcher (Lua)", value: "lua" }]
                        value: page.draft.mode || "command"
                        onPicked: v => { const d = Object.assign({}, page.draft); d.mode = v; page.draft = d }
                    }
                    UiField {
                        Layout.fillWidth: true; mono: true
                        text: (page.draft.mode === "lua" ? page.draft.lua : page.draft.command) || ""
                        placeholderText: page.draft.mode === "lua" ? "hl.dsp.window.close()   ·   hl.dsp.focus({ workspace = 3 })" : "foot   ·   qs ipc call launcher toggle"
                        onTextChanged: { if (page.draft.mode === "lua") page.draft.lua = text; else page.draft.command = text }
                    }
                }
                Text { text: "Description"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                UiField { Layout.fillWidth: true; text: page.draft.description || ""; placeholderText: "Apps|Terminal"; onTextChanged: page.draft.description = text }
                Text { text: "Flags"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: H.BIND_FLAGS
                        Rectangle {
                            id: chip
                            required property var modelData
                            readonly property bool on: !!page.draft[modelData.id]
                            width: ct.implicitWidth + 16; height: 24; radius: 12
                            color: on ? Ui.accent : "transparent"
                            border.width: 1; border.color: on ? Ui.accent : Ui.surface
                            Text { id: ct; anchors.centerIn: parent; text: chip.modelData.label; color: chip.on ? Ui.crust : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { const d = Object.assign({}, page.draft); if (chip.on) delete d[chip.modelData.id]; else d[chip.modelData.id] = true; page.draft = d } }
                            Tip { text: chip.modelData.hint; when: cm.containsMouse }
                        }
                    }
                }
            }
            RowLayout {
                Item { Layout.fillWidth: true }
                UiButton { label: "Cancel"; onClicked: page.editing = -2 }
                UiButton { label: "Save & reload"; primary: true; onClicked: page.saveDraft() }
            }
        }

        // ---------- disabled file binds ----------
        Card {
            visible: Store.unbinds.length > 0
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 12
            title: "Turned off"
            subtitle: "binds of conf/binds.lua removed by this app (hl.unbind)"
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: Store.unbinds
                    RowLayout {
                        required property var modelData
                        spacing: 4
                        Text { text: parent.modelData; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        UiButton { label: "enable"; small: true; onClicked: page.enableFile(parent.modelData) }
                    }
                }
            }
        }

        // ---------- the list ----------
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: parent.width
                spacing: 1
                Repeater {
                    model: page.rows
                    Rectangle {
                        id: r
                        required property var modelData
                        readonly property var b: modelData.bind
                        readonly property bool isOwn: modelData.own >= 0
                        Layout.fillWidth: true
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        implicitHeight: 40
                        radius: Ui.radius
                        color: rm.containsMouse ? Ui.faint : "transparent"
                        MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                            spacing: 12
                            Text { Layout.preferredWidth: 230; text: r.modelData.keys; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight }
                            Text { Layout.preferredWidth: 260; text: r.b.description || "—"; color: r.b.description ? Ui.text : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; text: H.dispatcherName(r.b) + (r.isOwn ? "  " + (Store.ownBinds[r.modelData.own].command || Store.ownBinds[r.modelData.own].lua) : ""); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                            Text {
                                text: ["locked", "release", "repeat", "mouse", "longPress", "non_consuming"].filter(f => r.b[f]).join(" · ")
                                color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3
                            }
                            Badge { visible: r.isOwn; text: "app"; tint: Ui.accent; tip: "added by this app" }
                            UiButton { visible: r.isOwn; icon: "󰏫"; small: true; tooltip: "edit"; onClicked: page.startEdit(r.modelData.own) }
                            UiButton { visible: r.isOwn; icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: page.removeOwn(r.modelData.own) }
                            UiButton { visible: !r.isOwn; icon: "󰌾"; small: true; tooltip: "turn this bind off (hl.unbind, kept in settings.json)"; opacity: rm.containsMouse ? 1 : 0; onClicked: page.disableFile(r.modelData.keys) }
                        }
                    }
                }
                Item { height: 16 }
            }
        }
    }
}
