import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Shelfmark's queue: what is downloading, waiting, done or failed, newest first
Item {
    id: page
    Component.onCompleted: Store.loadDownloads()

    function tint(b) { return b === "complete" || b === "done" ? Ui.green : b === "error" || b === "failed" ? Ui.red : b === "queued" ? Ui.overlay : Ui.accent }

    ListView {
        id: list
        anchors.fill: parent
        anchors.margins: 16; anchors.topMargin: 8
        clip: true
        spacing: 6
        model: Store.downloads
        ScrollBar.vertical: ScrollBar {}
        Text {
            anchors.centerIn: parent
            visible: Store.downloads.length === 0
            text: "Nothing in Shelfmark's queue."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
        delegate: Rectangle {
            id: row
            required property var modelData
            width: list.width
            implicitHeight: col.implicitHeight + 16
            radius: Ui.cardRadius
            color: Ui.raised
            ColumnLayout {
                id: col
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                spacing: 4
                RowLayout {
                    spacing: 8
                    Badge { text: row.modelData.bucket; tint: page.tint(row.modelData.bucket) }
                    Text { Layout.fillWidth: true; text: row.modelData.title + (row.modelData.author ? " — " + row.modelData.author : ""); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                    Text { text: [row.modelData.content_type, row.modelData.source, row.modelData.format].filter(x => x).join(" · "); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                }
                Rectangle {
                    visible: row.modelData.progress !== null && row.modelData.progress !== undefined && row.modelData.bucket !== "complete"
                    Layout.fillWidth: true; implicitHeight: 4; radius: 2; color: Ui.sunken
                    Rectangle { width: parent.width * Math.min(1, (row.modelData.progress || 0) / 100); height: parent.height; radius: 2; color: Ui.accent }
                }
                Text {
                    readonly property var m: row.modelData
                    visible: m.bucket === "downloading" && (m.progress !== null && m.progress !== undefined)
                    text: Math.floor(m.progress || 0) + " %" + (m.size ? " of " + m.size : "")
                          + (m.speed ? " · " + (m.speed > 1048576 ? (m.speed / 1048576).toFixed(1) + " MB/s" : Math.round(m.speed / 1024) + " KB/s") : "")
                          + (m.eta ? " · " + (m.eta >= 3600 ? Math.floor(m.eta / 3600) + " h " : "") + Math.floor((m.eta % 3600) / 60) + " min left" : "")
                    color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                }
                Text { visible: row.modelData.message !== ""; Layout.fillWidth: true; text: row.modelData.message; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap }
            }
        }
    }
}
