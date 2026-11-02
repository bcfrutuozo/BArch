import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the files of one snapshot: a tree listed on demand, a search, restore of what is ticked
Item {
    id: page
    property string snapshot: ""           // full id
    property var expanded: ({})            // path -> true
    property var selected: ({})            // path -> true
    property string query: ""

    readonly property var snap: Store.snapshots.filter(s => s.id === snapshot)[0] || null
    readonly property var selectedPaths: Object.keys(selected).filter(p => selected[p])

    onSnapshotChanged: { expanded = {}; selected = {}; Store.findResults = [] }
    Component.onCompleted: if (!snapshot && Store.snapshots.length) snapshot = Store.snapshots[0].id
    Connections { target: Store; function onSnapshotsChanged() { if (!page.snapshot && Store.snapshots.length) page.snapshot = Store.snapshots[0].id } }

    function toggle(path) {
        const e = Object.assign({}, expanded)
        if (e[path]) delete e[path]; else { e[path] = true; Store.loadDir(snapshot, path) }
        expanded = e
    }
    function tick(path, on) { const s = Object.assign({}, selected); if (on) s[path] = true; else delete s[path]; selected = s }
    function underSelected(path) { for (const p in selected) if (path !== p && path.startsWith(p + "/")) return true; return false }

    // the visible rows: roots (the snapshot's paths) and the children of expanded dirs
    readonly property var rows: {
        const out = []
        if (!snap) return out
        const walk = (entry, depth) => {
            out.push({ e: entry, depth: depth })
            if (entry.type === "dir" && expanded[entry.path]) {
                const kids = Store.children[Store.key(snapshot, entry.path)]
                if (kids === null || kids === undefined) out.push({ e: { name: "loading…", path: entry.path + "/\u0000", type: "loading" }, depth: depth + 1 })
                else if (kids.length === 0) out.push({ e: { name: "(empty)", path: entry.path + "/\u0000", type: "loading" }, depth: depth + 1 })
                else for (const k of kids) walk(k, depth + 1)
            }
        }
        const roots = (snap.paths || []).slice().sort()
        for (const p of roots) walk({ name: p, path: p, type: "dir", size: 0, mtime: "" }, 0)
        return out
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            UiCombo {
                Layout.preferredWidth: 300
                entries: Store.snapshots.map(s => ({ label: Store.when(s.time) + "  " + Store.short(s.id), value: s.id }))
                value: page.snapshot
                onPicked: v => page.snapshot = v
            }
            UiField { Layout.fillWidth: true; placeholderText: "find in this snapshot (pattern: *.kdbx, Documents/*, name)"; onCommitted: v => { page.query = v; Store.find(page.snapshot, v) } }
            Text { visible: Store.busy > 0; text: "restic…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiButton {
                label: page.selectedPaths.length ? "Restore " + page.selectedPaths.length + " item" + (page.selectedPaths.length === 1 ? "" : "s") : "Restore"
                icon: "󰁯"; primary: true; enabledBtn: page.selectedPaths.length > 0 && !Store.restoring
                tooltip: "into ~/Restore/<snapshot>-<time>/, never in place"
                onClicked: Store.restore(page.snapshot, page.selectedPaths)
            }
        }
        Text {
            Layout.leftMargin: 12; Layout.bottomMargin: 6
            text: "Tick files or folders, then Restore: they land under " + Store.restoreDir + " with their full paths, nothing is overwritten."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
        }

        // ---------- search results ----------
        Card {
            visible: page.query.trim() !== ""
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 8
            title: "Matches for " + page.query + "  ·  " + Store.findResults.length
            headerItems: [ UiButton { icon: "󰅖"; small: true; onClicked: { page.query = ""; Store.findResults = [] } } ]
            Repeater {
                model: Store.findResults.slice(0, 200)
                RowLayout {
                    id: fr
                    required property var modelData
                    spacing: 8
                    UiSwitch { implicitWidth: 32; implicitHeight: 18; checked: !!page.selected[fr.modelData.path]; onToggled: v => page.tick(fr.modelData.path, v) }
                    Text { text: fr.modelData.type === "dir" ? "󰉋" : "󰈔"; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize }
                    Text { Layout.fillWidth: true; text: fr.modelData.path; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideMiddle }
                    Text { text: fr.modelData.type === "file" ? Store.human(fr.modelData.size) : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                }
            }
        }

        // ---------- tree ----------
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: parent.width
                spacing: 0
                Repeater {
                    model: page.rows
                    Rectangle {
                        id: row
                        required property var modelData
                        readonly property var e: modelData.e
                        readonly property bool isDir: e.type === "dir"
                        readonly property bool loading: e.type === "loading"
                        readonly property bool ticked: !!page.selected[e.path]
                        readonly property bool inherited: page.underSelected(e.path)
                        Layout.fillWidth: true
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        implicitHeight: 28
                        radius: 6
                        color: row.ticked ? Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.15) : (rm.containsMouse ? Ui.faint : "transparent")
                        MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; onClicked: if (row.isDir) page.toggle(row.e.path) }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 6 + row.modelData.depth * 18; anchors.rightMargin: 8
                            spacing: 6
                            Text { visible: !row.loading; text: row.isDir ? (page.expanded[row.e.path] ? "󰅀" : "󰅂") : " "; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize - 1; Layout.preferredWidth: 14 }
                            Rectangle {
                                visible: !row.loading
                                width: 16; height: 16; radius: 4
                                color: row.ticked || row.inherited ? Ui.accent : "transparent"
                                border.width: 1; border.color: row.ticked || row.inherited ? Ui.accent : Ui.overlay
                                opacity: row.inherited && !row.ticked ? 0.5 : 1
                                Text { anchors.centerIn: parent; visible: row.ticked || row.inherited; text: "󰄬"; color: Ui.crust; font.family: Ui.iconFont; font.pixelSize: 11 }
                                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: page.tick(row.e.path, !row.ticked) }
                            }
                            Text { text: row.loading ? "" : row.isDir ? "󰉋" : "󰈔"; color: row.isDir ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize }
                            Text { Layout.fillWidth: true; text: row.e.name; color: row.loading ? Ui.overlay : Ui.text; font.family: row.modelData.depth === 0 ? Ui.monoFont : Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                            Text { visible: !row.isDir && !row.loading; text: Store.human(row.e.size); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; Layout.preferredWidth: 70; horizontalAlignment: Text.AlignRight }
                            Text { visible: !row.loading && row.e.mtime; text: Store.when(row.e.mtime); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                }
                Text { visible: page.rows.length === 0; Layout.margins: 12; text: Store.ready ? "pick a snapshot" : "reading the repository…"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                Item { height: 16 }
            }
        }

        // ---------- restore log ----------
        Rectangle {
            visible: Store.restoreLog !== ""
            Layout.fillWidth: true
            Layout.margins: 12; Layout.topMargin: 0
            implicitHeight: 150
            radius: Ui.radius
            color: Ui.sunken
            border.width: 1; border.color: Store.restoring ? Ui.yellow : Ui.surface
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 8; spacing: 4
                RowLayout {
                    Text { Layout.fillWidth: true; text: Store.restoring ? "restoring…" : "restore finished"; color: Store.restoring ? Ui.yellow : Ui.green; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true }
                    UiButton { label: "Open folder"; icon: "󰉋"; small: true; enabledBtn: !Store.restoring; onClicked: Store.openTarget() }
                    UiButton { icon: "󰅖"; small: true; enabledBtn: !Store.restoring; onClicked: Store.restoreLog = "" }
                }
                ScrollView {
                    id: lsv
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true; contentWidth: availableWidth
                    TextEdit { width: lsv.availableWidth; readOnly: true; selectByMouse: true; text: Store.restoreLog; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; wrapMode: TextEdit.Wrap }
                }
            }
        }
    }
}
