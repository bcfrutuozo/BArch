import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// what the pipeline can ask Lidarr (the same as barch music lidarr-*), and a scan of the inbox
Item {
    id: page
    function ids(s) { return s.split(/[\s,]+/).filter(x => /^\d+$/.test(x)).map(Number) }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: parent.width
            spacing: 12
            Item { implicitHeight: 2 }
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Look for new albums"
                subtitle: "Finished torrents in the pipeline's categories and folders dropped in /data/music-inbox (it also does this by itself)."
                UiButton { label: "Scan now"; icon: "󰑐"; onClicked: Store.scan() }
            }
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Quality: FLAC only"
                subtitle: "Every Lidarr quality profile allows only FLAC and FLAC 24bit, cutoff FLAC."
                UiButton { label: "Apply to every profile"; icon: "󰎈"; onClicked: Store.lidarr("flac-only", {}) }
            }
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Albums"
                subtitle: "Lidarr album ids (the number in the album's URL in Lidarr), separated by commas or spaces."
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    UiField { id: idsField; Layout.fillWidth: true; mono: true; placeholderText: "2932, 2933"; bad: text.trim() !== "" && page.ids(text).length === 0 }
                    UiButton { label: "Search now"; icon: "󰍉"; primary: true; enabledBtn: page.ids(idsField.text).length > 0; tooltip: "monitor them and search the indexers"; onClicked: Store.lidarr("search", { ids: page.ids(idsField.text) }) }
                    UiButton { label: "Monitor"; small: true; enabledBtn: page.ids(idsField.text).length > 0; onClicked: Store.lidarr("monitor", { ids: page.ids(idsField.text), monitored: true }) }
                    UiButton { label: "Unmonitor"; small: true; enabledBtn: page.ids(idsField.text).length > 0; onClicked: Store.lidarr("monitor", { ids: page.ids(idsField.text), monitored: false }) }
                }
            }
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Container"
                Text {
                    Layout.fillWidth: true
                    text: (Store.status.missing || []).length ? "Missing in the beets container: " + Store.status.missing.join(", ") + " (custom-cont-init.d not run? barch music install)" : "Every tool the pipeline needs is installed in the container."
                    color: (Store.status.missing || []).length ? Ui.red : Ui.subtext
                    font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                }
                Text { text: "API: " + (Store.url || "not configured"); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
            }
        }
    }
}
