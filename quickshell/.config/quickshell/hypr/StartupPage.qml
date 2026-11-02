import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// commands run at session start, environment variables and gestures: the app's (editable) and the files'
Item {
    id: page

    readonly property var ownExec: Store.settings.exec || []
    readonly property var ownEnv: Store.settings.env || ({})
    readonly property var ownGestures: Store.settings.gestures || []
    readonly property var fileExec: { const out = []; for (const p of Store.fileNames) for (const e of H.parseExec(Store.files[p])) out.push({ file: Store.shortPath(p), line: e.line, command: e.command }); return out }
    readonly property var fileEnv: { const out = []; for (const p of Store.fileNames) for (const e of H.parseEnv(Store.files[p])) out.push({ file: Store.shortPath(p), line: e.line, name: e.name, value: e.value }); return out }
    readonly property var fileGestures: { const out = []; for (const p of Store.fileNames) for (const c of H.findCalls(Store.files[p], "hl.gesture")) out.push({ file: Store.shortPath(p), line: c.line, spec: H.parseLuaTable(c.args) }); return out }

    function setExecAt(i, cmd) { const l = ownExec.slice(); if (cmd.trim() === "") l.splice(i, 1); else l[i] = cmd; Store.setExec(l) }
    function setEnvVar(name, value) { const m = Object.assign({}, ownEnv); if (value === null) delete m[name]; else m[name] = value; Store.setEnv(m) }
    function setGesture(i, field, v) {
        const l = H.clone(ownGestures)
        if (field === null) l.splice(i, 1)
        else { if (v === "" || v === null) delete l[i][field]; else l[i][field] = (field === "fingers" ? parseInt(v, 10) || 3 : field === "scale" ? Number(v) : v) }
        Store.setList("gestures", l)
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12

            // ---------- exec ----------
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: "Run at session start"
                subtitle: "hl.exec_cmd on hyprland.start (once per login). Saved ones run at the next session; Run now runs them in a shell right away."
                headerItems: [ UiButton { label: "Add"; icon: "󰐕"; small: true; onClicked: Store.setExec(page.ownExec.concat([""])) } ]
                Repeater {
                    model: page.ownExec
                    RowLayout {
                        id: er
                        required property int index
                        required property var modelData
                        spacing: 6
                        UiField { Layout.fillWidth: true; mono: true; text: er.modelData; placeholderText: "command (empty = remove)"; onCommitted: v => page.setExecAt(er.index, v) }
                        Badge { text: "app"; tint: Ui.accent }
                        UiButton { icon: "󰐊"; small: true; tooltip: "run now"; onClicked: Store.runNow(er.modelData) }
                        UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: page.setExecAt(er.index, "") }
                    }
                }
                Repeater {
                    model: page.fileExec
                    RowLayout {
                        id: fe
                        required property var modelData
                        spacing: 6
                        Text { Layout.fillWidth: true; text: fe.modelData.command; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                        Text { text: fe.modelData.file + ":" + fe.modelData.line; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        UiButton { icon: "󰐊"; small: true; tooltip: "run now"; onClicked: Store.runNow(fe.modelData.command) }
                    }
                }
            }

            // ---------- env ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Environment"
                subtitle: "hl.env: variables for everything Hyprland starts. They only take effect at the next Hyprland start (log out and in)." + (Store.restartNeeded ? "  ·  changed: restart pending" : "")
                headerItems: [ UiButton { label: "Add"; icon: "󰐕"; small: true; onClicked: { envName.text = ""; envValue.text = ""; envName.forceActiveFocus() } } ]
                RowLayout {
                    spacing: 6
                    UiField { id: envName; Layout.preferredWidth: 220; mono: true; placeholderText: "NAME" }
                    UiField { id: envValue; Layout.fillWidth: true; mono: true; placeholderText: "value" }
                    UiButton { label: "Save"; small: true; primary: true; enabledBtn: /^[A-Za-z_][A-Za-z0-9_]*$/.test(envName.text); onClicked: { page.setEnvVar(envName.text, envValue.text); envName.text = ""; envValue.text = "" } }
                }
                Repeater {
                    model: Object.keys(page.ownEnv).sort()
                    RowLayout {
                        id: ev
                        required property var modelData
                        spacing: 6
                        Text { Layout.preferredWidth: 220; text: ev.modelData; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        UiField { Layout.fillWidth: true; mono: true; text: String(page.ownEnv[ev.modelData]); onCommitted: v => page.setEnvVar(ev.modelData, v) }
                        Badge { text: "app"; tint: Ui.accent }
                        UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: page.setEnvVar(ev.modelData, null) }
                    }
                }
                Repeater {
                    model: page.fileEnv
                    RowLayout {
                        id: fv
                        required property var modelData
                        spacing: 6
                        Text { Layout.preferredWidth: 220; text: fv.modelData.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { Layout.fillWidth: true; text: fv.modelData.value; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                        Text { text: fv.modelData.file + ":" + fv.modelData.line; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    }
                }
            }

            // ---------- gestures ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Gestures"
                subtitle: "hl.gesture: fingers, direction, action (workspace, fullscreen, move, resize, special, close, float, dispatcher…), optional mods and scale. Changes apply at the next reload."
                headerItems: [ UiButton { label: "Add"; icon: "󰐕"; small: true; onClicked: Store.setList("gestures", page.ownGestures.concat([{ fingers: 3, direction: "horizontal", action: "workspace" }])) } ]
                Repeater {
                    model: page.ownGestures
                    RowLayout {
                        id: gr
                        required property int index
                        required property var modelData
                        spacing: 6
                        Text { text: "fingers"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiField { Layout.preferredWidth: 46; mono: true; text: String(gr.modelData.fingers || 3); onCommitted: v => page.setGesture(gr.index, "fingers", v) }
                        UiCombo { editable: true; Layout.preferredWidth: 130; entries: H.GESTURE_DIRECTIONS.map(d => ({ label: d, value: d })); value: gr.modelData.direction || ""; onPicked: v => page.setGesture(gr.index, "direction", String(v)) }
                        UiCombo { editable: true; Layout.preferredWidth: 130; entries: H.GESTURE_ACTIONS.map(d => ({ label: d, value: d })); value: gr.modelData.action || ""; onPicked: v => page.setGesture(gr.index, "action", String(v)) }
                        Text { text: "mods"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiField { Layout.preferredWidth: 110; mono: true; text: gr.modelData.mods || ""; placeholderText: "SUPER"; onCommitted: v => page.setGesture(gr.index, "mods", v) }
                        Text { text: "scale"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiField { Layout.preferredWidth: 60; mono: true; text: gr.modelData.scale !== undefined ? String(gr.modelData.scale) : ""; placeholderText: "1"; onCommitted: v => page.setGesture(gr.index, "scale", v) }
                        Item { Layout.fillWidth: true }
                        Badge { text: "app"; tint: Ui.accent }
                        UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: page.setGesture(gr.index, null, null) }
                    }
                }
                Repeater {
                    model: page.fileGestures
                    RowLayout {
                        id: fg
                        required property var modelData
                        spacing: 6
                        Text { Layout.fillWidth: true; text: Object.keys(fg.modelData.spec).map(k => k + " = " + JSON.stringify(fg.modelData.spec[k])).join("  ·  "); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { text: fg.modelData.file + ":" + fg.modelData.line; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    }
                }
            }
            Item { height: 12 }
        }
    }
}
