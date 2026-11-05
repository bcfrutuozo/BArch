import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Want to Read on Hardcover, each book with what Shelfmark made of it: not synced yet, a request
// waiting for a decision (Requests tab), downloading, in the library.
Item {
    id: page
    Component.onCompleted: Store.loadShelf()

    function stateOf(b) {
        if (b.owned) return { text: "in library", tint: Ui.green }
        const rs = b.requests || []
        if (!rs.length) return { text: "not synced yet", tint: Ui.overlay }
        const r = rs.filter(x => x.status === "pending")[0]
        if (r) return { text: r.type + " needs a decision", tint: Ui.yellow }
        const f = rs.filter(x => x.status === "fulfilled")[0]
        if (f) return { text: f.type + " " + (f.delivery && f.delivery !== "none" ? f.delivery : "requested"), tint: f.delivery === "complete" ? Ui.green : Ui.accent }
        return { text: rs[0].status, tint: Ui.overlay }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16; anchors.topMargin: 8
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; text: Store.shelfLoading ? "Reading Hardcover…" : Store.shelf.length + " books on Want to Read"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
            UiButton { label: "Reload"; icon: "󰑓"; small: true; onClicked: Store.loadShelf() }
            UiButton { label: "Sync now"; icon: "󰓦"; small: true; primary: true; tooltip: "Shelfmark's Hardcover Sync: new books become requests, strict matches download"; onClicked: Store.sync() }
        }
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: Math.max(150, Math.floor(width / Math.max(1, Math.floor(width / 170))))
            cellHeight: 290
            model: Store.shelf
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
                id: cell
                required property var modelData
                width: grid.cellWidth; height: grid.cellHeight
                readonly property var st: page.stateOf(modelData)
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 8
                    spacing: 4
                    Cover {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: Math.min(cell.width - 16, 130); Layout.preferredHeight: Layout.preferredWidth * 1.5
                        source: cell.modelData.cover_file || ""; title: cell.modelData.title
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Store.openUrl(cell.modelData.url) }
                    }
                    Text { Layout.fillWidth: true; text: cell.modelData.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter }
                    Text { Layout.fillWidth: true; text: Store.authors(cell.modelData.authors); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter }
                    Badge { Layout.alignment: Qt.AlignHCenter; text: cell.st.text; tint: cell.st.tint }
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }
}
