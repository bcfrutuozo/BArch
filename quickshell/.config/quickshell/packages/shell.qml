// shell.qml — BArch Packages: what is installed (explicit, AUR, orphans, everything) with
// description, size and date; pending updates and .pacnew; the pacman log; and whether the repo
// lists (packages/*.txt) match the system. Removing and marking go through pkexec (polkit asks
// the password); installing and Update All open a terminal. Own Shell ID; controls from ../ui.
//
//   qs -p ~/.config/quickshell/packages          barch packages [installed|updates|history]

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "installed"
    readonly property var pages: [
        { id: "installed", label: "Installed", icon: "󰏖" },
        { id: "updates",   label: "Updates & lists", icon: "󰚰" },
        { id: "history",   label: "History",   icon: "󰋚" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_PACKAGES_PAGE"); if (p) open(p) }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Packages"
        implicitWidth: 1240
        implicitHeight: 800
        minimumSize: Qt.size(900, 560)
        color: Ui.base
        onVisibleChanged: if (!visible) Qt.quit()

        RowLayout {
            anchors.fill: parent
            spacing: 0
            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 200
                color: Ui.raised
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 2
                    RowLayout {
                        Layout.leftMargin: 6; Layout.topMargin: 4; Layout.bottomMargin: 10
                        Text { text: "󰏖"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Packages"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text { text: Store.ready ? Store.all.length + " installed" : "…"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                    Repeater {
                        model: root.pages
                        Rectangle {
                            id: nav
                            required property var modelData
                            readonly property bool current: root.page === modelData.id
                            readonly property int marks: modelData.id === "updates" ? Store.updates.length + Store.pacnew.length + Store.unsavedCount : modelData.id === "installed" ? Store.orphans.length : 0
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Ui.radius
                            color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 8
                                Text { text: nav.modelData.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                Text { Layout.fillWidth: true; text: nav.modelData.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                                Rectangle {
                                    visible: nav.marks > 0
                                    width: mt.implicitWidth + 10; height: 16; radius: 8
                                    color: nav.modelData.id === "installed" ? Ui.red : Ui.yellow
                                    Text { id: mt; anchors.centerIn: parent; text: nav.marks; color: Ui.crust; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                                }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    UiButton { Layout.fillWidth: true; label: "Refresh"; icon: "󰑐"; small: true; onClicked: Store.refreshAll() }
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 16; Layout.bottomMargin: 4
                    Text { text: (root.pages.filter(p => p.id === root.page)[0] || { label: "" }).label; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 6; font.bold: true }
                    Item { Layout.fillWidth: true }
                }
                Loader {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    sourceComponent: root.page === "updates" ? updatesC : root.page === "history" ? historyC : installedC
                }
                Component { id: installedC; InstalledPage {} }
                Component { id: updatesC; UpdatesPage {} }
                Component { id: historyC; HistoryPage {} }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.status; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { text: Store.explicitNames.length + " explicit · " + Store.foreignNames.length + " AUR · " + Store.orphans.length + " orphans"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
