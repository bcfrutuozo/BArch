pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One series (video.py show): every season with its files, the checklist over its episodes and the
// dub job (the pipeline works per season: s<series>x<season>); a season opens to its episodes.
// Search and Releases per season (a season pack) or per episode.
Rectangle {
    id: d
    color: Ui.base
    readonly property var s: Store.show
    property var open: ({})               // season number -> expanded

    function toggle(n) { const o = Object.assign({}, open); o[n] = !o[n]; open = o }
    function pad(n) { return n < 10 ? "0" + n : "" + n }

    Flickable {
        anchors.fill: parent
        anchors.margins: 14
        contentHeight: col.implicitHeight
        clip: true
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: col
            width: parent.width
            spacing: 10
            Text { visible: !d.s; text: "Reading Sonarr…"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
            RowLayout {
                visible: !!d.s
                Layout.fillWidth: true
                spacing: 12
                Poster { source: d.s ? d.s.poster : ""; title: d.s ? d.s.title : ""; Layout.preferredWidth: 80; Layout.preferredHeight: 120 }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text { Layout.fillWidth: true; text: d.s ? d.s.title + " (" + d.s.year + ")" : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true; wrapMode: Text.WordWrap }
                    Text { Layout.fillWidth: true; text: d.s ? [d.s.network, "original: " + (d.s.original || "?"), d.s.profile].filter(x => x).join(" · ") : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap }
                    RowLayout {
                        spacing: 4
                        Text { text: "Profile"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiButton { small: true; label: "4K"; primary: !!d.s && d.s.profile === "BArch 4K"; onClicked: Store.setProfile("series", d.s.id, "4k") }
                        UiButton { small: true; label: "1080p"; primary: !!d.s && d.s.profile === "BArch 1080p"; onClicked: Store.setProfile("series", d.s.id, "1080p") }
                        Item { Layout.fillWidth: true }
                        UiButton { small: true; label: "Search all"; icon: "󰍉"; onClicked: Store.searchNow({ kind: "series", id: d.s.id, label: d.s.title }) }
                    }
                }
            }
            Text { visible: !!d.s && d.s.overview !== ""; Layout.fillWidth: true; text: d.s ? d.s.overview : ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight }

            ReleasesView { Layout.fillWidth: true; visible: Store.relTarget !== null && Store.relTarget.kind === "series" }

            Repeater {
                model: d.s ? d.s.seasons : []
                Rectangle {
                    id: sea
                    required property var modelData
                    readonly property int n: modelData.season
                    readonly property bool expanded: !!d.open[n]
                    Layout.fillWidth: true
                    implicitHeight: sc.implicitHeight + 16
                    radius: Ui.cardRadius
                    color: Ui.raised
                    border.width: 1; border.color: Ui.surface
                    ColumnLayout {
                        id: sc
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                        spacing: 6
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text {
                                text: (sea.expanded ? "󰅀" : "󰅂"); color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize
                                MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: d.toggle(sea.n) }
                            }
                            Text {
                                text: "Season " + sea.n
                                color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: d.toggle(sea.n) }
                            }
                            Badge { text: sea.modelData.files + "/" + sea.modelData.total; tint: sea.modelData.files >= sea.modelData.total ? Ui.green : Ui.yellow; tip: "episodes with a file" }
                            Checks { check: sea.modelData.files ? sea.modelData.check : null; compact: true }
                            Badge {
                                visible: sea.modelData.dub !== ""
                                text: "dub " + sea.modelData.dub; tint: Store.dubTint(sea.modelData.dub); tip: sea.modelData.dub_reason
                            }
                            Item { Layout.fillWidth: true }
                            UiButton { small: true; icon: "󰍉"; tooltip: "Sonarr searches this season now"; onClicked: Store.searchNow({ kind: "series", id: d.s.id, season: sea.n, label: d.s.title + " S" + d.pad(sea.n) }) }
                            UiButton { small: true; icon: "󰒺"; tooltip: "releases of this season: packs and episodes, ranked"; onClicked: Store.findReleases({ kind: "series", id: d.s.id, season: sea.n, label: d.s.title + " S" + d.pad(sea.n), original: d.s.original }) }
                        }
                        Text {
                            visible: sea.modelData.dub_reason !== "" && sea.modelData.dub !== "done"
                            Layout.fillWidth: true
                            text: sea.modelData.dub_reason
                            color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WordWrap
                        }
                        Repeater {
                            model: sea.expanded ? sea.modelData.episodes : []
                            RowLayout {
                                id: ep
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 6
                                Text { Layout.preferredWidth: 30; text: "E" + d.pad(ep.modelData.episode); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                                Text { Layout.fillWidth: true; text: ep.modelData.title || "?"; color: ep.modelData.has_file ? Ui.text : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                                Badge { visible: !!ep.modelData.queue; text: ep.modelData.queue ? Math.floor(ep.modelData.queue.progress) + " %" : ""; tint: Ui.accent }
                                Badge {
                                    visible: !ep.modelData.has_file && !ep.modelData.queue
                                    text: ep.modelData.aired && ep.modelData.aired > new Date().toISOString().slice(0, 10) ? "airs " + ep.modelData.aired : "missing"
                                    tint: Ui.overlay
                                }
                                Text { visible: ep.modelData.has_file; text: ep.modelData.quality; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                                Checks { visible: ep.modelData.has_file; check: ep.modelData.check; compact: true }
                                UiButton {
                                    small: true; icon: "󰒺"; tooltip: "releases of this episode"
                                    onClicked: Store.findReleases({ kind: "series", id: d.s.id, season: sea.n, episode: ep.modelData.episode, label: d.s.title + " S" + d.pad(sea.n) + "E" + d.pad(ep.modelData.episode), original: d.s.original })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
