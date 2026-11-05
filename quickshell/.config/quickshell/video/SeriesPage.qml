import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Sonarr's series: episodes on disk, what is downloading, the dub per season. A click opens the series
// on the right with its seasons and episodes (checklist each), Search and Releases per season/episode.
Item {
    id: page
    property string needle: ""

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            readonly property bool split: Store.show !== null || Store.detailLoading
            Layout.fillWidth: !split
            Layout.preferredWidth: split ? 340 : -1
            Layout.fillHeight: true
            Layout.margins: 16; Layout.topMargin: 8
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                UiField { Layout.fillWidth: true; placeholderText: "filter by title"; onTextChanged: page.needle = text }
                UiButton { label: "Reload"; icon: "󰑓"; small: true; onClicked: Store.loadSeries() }
            }
            Text {
                visible: Store.series.length === 0
                text: Store.seriesLoading ? "Reading Sonarr…" : "No series yet: add one in Search."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 6
                model: Store.series.filter(s => !page.needle || s.title.toLowerCase().indexOf(page.needle.toLowerCase()) >= 0)
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool current: Store.show && Store.show.id === modelData.id
                    width: list.width
                    implicitHeight: 112
                    radius: Ui.cardRadius
                    color: current ? Ui.surface : (rm.containsMouse ? Ui.faint : Ui.raised)
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 8
                        spacing: 12
                        Poster { source: row.modelData.poster || ""; title: row.modelData.title; Layout.preferredWidth: 64; Layout.preferredHeight: 96 }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            Text { Layout.fillWidth: true; text: row.modelData.title + " (" + row.modelData.year + ")"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; text: [row.modelData.network, row.modelData.status, row.modelData.profile, row.modelData.original ? "original: " + row.modelData.original : ""].filter(x => x).join(" · "); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                            RowLayout {
                                spacing: 4
                                Badge { text: row.modelData.files + "/" + row.modelData.episodes + " episodes"; tint: row.modelData.files >= row.modelData.episodes ? Ui.green : Ui.yellow }
                                Badge { text: Store.gb(row.modelData.size_gb); tint: Ui.subtext }
                                Badge { visible: !!row.modelData.queue; text: row.modelData.queue ? row.modelData.queue.count + " downloading" : ""; tint: Ui.accent }
                                Badge { visible: row.modelData.dub_seasons > 0; text: "dub " + row.modelData.dub_done + "/" + row.modelData.dub_seasons + " seasons"; tint: row.modelData.dub_done === row.modelData.dub_seasons ? Ui.green : Ui.yellow }
                            }
                            Rectangle {
                                Layout.fillWidth: true; implicitHeight: 4; radius: 2; color: Ui.sunken
                                Rectangle { width: parent.width * (row.modelData.episodes ? Math.min(1, row.modelData.files / row.modelData.episodes) : 0); height: parent.height; radius: 2; color: Ui.green }
                            }
                        }
                    }
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.openShow(row.modelData.id) }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface; visible: Store.show !== null || Store.detailLoading }
        SeriesDetail {
            Layout.fillHeight: true
            Layout.fillWidth: true
            Layout.minimumWidth: 380
            visible: Store.show !== null || Store.detailLoading
        }
    }
}
