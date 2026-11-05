// shell.qml — BArch Video: Radarr, Sonarr and the PT-BR pipeline (server/video) in a window. Search and
// add movies and series (4K, or 1080p when no 4K release fits), the library with the checklist of every
// file (original audio, PT-BR audio, English and PT-BR subtitles), releases picked by hand, the download
// queue, and the dub jobs that mux the Brazilian audio into each file.
// Talks to them through video.py with ~/.config/barch/video.json. Own Shell ID; controls from ../ui.
//
//   qs -p ~/.config/quickshell/video          barch video browse [search|movies|series|downloads|dub]

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "movies"
    readonly property var pages: [
        { id: "search", label: "Search", icon: "󰍉" },
        { id: "movies", label: "Movies", icon: "󰎁" },
        { id: "series", label: "Series", icon: "󰟞" },
        { id: "downloads", label: "Downloads", icon: "󰇚" },
        { id: "dub", label: "PT-BR dub", icon: "󰗊" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_VIDEO_PAGE"); if (p) open(p) }
    Connections { target: Store; function onNavigate(p) { root.open(p) } }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        // one movie (Radarr id), series (Sonarr id) or dub job ("m80", "s21x02") opened on its page
        function select(kind: string, id: string): void {
            if (kind === "movie") { Store.openMovie(parseInt(id)); root.open("movies") }
            else if (kind === "series") { Store.openShow(parseInt(id)); root.open("series") }
            else if (kind === "dub") { Store.openDub(id); root.open("dub") }
        }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Video"
        implicitWidth: 1320
        implicitHeight: 860
        minimumSize: Qt.size(960, 580)
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
                        Text { text: "󰕧"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Video"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text {
                                text: !Store.reachable ? "Radarr/Sonarr not reachable" : Store.status.free_gb ? Store.status.free_gb + " GB free" : "…"
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
                            readonly property int marks: modelData.id === "downloads" ? Store.queue.length
                                                       : modelData.id === "dub" ? Store.dubReview
                                                       : modelData.id === "movies" ? Store.status.movies || 0
                                                       : modelData.id === "series" ? Store.status.series || 0 : 0
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
                                    color: nav.modelData.id === "dub" ? Ui.yellow : nav.modelData.id === "downloads" ? Ui.accent : Ui.surface
                                    Text { id: mt; anchors.centerIn: parent; text: nav.marks; color: nav.modelData.id === "dub" || nav.modelData.id === "downloads" ? Ui.crust : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                                }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Text {
                        Layout.fillWidth: true; Layout.leftMargin: 6
                        text: (Store.status.movies_with_file || 0) + "/" + (Store.status.movies || 0) + " movies on disk"
                        color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WordWrap
                    }
                    UiButton { Layout.fillWidth: true; label: "Refresh"; icon: "󰑓"; small: true; onClicked: { Store.refresh(); Store.loadMovies(); Store.loadSeries() } }
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
                    sourceComponent: root.page === "search" ? searchC : root.page === "series" ? seriesC : root.page === "downloads" ? queueC : root.page === "dub" ? dubC : moviesC
                }
                Component { id: searchC; SearchPage {} }
                Component { id: moviesC; MoviesPage {} }
                Component { id: seriesC; SeriesPage {} }
                Component { id: queueC; QueuePage {} }
                Component { id: dubC; DubPage {} }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.statusText; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { visible: Store.busy > 0; text: "…"; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text { text: Store.queue.length + " downloading"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
