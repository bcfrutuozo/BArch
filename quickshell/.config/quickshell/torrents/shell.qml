// shell.qml — BArch Torrents: qBittorrent's statistics over time. qBittorrent only knows its totals as
// they are now, so a small service on the NAS (server/torrents, container barch-torrents) writes them
// down every five minutes; this window draws them: the ratio and how it moves, upload and download per
// day, where the traffic comes from (indexer, category, tracker) and every torrent, removed ones included.
// Read only. Talks to the service's API with ~/.config/barch/torrents.json. Own Shell ID; controls from ../ui.
//
//   qs -p ~/.config/quickshell/torrents          barch torrents browse [overview|sources|torrents]

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "overview"
    readonly property var pages: [
        { id: "overview", label: "Overview", icon: "󰄪" },
        { id: "sources", label: "Sources", icon: "󰒍" },
        { id: "torrents", label: "Torrents", icon: "󰈙" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_TORRENTS_PAGE"); if (p) open(p) }
    Connections { target: Store; function onNavigate(p) { root.open(p) } }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function range(r: string): void { if (Store.ranges.some(x => x.value === r)) Store.range = r }
        // one torrent (its info hash) opened on the Torrents page
        function torrent(hash: string): void { Store.pickTorrent(hash.toLowerCase()); root.open("torrents") }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Torrents"
        implicitWidth: 1360
        implicitHeight: 880
        minimumSize: Qt.size(1040, 600)
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
                        Text { text: "󰇚"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Torrents"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text {
                                text: !Store.configured ? "not installed" : !Store.reachable ? "service not reachable"
                                      : "ratio " + Store.ratio((Store.overview.now || {}).ratio)
                                color: Store.configured && Store.reachable ? Ui.subtext : Ui.red
                                font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                            }
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
                    Text {
                        Layout.fillWidth: true; Layout.leftMargin: 6; Layout.bottomMargin: 4
                        text: Store.status.error ? "qBittorrent does not answer the service"
                              : Store.status.last ? "last sample " + Store.ago(Store.status.last) : ""
                        color: Store.status.error ? Ui.red : Ui.overlay
                        font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WordWrap
                    }
                    UiButton { Layout.fillWidth: true; label: "Sample now"; icon: "󰑓"; small: true; tooltip: "read qBittorrent's counters now instead of at the next five minutes"; onClicked: Store.sampleNow() }
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
                    spacing: 6
                    Text {
                        Layout.fillWidth: true
                        text: (root.pages.filter(p => p.id === root.page)[0] || { label: "" }).label
                        color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 6; font.bold: true
                    }
                    Text { text: "Range"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Repeater {
                        model: Store.ranges
                        UiButton { required property var modelData; label: modelData.label; small: true; primary: Store.range === modelData.value; onClicked: Store.range = modelData.value }
                    }
                }
                Loader {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    sourceComponent: root.page === "sources" ? sourcesC : root.page === "torrents" ? torrentsC : overviewC
                }
                Component { id: overviewC; OverviewPage {} }
                Component { id: sourcesC; SourcesPage {} }
                Component { id: torrentsC; TorrentsPage {} }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.statusText; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { visible: Store.busy > 0; text: "…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text {
                            text: Store.status.torrents ? Store.status.live + " torrents in the client · " + (Store.status.torrents - Store.status.live) + " removed, still counted" : ""
                            color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                        }
                    }
                }
            }
        }
    }
}
