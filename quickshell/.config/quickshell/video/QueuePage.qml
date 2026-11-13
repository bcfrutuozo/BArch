pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Radarr's and Sonarr's queue (video.py queue): one row per download (a season pack's episodes
// together), progress, time left, the warnings the client or the app gave. Remove takes it out of the
// client; with "blocklist" that release is never grabbed again, with "search" another one is looked for.
Item {
    id: page
    property string app: "all"
    Component.onCompleted: Store.loadQueue()

    function tint(q) {
        return q.error || q.health === "warning" || q.health === "error" ? Ui.red
             : q.state === "importPending" || q.state === "importing" ? Ui.green
             : q.status === "queued" || q.status === "paused" ? Ui.overlay : Ui.accent
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16; anchors.topMargin: 8
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            UiCombo {
                entries: [{ label: "Radarr and Sonarr", value: "all" }, { label: "Radarr (movies)", value: "radarr" }, { label: "Sonarr (series)", value: "sonarr" }]
                value: page.app
                onPicked: v => page.app = v
            }
            Text {
                Layout.fillWidth: true
                text: list.count + " downloads · " + Store.queue.filter(q => q.state === "downloading" && q.progress > 0).length + " moving · "
                      + Store.queue.filter(q => q.error || q.health === "warning").length + " with a warning"
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
            }
            UiButton { label: "Reload"; icon: "󰑓"; small: true; onClicked: Store.loadQueue() }
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: Store.queue.filter(q => page.app === "all" || q.app === page.app)
            ScrollBar.vertical: ScrollBar {}
            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: "Nothing downloading."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            delegate: Rectangle {
                id: row
                required property var modelData
                property bool asking: false
                width: list.width
                implicitHeight: col.implicitHeight + 16
                radius: Ui.cardRadius
                color: Ui.raised
                ColumnLayout {
                    id: col
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: row.modelData.app === "radarr" ? "󰎁" : "󰟞"; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                        Text { Layout.fillWidth: true; text: row.modelData.what; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight }
                        Badge { text: row.modelData.state || row.modelData.status; tint: page.tint(row.modelData) }
                        Text { text: Store.gb(row.modelData.size_gb) + (row.modelData.timeleft ? " · " + row.modelData.timeleft : ""); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        UiButton { small: true; icon: "󰆴"; tooltip: "remove…"; onClicked: row.asking = !row.asking }
                    }
                    Text { Layout.fillWidth: true; text: row.modelData.release; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle }
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 4; radius: 2; color: Ui.sunken
                        Rectangle { width: parent.width * Math.min(1, row.modelData.progress / 100); height: parent.height; radius: 2; color: page.tint(row.modelData) }
                    }
                    Text {
                        visible: text !== ""
                        Layout.fillWidth: true
                        text: [row.modelData.error].concat(row.modelData.messages).filter(x => x).join(" · ")
                        color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        visible: row.asking
                        spacing: 6
                        Text { text: "Remove from " + row.modelData.client + ":"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiButton { small: true; label: "Just remove"; onClicked: { row.asking = false; Store.remove(row.modelData, false, false) } }
                        UiButton { small: true; label: "Blocklist + search another"; danger: true; tooltip: "this release is never grabbed again and the app looks for another"; onClicked: { row.asking = false; Store.remove(row.modelData, true, true) } }
                        UiButton { small: true; label: "Cancel"; onClicked: row.asking = false }
                    }
                }
            }
        }
    }
}
