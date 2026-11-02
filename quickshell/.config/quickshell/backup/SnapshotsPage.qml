import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// every snapshot in the repository
Item {
    id: page
    signal browse(string id)

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 1
            RowLayout {
                Layout.margins: 12
                Text { Layout.fillWidth: true; text: Store.ready ? Store.snapshots.length + " snapshots, newest first" : "reading the repository…"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshSnapshots() }
            }
            Repeater {
                model: Store.snapshots
                Rectangle {
                    id: r
                    required property var modelData
                    required property int index
                    readonly property var s: modelData
                    readonly property var st: Store.stats[s.id] || null
                    readonly property var sum: s.summary || null
                    Layout.fillWidth: true
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    implicitHeight: 46
                    radius: Ui.radius
                    color: rm.containsMouse ? Ui.faint : "transparent"
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                        spacing: 12
                        Text { Layout.preferredWidth: 140; text: Store.when(r.s.time); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; font.bold: r.index === 0 }
                        Text { Layout.preferredWidth: 80; text: Store.short(r.s.id); color: Ui.accent; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.preferredWidth: 170; text: r.sum ? r.sum.files_new + " new · " + r.sum.files_changed + " changed · " + Store.human(r.sum.data_added) + " added" : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                        Text { Layout.fillWidth: true; text: (r.s.paths || []).length + " paths" + ((r.s.tags || []).length ? "  ·  " + r.s.tags.join(", ") : "") + "  ·  " + r.s.hostname; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                        Text { visible: r.st !== null; text: r.st ? Store.human(r.st.total_size) + "  ·  " + r.st.total_file_count + " files" : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiButton { visible: r.st === null; label: "size"; small: true; tooltip: "restic stats (takes a moment)"; onClicked: Store.loadStats(r.s.id) }
                        UiButton { label: "Browse"; icon: "󰉋"; small: true; onClicked: page.browse(r.s.id) }
                    }
                }
            }
            Item { height: 16 }
        }
    }
}
