// shell.qml — Hyprland Settings: every option of the running Hyprland, its monitors, key binds,
// animations, rules, devices and startup, in one window (own Shell ID, like the palette editor).
//
//   qs -p ~/.config/quickshell/hypr              barch hypr [edit]
//   BARCH_HYPR_PAGE=<page|section>               opens on that page (general, decoration, monitors, binds…)
//   qs -p ~/.config/quickshell/hypr ipc call app open <page> | close
//
// The option list comes from `hyprctl descriptions` (so it always matches the installed version)
// typed with the Lua stubs Hyprland ships; the hand-written conf/*.lua are read, never written:
// what you change goes to ~/.config/hypr/settings.json, which conf/settings.lua applies on top.
// Options, monitors, animations and devices apply live (hyprctl eval); binds, rules, gestures
// reload Hyprland; environment waits for the next start.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "hypr.js" as H

ShellRoot {
    id: root

    property string page: "general"      // a section id or monitors | binds | animations | rules | devices | startup | files
    property string query: ""
    readonly property var pages: [
        { id: "monitors",   label: "Monitors",   icon: "󰍹" },
        { id: "binds",      label: "Key binds",  icon: "󰌌" },
        { id: "animations", label: "Animations", icon: "󰑓" },
        { id: "rules",      label: "Rules",      icon: "󰓆" },
        { id: "devices",    label: "Devices",    icon: "󰍽" },
        { id: "startup",    label: "Startup",    icon: "󰐊" },
        { id: "files",      label: "Files",      icon: "󰈙" }
    ]
    readonly property bool onSection: !pages.some(p => p.id === page)

    function open(p) {
        if (p) { page = p; query = "" }
        win.visible = true
    }
    Component.onCompleted: {
        const p = Quickshell.env("BARCH_HYPR_PAGE")
        if (p) page = p
    }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
        // barch hypr set|reset|get: the value is JSON (10, true, "dwindle", {"colors": [...]})
        function set(name: string, json: string): string {
            if (!Store.byName[name]) return JSON.stringify({ ok: false, error: "unknown option: " + name })
            let v
            try { v = JSON.parse(json) } catch (e) { v = json }
            Store.setOption(name, v)
            return JSON.stringify({ ok: true, name: name, value: v })
        }
        function reset(name: string): string {
            if (!(name in Store.overrides)) return JSON.stringify({ ok: false, error: "not saved by the app: " + name })
            Store.resetOption(name)
            return JSON.stringify({ ok: true, name: name })
        }
        function get(name: string): string {
            const o = Store.byName[name]
            if (!o) return JSON.stringify({ ok: false, error: "unknown option: " + name })
            return JSON.stringify({ ok: true, name: name, kind: o.kind, current: Store.current[name], "default": o.def, saved: name in Store.overrides ? Store.overrides[name] : null, description: o.desc })
        }
    }

    FloatingWindow {
        id: win
        title: "BArch Hyprland"
        implicitWidth: 1280
        implicitHeight: 820
        minimumSize: Qt.size(980, 600)
        color: Ui.base

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // ---------- sidebar ----------
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 230
                color: Ui.raised
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 6
                    RowLayout {
                        Layout.leftMargin: 6; Layout.topMargin: 4
                        Text { text: "󰖲"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Hyprland"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text { text: Store.version || "…"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                    UiField {
                        id: search
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        placeholderText: "search options…"
                        onTextChanged: { root.query = text; if (text !== "" && !root.onSection) root.page = "general" }
                        Keys.onEscapePressed: { text = ""; focus = false }
                    }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: availableWidth
                        clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        ColumnLayout {
                            width: parent.width
                            spacing: 1
                            component NavRow: Rectangle {
                                id: nav
                                property string pid: ""
                                property string label: ""
                                property string icon: ""
                                property int count: 0
                                property int marks: 0
                                readonly property bool current: root.page === pid && (root.query === "" || !root.onSection || true)
                                Layout.fillWidth: true
                                implicitHeight: 30
                                radius: Ui.radius
                                color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                    spacing: 8
                                    Text { visible: nav.icon !== ""; text: nav.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                    Text { Layout.fillWidth: true; text: nav.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                                    Rectangle { visible: nav.marks > 0; width: 8; height: 8; radius: 4; color: Ui.accent }
                                    Text { visible: nav.count > 0; text: nav.count; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                                }
                                MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.page = nav.pid; if (!root.onSection) { search.text = "" } } }
                            }
                            Text { Layout.leftMargin: 10; Layout.topMargin: 4; text: "Hyprland"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; font.bold: true }
                            Repeater {
                                model: root.pages
                                NavRow {
                                    required property var modelData
                                    pid: modelData.id
                                    label: modelData.label
                                    icon: modelData.icon
                                    marks: modelData.id === "monitors" ? Object.keys(Store.settings.monitors || {}).length
                                         : modelData.id === "binds" ? Store.ownBinds.length + Store.unbinds.length
                                         : modelData.id === "animations" ? Object.keys(Store.settings.animations || {}).length + Object.keys(Store.settings.curves || {}).length
                                         : modelData.id === "rules" ? (Store.settings.window_rules || []).length + (Store.settings.layer_rules || []).length + (Store.settings.workspace_rules || []).length
                                         : modelData.id === "devices" ? Object.keys(Store.settings.devices || {}).length
                                         : modelData.id === "startup" ? (Store.settings.exec || []).length + Object.keys(Store.settings.env || {}).length + (Store.settings.gestures || []).length
                                         : 0
                                }
                            }
                            Text { Layout.leftMargin: 10; Layout.topMargin: 12; text: "Options"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; font.bold: true }
                            Repeater {
                                model: Store.sections
                                NavRow {
                                    required property var modelData
                                    pid: modelData.id
                                    label: modelData.label
                                    count: modelData.count
                                    marks: Object.keys(Store.overrides).filter(n => n.split(":")[0] === modelData.id).length
                                }
                            }
                        }
                    }
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }

            // ---------- content ----------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                // header
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 16; Layout.bottomMargin: 4
                    spacing: 10
                    Text {
                        text: root.query !== "" && root.onSection ? "Search: " + root.query
                            : root.onSection ? H.sectionLabel(root.page) : (root.pages.filter(p => p.id === root.page)[0] || { label: root.page }).label
                        color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 6; font.bold: true
                    }
                    Text {
                        visible: root.onSection && root.query === ""
                        text: Store.sections.filter(s => s.id === root.page).map(s => s.count + " options")[0] || ""
                        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                    }
                    Item { Layout.fillWidth: true }
                    Text { visible: Store.busy; text: "reloading…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    UiButton { icon: "󰑐"; label: "Reload"; small: true; tooltip: "hyprctl reload: re-reads the files and settings.json"; onClicked: Store.reload() }
                }
                // page
                Loader {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    sourceComponent: {
                        switch (root.onSection ? "options" : root.page) {
                        case "monitors": return monitorsC
                        case "binds": return bindsC
                        case "animations": return animationsC
                        case "rules": return rulesC
                        case "devices": return devicesC
                        case "startup": return startupC
                        case "files": return filesC
                        default: return optionsC
                        }
                    }
                }
                Component { id: optionsC; OptionsPage { section: root.page; query: root.query } }
                Component { id: monitorsC; MonitorsPage {} }
                Component { id: bindsC; BindsPage {} }
                Component { id: animationsC; AnimationsPage {} }
                Component { id: rulesC; RulesPage {} }
                Component { id: devicesC; DevicesPage {} }
                Component { id: startupC; StartupPage {} }
                Component { id: filesC; FilesPage {} }

                // status bar
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        spacing: 12
                        Text {
                            Layout.fillWidth: true
                            text: Store.status
                            color: Store.statusBad ? Ui.red : Ui.subtext
                            font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                            elide: Text.ElideRight
                        }
                        Text { visible: Store.configErrors !== ""; text: "config errors"; color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.page = "files" } }
                        Text { visible: Store.applyErrors !== ""; text: "settings.json errors"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.page = "files" } }
                        Text { visible: Store.restartNeeded; text: "env: restart Hyprland"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text { text: Store.overrideCount + " option" + (Store.overrideCount === 1 ? "" : "s") + " saved"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
