import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the safety snapshot pairs around Claude sessions (snapper, root only: the app hands you the commands)
Item {
    id: page

    readonly property var rows: Store.snapshots.slice().reverse()

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 1
            Text {
                Layout.margins: 12; Layout.fillWidth: true
                text: "Every Claude session in ~/BArch takes a pre snapshot of / when it starts and a post one when it ends (/home is not included; the repo has git). snapper needs root, so Status and Undo open a terminal with sudo."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
            }
            Repeater {
                model: page.rows
                Rectangle {
                    id: r
                    required property var modelData
                    readonly property var s: modelData
                    readonly property bool open: s.post === null || s.post === undefined
                    Layout.fillWidth: true
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    implicitHeight: 40
                    radius: Ui.radius
                    color: rm.containsMouse ? Ui.faint : "transparent"
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                        spacing: 12
                        Text { Layout.preferredWidth: 150; text: String(r.s.time).slice(0, 16).replace("T", " "); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.preferredWidth: 140; text: "#" + r.s.pre + " .. " + (r.open ? "(open)" : "#" + r.s.post); color: r.open ? Ui.yellow : Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.fillWidth: true; text: "session " + String(r.s.session).slice(0, 8); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        RowLayout {
                            spacing: 4
                            opacity: rm.containsMouse ? 1 : 0.35
                            UiButton { label: "Status"; small: true; enabledBtn: !r.open; tooltip: "what the session changed outside the repo (terminal, sudo)"; onClicked: Store.terminal("snapper status " + r.s.pre, Store.snapperCmd("status", r.s)) }
                            UiButton { label: "Undo"; small: true; danger: true; enabledBtn: !r.open; tooltip: "revert those changes (terminal, sudo; snapper asks nothing, so read Status first)"; onClicked: Store.terminal("snapper undochange " + r.s.pre, Store.snapperCmd("undochange", r.s)) }
                            UiButton { icon: "󰆏"; small: true; tooltip: "copy the status command"; onClicked: Store.copy(Store.snapperCmd("status", r.s)) }
                            UiButton { icon: "󰚩"; small: true; tooltip: "resume that Claude session"; onClicked: Store.continueSession(r.s.session) }
                        }
                    }
                }
            }
            Text { visible: page.rows.length === 0; Layout.margins: 12; text: "no safety snapshots yet"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
            Item { height: 16 }
        }
    }
}
