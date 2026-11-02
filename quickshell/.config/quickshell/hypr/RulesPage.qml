import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// window, layer and workspace rules: the app's (editable, settings.json) and the files' (read-only)
Item {
    id: page

    property string kind: "window"     // window | layer | workspace
    readonly property var kinds: [
        { id: "window",    label: "Window rules",    key: "window_rules",    fn: "hl.window_rule",    matchKeys: H.WINDOW_MATCH_KEYS, ruleKeys: H.WINDOW_RULE_KEYS },
        { id: "layer",     label: "Layer rules",     key: "layer_rules",     fn: "hl.layer_rule",     matchKeys: H.LAYER_MATCH_KEYS,  ruleKeys: H.LAYER_RULE_KEYS },
        { id: "workspace", label: "Workspace rules", key: "workspace_rules", fn: "hl.workspace_rule", matchKeys: [],                  ruleKeys: H.WORKSPACE_RULE_KEYS }
    ]
    readonly property var k: kinds.filter(x => x.id === kind)[0]
    readonly property var own: Store.settings[k.key] || []
    readonly property var fromFiles: {
        const out = []
        for (const path of Store.fileNames)
            for (const c of H.findCalls(Store.files[path], k.fn))
                out.push({ file: Store.shortPath(path), line: c.line, rule: H.parseLuaTable(c.args) })
        return out
    }
    property int editing: -2
    property var draft: ({})

    function pairs(obj) { const out = []; for (const key in (obj || {})) if (key !== "match" && key !== "__list") out.push({ key: key, value: obj[key] }); return out }
    function typed(v) {
        const s = String(v).trim()
        if (s === "true") return true
        if (s === "false") return false
        if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s)
        return s
    }
    function show(v) { return typeof v === "object" ? JSON.stringify(v) : String(v) }
    function startEdit(i) {
        editing = i
        const r = i >= 0 ? H.clone(own[i]) : (kind === "workspace" ? { workspace: "" } : { name: "", match: {} })
        draft = { name: r.name || "", workspace: r.workspace || "", match: pairs(r.match), props: pairs(r).filter(p => p.key !== "name" && p.key !== "workspace") }
    }
    function saveDraft() {
        const r = {}
        if (kind === "workspace") { if (!draft.workspace) { Store.say("a workspace rule needs a workspace", true); return } r.workspace = draft.workspace }
        else {
            if (draft.name) r.name = draft.name
            r.match = {}
            for (const p of draft.match) if (p.key) r.match[p.key] = typed(p.value)
        }
        for (const p of draft.props) if (p.key) r[p.key] = typed(p.value)
        const list = own.slice()
        if (editing >= 0) list[editing] = r; else list.push(r)
        Store.setList(k.key, list)
        editing = -2
    }
    function remove(i) { const list = own.slice(); list.splice(i, 1); Store.setList(k.key, list) }
    function setPair(which, i, field, v) { const d = H.clone(draft); d[which][i][field] = v; draft = d }
    function addPair(which) { const d = H.clone(draft); d[which].push({ key: "", value: "" }); draft = d }
    function dropPair(which, i) { const d = H.clone(draft); d[which].splice(i, 1); draft = d }

    // a key = value editor (match or properties)
    component PairList: ColumnLayout {
        id: pl
        property string which: "props"
        property var keys: []
        property string title: ""
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            Text { text: pl.title; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
            UiButton { icon: "󰐕"; small: true; onClicked: page.addPair(pl.which) }
        }
        Repeater {
            model: page.draft[pl.which] || []
            RowLayout {
                id: pr
                required property int index
                required property var modelData
                spacing: 6
                UiCombo { Layout.preferredWidth: 190; editable: true; entries: pl.keys.map(x => ({ label: x, value: x })); value: pr.modelData.key
                    onPicked: v => page.setPair(pl.which, pr.index, "key", String(v)) }
                UiField { Layout.fillWidth: true; mono: true; text: page.show(pr.modelData.value); placeholderText: "value (true, 1, text, regex…)"
                    onCommitted: v => page.setPair(pl.which, pr.index, "value", v) }
                UiButton { icon: "󰆴"; small: true; danger: true; onClicked: page.dropPair(pl.which, pr.index) }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 6
            Repeater {
                model: page.kinds
                UiButton {
                    required property var modelData
                    label: modelData.label
                    primary: page.kind === modelData.id
                    onClicked: { page.kind = modelData.id; page.editing = -2 }
                }
            }
            Item { Layout.fillWidth: true }
            UiButton { label: "Add rule"; icon: "󰐕"; primary: true; onClicked: page.startEdit(-1) }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: parent.width
                spacing: 12

                // ---------- editor ----------
                Card {
                    visible: page.editing !== -2
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    title: page.editing >= 0 ? "Edit rule" : "New " + page.kind + " rule"
                    subtitle: page.kind === "workspace" ? "workspace: 1, name:web, special:magic, w[tv1]…  ·  properties as hl.workspace_rule takes them"
                             : "match: regexes (class, title…) and states (float, xwayland…)  ·  properties as " + page.k.fn + " takes them (float = true, size = \"800 600\", opacity = 0.9)"
                    RowLayout {
                        visible: page.kind !== "workspace"
                        Text { text: "Name"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                        UiField { Layout.preferredWidth: 260; text: page.draft.name || ""; placeholderText: "optional"; onTextChanged: page.draft.name = text }
                    }
                    RowLayout {
                        visible: page.kind === "workspace"
                        Text { text: "Workspace"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                        UiField { Layout.preferredWidth: 260; mono: true; text: page.draft.workspace || ""; placeholderText: "1  ·  name:web  ·  special:magic"; onTextChanged: page.draft.workspace = text }
                    }
                    PairList { visible: page.kind !== "workspace"; which: "match"; keys: page.k.matchKeys; title: "Match" }
                    PairList { which: "props"; keys: page.k.ruleKeys; title: "Properties" }
                    RowLayout {
                        Item { Layout.fillWidth: true }
                        UiButton { label: "Cancel"; onClicked: page.editing = -2 }
                        UiButton { label: "Save & reload"; primary: true; onClicked: page.saveDraft() }
                    }
                }

                // ---------- app rules ----------
                Text { visible: page.own.length > 0; Layout.leftMargin: 12; text: "From this app"; color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
                Repeater {
                    model: page.own
                    Card {
                        id: oc
                        required property int index
                        required property var modelData
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        title: modelData.name || modelData.workspace || "(unnamed)"
                        subtitle: (modelData.match ? "match " + JSON.stringify(modelData.match) + "\n" : "") + page.pairs(modelData).filter(p => p.key !== "name" && p.key !== "workspace").map(p => p.key + " = " + page.show(p.value)).join("  ·  ")
                        headerItems: [
                            UiButton { icon: "󰏫"; small: true; tooltip: "edit"; onClicked: page.startEdit(oc.index) },
                            UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: page.remove(oc.index) }
                        ]
                    }
                }

                // ---------- file rules ----------
                Text { Layout.leftMargin: 12; text: "From the files (read-only)"; color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
                Repeater {
                    model: page.fromFiles
                    Card {
                        id: fc
                        required property var modelData
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        title: (modelData.rule.name || modelData.rule.workspace || "(unnamed)") + "   ·   " + modelData.file + ":" + modelData.line
                        subtitle: (modelData.rule.match ? "match " + JSON.stringify(modelData.rule.match) + "\n" : "") + page.pairs(modelData.rule).filter(p => p.key !== "name" && p.key !== "workspace").map(p => p.key + " = " + page.show(p.value)).join("  ·  ")
                        headerItems: [ UiButton { icon: "󰏫"; small: true; tooltip: "open the file"; onClicked: Store.openFile(Store.hyprDir + "/" + fc.modelData.file) } ]
                    }
                }
                Text { visible: page.fromFiles.length === 0 && page.own.length === 0; Layout.margins: 12; text: "no " + page.kind + " rules"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                Item { height: 12 }
            }
        }
    }
}
