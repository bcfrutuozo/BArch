import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// where the traffic comes from: every indexer (the one Lidarr, Radarr or Sonarr grabbed the torrent
// from, by their history), category or tracker (the torrent's first announce host), with its torrents,
// what it uploaded and downloaded in the range and in total, and its lifetime ratio. A click shows
// its history on the right.
Item {
    id: page
    readonly property var kinds: [
        { value: "indexer", label: "Indexer" }, { value: "category", label: "Category" }, { value: "tracker", label: "Tracker" }
    ]
    readonly property real topUp: Math.max(1, ...Store.groups.map(g => g.up))
    readonly property var picked: Store.groups.filter(g => g.key === Store.groupKey)[0] || null
    readonly property var missing: Store.status.indexers_missing || []

    component Cell: Text {
        property real w: 76
        Layout.preferredWidth: w
        horizontalAlignment: Text.AlignRight
        color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
        elide: Text.ElideRight
    }
    component Head: Cell { color: Ui.subtext; font.pixelSize: Ui.fontSize - 2 }

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
                spacing: 6
                Text { text: "By"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                Repeater {
                    model: page.kinds
                    UiButton { required property var modelData; label: modelData.label; small: true; primary: Store.by === modelData.value; onClicked: Store.setBy(modelData.value) }
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: Store.by === "indexer" ? (page.missing.length ? "no API key for " + page.missing.join(", ") + ": its torrents have no indexer" : "from the history of Lidarr, Radarr and Sonarr")
                        : Store.by === "tracker" ? "the first announce host of each torrent (public ones carry many)" : "qBittorrent's category"
                    color: Store.by === "indexer" && page.missing.length ? Ui.yellow : Ui.overlay
                    font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                spacing: 10
                Head { Layout.fillWidth: true; horizontalAlignment: Text.AlignLeft; text: Store.by.charAt(0).toUpperCase() + Store.by.slice(1) }
                Head { w: 70; text: "torrents" }
                Head { w: 150; text: "↑ " + Store.rangeLabel }
                Head { text: "↓ " + Store.rangeLabel }
                Head { text: "↑ total" }
                Head { text: "↓ total" }
                Head { w: 56; text: "ratio" }
            }
            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 4
                model: Store.groups
                ScrollBar.vertical: ScrollBar {}
                Text {
                    anchors.centerIn: parent
                    visible: list.count === 0
                    text: Store.reachable ? "No torrents seen yet." : "The service is not reachable."
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                }
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool current: Store.groupPicked && Store.groupKey === modelData.key
                    width: list.width
                    implicitHeight: 38
                    radius: Ui.radius
                    color: current ? Ui.surface : (rm.containsMouse ? Ui.faint : Ui.raised)
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                        spacing: 10
                        Text {
                            Layout.fillWidth: true
                            text: Store.groupName(row.modelData.key)
                            color: row.modelData.key === "" ? Ui.subtext : Ui.text
                            font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: row.current; elide: Text.ElideRight
                        }
                        Cell { w: 70; text: row.modelData.live + (row.modelData.torrents > row.modelData.live ? " +" + (row.modelData.torrents - row.modelData.live) : ""); color: Ui.subtext }
                        RowLayout {
                            Layout.preferredWidth: 150
                            Layout.fillWidth: false
                            spacing: 8
                            Rectangle {
                                Layout.fillWidth: true; height: 6; radius: 3; color: Ui.sunken
                                Rectangle { width: parent.width * row.modelData.up / page.topUp; height: parent.height; radius: 3; color: Ui.accent; visible: row.modelData.up > 0 }
                            }
                            Cell { w: 62; text: Store.bytes(row.modelData.up) }
                        }
                        Cell { text: Store.bytes(row.modelData.down); color: Ui.subtext }
                        Cell { text: Store.bytes(row.modelData.total_up) }
                        Cell { text: Store.bytes(row.modelData.total_down); color: Ui.subtext }
                        Cell { w: 56; text: Store.ratio(row.modelData.ratio); color: Store.ratioTint(row.modelData.ratio); font.bold: true }
                    }
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.pickGroup(row.modelData.key) }
                }
            }
            Text {
                Layout.fillWidth: true
                text: "torrents: in the client, + the removed ones still counted  ·  totals include what a torrent had before tracking began"
                color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight
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
                visible: !page.picked
                text: "Pick a row to see its history."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            ScrollView {
                anchors.fill: parent; anchors.margins: 14
                visible: !!page.picked
                contentWidth: availableWidth
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    width: parent.width
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { Layout.fillWidth: true; text: page.picked ? Store.groupName(page.picked.key) : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true; elide: Text.ElideRight }
                            Text {
                                Layout.fillWidth: true
                                text: page.picked ? page.picked.live + " torrents in the client (" + Store.bytes(page.picked.size) + ")"
                                      + (page.picked.torrents > page.picked.live ? ", " + (page.picked.torrents - page.picked.live) + " removed" : "")
                                      + (page.picked.below_1 ? "  ·  " + page.picked.below_1 + " below ratio 1" : "") : ""
                                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap
                            }
                        }
                        UiButton { label: "Torrents"; icon: "󰁔"; small: true; tooltip: "the torrents of this " + Store.by; onClicked: Store.showTorrentsOf(Store.by, page.picked.key) }
                    }
                    HistoryPanel { Layout.fillWidth: true; history: Store.groupHistory }
                }
            }
        }
    }
}
