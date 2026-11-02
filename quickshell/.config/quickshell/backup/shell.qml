// shell.qml — BArch Backup: the restic repository `barch backup` keeps on the NAS. Status of the
// last run, every snapshot, the files inside each one (listed on demand), search, and restore
// into ~/Restore with a click. Own Shell ID; the shared controls are links into ../ui.
//
//   qs -p ~/.config/quickshell/backup            barch backup browse [status|snapshots|browse]
//   qs -p ~/.config/quickshell/backup ipc call app open <page> | close

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "status"
    property string browseId: ""
    readonly property var pages: [
        { id: "status",    label: "Status",    icon: "󰋼" },
        { id: "snapshots", label: "Snapshots", icon: "󰆼" },
        { id: "browse",    label: "Browse & restore", icon: "󰉋" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_BACKUP_PAGE"); if (p) open(p) }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
        // scripting: list a folder of a snapshot (loaded on demand), restore paths (one per line)
        function ls(id: string, path: string): string {
            Store.loadDir(id, path)
            const k = Store.children[Store.key(id, path)]
            return JSON.stringify(k === undefined || k === null ? { ok: true, loading: true } : { ok: true, entries: k })
        }
        function restore(id: string, paths: string): string {       // paths separated by newlines
            const list = String(paths).split("\n").map(p => p.trim()).filter(p => p !== "")
            if (!list.length) return JSON.stringify({ ok: false, error: "no paths" })
            Store.restore(id, list)
            return JSON.stringify({ ok: true, target: Store.restoreTarget })
        }
    }

    FloatingWindow {
        id: win
        title: "BArch Backup"
        implicitWidth: 1240
        implicitHeight: 800
        minimumSize: Qt.size(900, 560)
        color: Ui.base
        onVisibleChanged: if (!visible) Qt.quit()

        RowLayout {
            anchors.fill: parent
            spacing: 0
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 200
                color: Ui.raised
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 2
                    RowLayout {
                        Layout.leftMargin: 6; Layout.topMargin: 4; Layout.bottomMargin: 10
                        Text { text: "󰁯"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Backup"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text { text: "restic · NAS"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                    Repeater {
                        model: root.pages
                        Rectangle {
                            id: nav
                            required property var modelData
                            readonly property bool current: root.page === modelData.id
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Ui.radius
                            color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 8
                                Text { text: nav.modelData.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                Text { Layout.fillWidth: true; text: nav.modelData.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 54; radius: Ui.radius
                        color: Ui.sunken; border.width: 1; border.color: Store.last.ok === false ? Ui.red : Ui.surface
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 8; spacing: 1
                            Text { text: Store.last.at ? (Store.last.ok ? "last run ok" : "last run FAILED") : "never ran"; color: Store.last.at ? (Store.last.ok ? Ui.green : Ui.red) : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
                            Text { text: Store.last.at ? Store.ago(Store.last.at * 1000) : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 16; Layout.bottomMargin: 4
                    Text { text: (root.pages.filter(p => p.id === root.page)[0] || { label: "" }).label; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 6; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { visible: Store.busy > 0; text: "restic working…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                }
                Loader {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    sourceComponent: root.page === "snapshots" ? snapshotsC : root.page === "browse" ? browseC : statusC
                }
                Component { id: statusC; StatusPage {} }
                Component { id: snapshotsC; SnapshotsPage { onBrowse: id => { root.browseId = id; root.page = "browse" } } }
                Component { id: browseC; BrowsePage { snapshot: root.browseId } }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.status; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { text: Store.repo; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle; Layout.maximumWidth: 500 }
                    }
                }
            }
        }
    }
}
