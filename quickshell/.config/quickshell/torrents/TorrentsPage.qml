pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// every torrent the service has seen, the ones the seed policy already removed included: what each
// uploaded in the range and in total, its ratio, how long it has seeded. A click shows its history.
Item {
    id: page
    readonly property var t: Store.torrent

    component Cell: Text {
        property real w: 72
        Layout.preferredWidth: w
        horizontalAlignment: Text.AlignRight
        color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
        elide: Text.ElideRight
    }
    component Head: Cell { color: Ui.subtext; font.pixelSize: Ui.fontSize - 2 }
    component Fact: RowLayout {
        property string label: ""
        property string value: ""
        property color tint: Ui.text
        Layout.fillWidth: true
        spacing: 8
        visible: value !== ""
        Text { Layout.preferredWidth: 96; text: parent.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
        Text { Layout.fillWidth: true; text: parent.value; color: parent.tint; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WrapAnywhere }
    }

    // side by side in a wide window, the history under the list in a narrow (tiled) one
    readonly property bool wide: width >= 1060
    GridLayout {
        anchors.fill: parent
        anchors.margins: 16; anchors.topMargin: 8
        columns: page.wide ? 2 : 1
        columnSpacing: 14; rowSpacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: 1
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                UiField {
                    Layout.preferredWidth: 220
                    placeholderText: "Filter by name…"
                    text: Store.tQuery
                    onCommitted: v => { Store.tQuery = v.trim(); Store.loadTorrents() }
                }
                UiCombo {
                    entries: [{ label: "All", value: "all" }, { label: "In the client", value: "live" }, { label: "Removed", value: "removed" }]
                    value: Store.tState
                    onPicked: v => { Store.tState = v; Store.loadTorrents() }
                }
                UiCombo {
                    implicitWidth: 210
                    entries: [
                        { label: "Most uploaded " + Store.rangeLabel, value: "up" }, { label: "Most uploaded in total", value: "total_up" },
                        { label: "Most downloaded " + Store.rangeLabel, value: "down" }, { label: "Highest ratio", value: "ratio" },
                        { label: "Lowest ratio", value: "ratio_asc" }, { label: "Largest", value: "size" },
                        { label: "Newest", value: "added" }, { label: "Longest seeding", value: "seeding" }, { label: "Name", value: "name" }
                    ]
                    value: Store.tSort
                    onPicked: v => { Store.tSort = v; Store.loadTorrents() }
                }
                Rectangle {
                    visible: Store.tBy !== ""
                    implicitWidth: chip.implicitWidth + 16; implicitHeight: 24; radius: 12
                    color: Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.18)
                    RowLayout {
                        id: chip
                        anchors.centerIn: parent
                        spacing: 6
                        Text { text: Store.tBy + ": " + (Store.tKey || "(none)"); color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; font.bold: true }
                        Text { text: "󰅖"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize - 2 }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Store.clearGroupFilter() }
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    text: Store.torrentsLoading && !list.count ? "loading…" : list.count + " torrents"
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                spacing: 10
                Head { Layout.fillWidth: true; horizontalAlignment: Text.AlignLeft; text: "Torrent" }
                Head { w: 64; text: "size" }
                Head { text: "↑ " + Store.range }
                Head { text: "↑ total" }
                Head { text: "↓ total" }
                Head { w: 52; text: "ratio" }
                Head { w: 56; text: "seeding" }
            }
            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 4
                model: Store.torrents
                ScrollBar.vertical: ScrollBar {}
                Text {
                    anchors.centerIn: parent
                    visible: list.count === 0 && !Store.torrentsLoading
                    text: "No torrents match."
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                }
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool current: Store.torrentHash === modelData.hash
                    readonly property bool gone: modelData.removed_at !== null
                    width: list.width
                    implicitHeight: 46
                    radius: Ui.radius
                    color: current ? Ui.surface : (rm.containsMouse ? Ui.faint : Ui.raised)
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                        spacing: 10
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { Layout.fillWidth: true; text: row.modelData.name || row.modelData.hash; color: row.gone ? Ui.subtext : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                            Text {
                                Layout.fillWidth: true
                                text: [row.modelData.category, row.modelData.indexer, row.modelData.tracker, "added " + Store.day(row.modelData.added_on),
                                       row.gone ? "removed " + Store.day(row.modelData.removed_at) : row.modelData.progress < 1 ? Math.floor(row.modelData.progress * 100) + " %" : ""].filter(x => x).join("  ·  ")
                                color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight
                            }
                        }
                        Cell { w: 64; text: Store.bytes(row.modelData.size); color: Ui.subtext }
                        Cell { text: row.modelData.up ? Store.bytes(row.modelData.up) : "—"; color: row.modelData.up ? Ui.accent : Ui.overlay }
                        Cell { text: Store.bytes(row.modelData.total_up) }
                        Cell { text: Store.bytes(row.modelData.total_down); color: Ui.subtext }
                        Cell { w: 52; text: Store.ratio(row.modelData.ratio); color: Store.ratioTint(row.modelData.ratio); font.bold: true }
                        Cell { w: 56; text: Store.span(row.modelData.seeding_time); color: Ui.subtext }
                    }
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.pickTorrent(row.modelData.hash) }
                }
            }
        }

        Rectangle {
            Layout.preferredWidth: page.wide ? 420 : -1
            Layout.fillWidth: !page.wide
            Layout.fillHeight: true
            Layout.preferredHeight: 1
            radius: Ui.cardRadius
            color: Ui.raised
            border.width: 1; border.color: Ui.surface
            Text {
                anchors.centerIn: parent
                visible: !page.t
                text: Store.torrentHash ? "loading…" : "Pick a torrent to see its history."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            ScrollView {
                anchors.fill: parent; anchors.margins: 14
                visible: !!page.t
                contentWidth: availableWidth
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    width: parent.width
                    spacing: 4
                    Text { Layout.fillWidth: true; Layout.bottomMargin: 4; text: page.t ? page.t.name : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; wrapMode: Text.WrapAnywhere }
                    Fact { label: "State"; value: !page.t ? "" : page.t.removed_at !== null ? "removed " + Store.when(page.t.removed_at) : page.t.state + (page.t.progress < 1 ? ", " + Math.floor(page.t.progress * 100) + " %" : ""); tint: page.t && page.t.removed_at !== null ? Ui.subtext : Ui.text }
                    Fact { label: "Category"; value: page.t ? page.t.category : "" }
                    Fact { label: "Indexer"; value: page.t ? page.t.indexer : "" }
                    Fact { label: "Tracker"; value: page.t ? page.t.tracker + (page.t.private === true ? " (private)" : "") : "" }
                    Fact { label: "Size"; value: page.t ? Store.bytes(page.t.size) : "" }
                    Fact { label: "Uploaded"; value: page.t ? Store.bytes(page.t.total_up) + (page.t.base_up ? "  (" + Store.bytes(page.t.base_up) + " before tracking)" : "") : "" }
                    Fact { label: "Downloaded"; value: page.t ? Store.bytes(page.t.total_down) : "" }
                    Fact { label: "Ratio"; value: page.t ? Store.ratio(page.t.ratio) : ""; tint: page.t ? Store.ratioTint(page.t.ratio) : Ui.text }
                    Fact { label: "Added"; value: page.t ? Store.when(page.t.added_on) : "" }
                    Fact { label: "Finished"; value: page.t && page.t.completion_on ? Store.when(page.t.completion_on) : "" }
                    Fact { label: "Seeding for"; value: page.t && page.t.seeding_time ? Store.span(page.t.seeding_time) : "" }
                    HistoryPanel { Layout.fillWidth: true; history: Store.torrentHistory }
                }
            }
        }
    }
}
