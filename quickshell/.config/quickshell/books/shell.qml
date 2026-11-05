// shell.qml — BArch Books: the book stack on the NAS (server/books) in a window. Search Hardcover and
// put books on Want to Read (Shelfmark's Hardcover Sync requests and downloads them), the shelf with
// what became of each book, the requests the automatic download could not settle (a release search
// with a query you can fix, Download, Fix with Agent), the download queue.
// Talks to Shelfmark through books.py with ~/.config/barch/books.json. Own Shell ID; controls from ../ui.
//
//   qs -p ~/.config/quickshell/books          barch books browse [search|shelf|requests|rejected|downloads]

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "search"
    readonly property var pages: [
        { id: "search", label: "Search", icon: "󰍉" },
        { id: "shelf", label: "Want to Read", icon: "󰃀" },
        { id: "requests", label: "Requests", icon: "󰀦" },
        { id: "rejected", label: "Rejected", icon: "󰜺" },
        { id: "downloads", label: "Downloads", icon: "󰇚" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_BOOKS_PAGE"); if (p) open(p) }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Books"
        implicitWidth: 1200
        implicitHeight: 820
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
                        Text { text: "󰂺"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Books"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text {
                                text: !Store.reachable ? "Shelfmark not reachable" : Store.status.active > 0 ? Store.status.active + " downloading" : "idle"
                                color: Store.reachable ? Ui.subtext : Ui.red; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                            }
                        }
                    }
                    Repeater {
                        model: root.pages
                        Rectangle {
                            id: nav
                            required property var modelData
                            readonly property bool current: root.page === modelData.id
                            readonly property int marks: modelData.id === "requests" ? Store.pendingCount : modelData.id === "downloads" ? Store.status.active || 0 : 0
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Ui.radius
                            color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 8
                                Text { text: nav.modelData.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                Text { Layout.fillWidth: true; text: nav.modelData.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                                Rectangle {
                                    visible: nav.marks > 0
                                    width: mt.implicitWidth + 10; height: 16; radius: 8
                                    color: nav.modelData.id === "requests" ? Ui.yellow : Ui.accent
                                    Text { id: mt; anchors.centerIn: parent; text: nav.marks; color: Ui.crust; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                                }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    UiButton { Layout.fillWidth: true; label: "Sync now"; icon: "󰓦"; small: true; tooltip: "Hardcover Sync: Want to Read -> requests -> downloads"; onClicked: Store.sync() }
                    UiButton { Layout.fillWidth: true; label: "Refresh"; icon: "󰑓"; small: true; onClicked: Store.refresh() }
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                Text {
                    Layout.margins: 16; Layout.bottomMargin: 4
                    text: (root.pages.filter(p => p.id === root.page)[0] || { label: "" }).label
                    color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 6; font.bold: true
                }
                Loader {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    sourceComponent: root.page === "shelf" ? shelfC : root.page === "requests" ? requestsC : root.page === "rejected" ? rejectedC : root.page === "downloads" ? downloadsC : searchC
                }
                Component { id: searchC; SearchPage {} }
                Component { id: shelfC; ShelfPage {} }
                Component { id: requestsC; RequestsPage {} }
                Component { id: rejectedC; RequestsPage { fixedFilter: "rejected" } }
                Component { id: downloadsC; DownloadsPage {} }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.statusText; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { visible: Store.busy > 0; text: "…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text { text: Store.pendingCount + " pending"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
