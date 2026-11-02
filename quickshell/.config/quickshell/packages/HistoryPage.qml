import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the pacman log: installs, upgrades and removals, newest first
Item {
    id: page
    property string filter: ""
    property string action: "all"

    readonly property var rows: {
        const q = filter.trim().toLowerCase()
        let list = Store.history
        if (action !== "all") list = list.filter(h => h.action === action)
        if (q) list = list.filter(h => h.name.toLowerCase().indexOf(q) !== -1)
        return list.slice(0, 600)
    }
    function color(a) { return a === "installed" ? Ui.green : a === "removed" ? Ui.red : a === "downgraded" ? Ui.yellow : Ui.subtext }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            UiCombo { entries: ["all", "installed", "upgraded", "removed", "reinstalled", "downgraded"].map(a => ({ label: a, value: a })); value: page.action; onPicked: v => page.action = v }
            UiField { Layout.fillWidth: true; placeholderText: "package name"; onTextChanged: page.filter = text }
            Text { text: page.rows.length + (page.rows.length === 600 ? "+" : "") + " entries · /var/log/pacman.log"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            UiButton { icon: "󰏫"; small: true; tooltip: "open the full log"; onClicked: Store.terminal("pacman.log", "less +G /var/log/pacman.log") }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: parent.width
                spacing: 0
                Repeater {
                    model: page.rows
                    Rectangle {
                        id: r
                        required property var modelData
                        required property int index
                        readonly property bool newDay: index === 0 || page.rows[index - 1].time.slice(0, 10) !== modelData.time.slice(0, 10)
                        Layout.fillWidth: true
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        implicitHeight: newDay ? 44 : 24
                        color: "transparent"
                        Text { visible: r.newDay; y: 4; text: r.modelData.time.slice(0, 10); color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; font.bold: true }
                        RowLayout {
                            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                            height: 24
                            spacing: 10
                            Text { Layout.preferredWidth: 50; text: r.modelData.time.slice(11, 16); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                            Text { Layout.preferredWidth: 90; text: r.modelData.action; color: page.color(r.modelData.action); font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Text { Layout.preferredWidth: 280; text: r.modelData.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (Store.packages[r.modelData.name]) Store.showDetails(r.modelData.name) } }
                            Text { Layout.fillWidth: true; text: r.modelData.version; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                        }
                    }
                }
                Item { height: 16 }
            }
        }
    }
}
