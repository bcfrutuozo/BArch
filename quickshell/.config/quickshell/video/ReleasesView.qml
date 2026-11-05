import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The releases of Store.relTarget (a movie, a season or an episode), ranked by video.py releases:
// the ones that fit the profile first, then resolution, custom format score, seeders. Grab sends one
// to the download client through Radarr/Sonarr, even a rejected one (it says why it was rejected).
ColumnLayout {
    id: view
    spacing: 6
    visible: Store.relTarget !== null

    RowLayout {
        Layout.fillWidth: true
        Text {
            Layout.fillWidth: true
            text: "Releases · " + (Store.relTarget ? Store.relTarget.label : "")
            color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; elide: Text.ElideRight
        }
        CheckBox {
            id: onlyFit
            checked: false
            contentItem: Text { leftPadding: 24; text: "only what fits"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; verticalAlignment: Text.AlignVCenter }
        }
        UiButton { small: true; label: "Close"; icon: "󰅖"; onClicked: Store.clearReleases() }
    }
    Text {
        visible: Store.releasesLoading || Store.releases.length === 0
        text: Store.releasesLoading ? "Asking the indexers through " + (Store.relTarget && Store.relTarget.kind === "movie" ? "Radarr" : "Sonarr") + " (up to a few minutes)…" : "No releases."
        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
    }
    Repeater {
        model: Store.releases.filter(r => !onlyFit.checked || r.accepted).slice(0, 60)
        Rectangle {
            id: rel
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: rc.implicitHeight + 12
            radius: Ui.radius
            color: modelData.accepted ? Ui.sunken : Qt.rgba(Ui.red.r, Ui.red.g, Ui.red.b, 0.06)
            border.width: 1
            border.color: modelData.accepted ? Ui.surface : Qt.rgba(Ui.red.r, Ui.red.g, Ui.red.b, 0.25)
            RowLayout {
                anchors.fill: parent; anchors.margins: 6
                spacing: 8
                ColumnLayout {
                    id: rc
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        Layout.fillWidth: true
                        text: rel.modelData.title
                        color: rel.modelData.accepted ? Ui.text : Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                        wrapMode: Text.WrapAnywhere; maximumLineCount: 2; elide: Text.ElideRight
                    }
                    RowLayout {
                        spacing: 4
                        Badge { text: rel.modelData.quality; tint: rel.modelData.resolution >= 2160 ? Ui.accent : Ui.subtext }
                        Badge { text: Store.gb(rel.modelData.size_gb); tint: Ui.subtext }
                        Badge { visible: rel.modelData.seeders !== null && rel.modelData.seeders !== undefined; text: rel.modelData.seeders + " seeds"; tint: rel.modelData.seeders > 5 ? Ui.green : Ui.yellow }
                        Badge { visible: rel.modelData.score !== 0; text: "score " + rel.modelData.score; tint: rel.modelData.score > 0 ? Ui.green : Ui.red }
                        Badge { visible: rel.modelData.full_season; text: "full season"; tint: Ui.accent }
                        Badge { visible: rel.modelData.languages.length > 0; text: rel.modelData.languages.slice(0, 3).join("/"); tint: rel.modelData.languages.indexOf("Portuguese (Brazil)") >= 0 || rel.modelData.languages.indexOf("Portuguese") >= 0 ? Ui.green : Ui.overlay }
                        Text { text: rel.modelData.indexer + " · " + rel.modelData.age_days + " d"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                    }
                    Text {
                        visible: !rel.modelData.accepted && rel.modelData.rejections.length > 0
                        Layout.fillWidth: true
                        text: rel.modelData.rejections.join(" · ")
                        color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WordWrap
                    }
                    Text {
                        visible: rel.modelData.formats.length > 0
                        Layout.fillWidth: true
                        text: rel.modelData.formats.join(", ")
                        color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight
                    }
                }
                UiButton {
                    small: true
                    label: Store.grabbing === rel.modelData.n ? "…" : "Grab"
                    icon: "󰇚"
                    primary: rel.modelData.accepted
                    enabledBtn: Store.grabbing < 0
                    tooltip: rel.modelData.accepted ? "download this one" : "download it anyway (Radarr/Sonarr rejected it: see why below the title)"
                    onClicked: Store.grab(rel.modelData.n)
                }
            }
        }
    }
}
