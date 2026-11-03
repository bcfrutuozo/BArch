// shell.qml — BArch Music: the music pipeline on the NAS (server/music) in a window. The review
// queue with everything the pipeline found and the inputs of `barch music resolve` as a form
// (release, cover, date, genre, names, titles, replace), every album it handled (undo), the
// library's covers (scans with a frame -> the clean artwork), Lidarr.
// Talks to the pipeline's API with ~/.config/barch/music.json. Own Shell ID; controls from ../ui.
//
//   qs -p ~/.config/quickshell/music          barch music browse [review|albums|covers|lidarr]

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "review"
    readonly property var pages: [
        { id: "review", label: "Review",  icon: "󰀦" },
        { id: "albums", label: "Albums",  icon: "󰀥" },
        { id: "covers", label: "Covers",  icon: "󰋩" },
        { id: "lidarr", label: "Lidarr & scan", icon: "󰒓" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_MUSIC_PAGE"); if (p) open(p) }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Music"
        implicitWidth: 1280
        implicitHeight: 860
        minimumSize: Qt.size(960, 600)
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
                        Text { text: "󰝚"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Music"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text {
                                text: !Store.reachable ? "NAS not reachable" : Store.status.running ? "working…" : (Store.status.counts.done || 0) + " done"
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
                            readonly property int marks: modelData.id === "review" ? Store.reviewCount : modelData.id === "albums" ? (Store.status.counts.failed || 0) : modelData.id === "covers" ? Store.coversToLook : 0
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
                                    color: nav.modelData.id === "review" ? Ui.yellow : Ui.red
                                    Text { id: mt; anchors.centerIn: parent; text: nav.marks; color: Ui.crust; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                                }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Repeater {
                        model: Store.states.filter(s => (Store.status.counts || {})[s] > 0)
                        RowLayout {
                            required property var modelData
                            Layout.leftMargin: 8
                            spacing: 6
                            Rectangle { implicitWidth: 8; implicitHeight: 8; radius: 4; color: Store.stateColor(parent.modelData) }
                            Text { text: Store.status.counts[parent.modelData] + " " + parent.modelData; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        }
                    }
                    Item { implicitHeight: 8 }
                    UiButton { Layout.fillWidth: true; label: "Scan"; icon: "󰑐"; small: true; tooltip: "look for finished torrents and inbox folders now"; onClicked: Store.scan() }
                    UiButton { Layout.fillWidth: true; label: "Refresh"; icon: "󰑓"; small: true; onClicked: Store.refresh() }
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
                    Text { visible: Store.status.running !== ""; text: "working on " + Store.status.running; color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle; Layout.maximumWidth: 500 }
                }
                Loader {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    sourceComponent: root.page === "albums" ? albumsC : root.page === "covers" ? coversC : root.page === "lidarr" ? lidarrC : reviewC
                }
                Component { id: reviewC; JobsPage { fixedState: "review" } }
                Component { id: albumsC; JobsPage {} }
                Component { id: lidarrC; LidarrPage {} }
                Component { id: coversC; CoversPage {} }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.statusText; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { visible: Store.busy > 0; text: "…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text { text: Store.jobs.length + " jobs"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
