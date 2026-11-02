// shell.qml — BArch Center: services and timers (user and system), the failures `barch failure`
// saved, the agent tasks and reports, the safety snapshots, the health check and the journal,
// in one window (own Shell ID, like the palette editor and Hyprland Settings).
//
//   qs -p ~/.config/quickshell/center            barch center [page]
//   BARCH_CENTER_PAGE=<page>                     overview | services | timers | failures | agent | snapshots | journal
//   qs -p ~/.config/quickshell/center ipc call app open <page> | close
//
// Reads what systemctl, journalctl and `barch --json` give; actions are the same commands
// (system units through polkit). The shared controls are links into ../ui.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "overview"
    readonly property var pages: [
        { id: "overview",  label: "Overview",  icon: "󰋼" },
        { id: "services",  label: "Services",  icon: "󰒓" },
        { id: "timers",    label: "Timers",    icon: "󰔛" },
        { id: "failures",  label: "Failures",  icon: "󰀦" },
        { id: "agent",     label: "Agent",     icon: "󰚩" },
        { id: "snapshots", label: "Snapshots", icon: "󰁯" },
        { id: "journal",   label: "Journal",   icon: "󰌱" }
    ]
    function open(p) {
        if (p && pages.some(x => x.id === p)) page = p
        win.visible = true
    }
    Component.onCompleted: { const p = Quickshell.env("BARCH_CENTER_PAGE"); if (p) open(p) }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Center"
        implicitWidth: 1320
        implicitHeight: 840
        minimumSize: Qt.size(980, 600)
        color: Ui.base
        onVisibleChanged: if (!visible) Qt.quit()

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // ---------- sidebar ----------
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
                        Text { text: "󰣇"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "BArch"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text { text: "center"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                    Repeater {
                        model: root.pages
                        Rectangle {
                            id: nav
                            required property var modelData
                            readonly property bool current: root.page === modelData.id
                            readonly property int marks: modelData.id === "services" ? Store.failedNow.length
                                                       : modelData.id === "failures" ? Store.failures.filter(f => Date.now() - f.time < 86400000).length
                                                       : modelData.id === "agent" ? Store.reports.filter((r, i, a) => a.findIndex(x => x.task === r.task) === i && r.status !== "ok").length
                                                       : 0
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Ui.radius
                            color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 8
                                Text { text: nav.modelData.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                Text { Layout.fillWidth: true; text: nav.modelData.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                                Rectangle {
                                    visible: nav.marks > 0
                                    width: mt.implicitWidth + 10; height: 16; radius: 8
                                    color: nav.modelData.id === "services" ? Ui.red : Ui.yellow
                                    Text { id: mt; anchors.centerIn: parent; text: nav.marks; color: Ui.crust; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                                }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    UiButton { Layout.fillWidth: true; label: "Refresh all"; icon: "󰑐"; small: true; onClicked: Store.refreshAll() }
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }

            // ---------- content ----------
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
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    Loader {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        sourceComponent: {
                            switch (root.page) {
                            case "services": return servicesC
                            case "timers": return timersC
                            case "failures": return failuresC
                            case "agent": return agentC
                            case "snapshots": return snapshotsC
                            case "journal": return journalC
                            default: return overviewC
                            }
                        }
                    }
                    LogPanel { Layout.rightMargin: 12; Layout.bottomMargin: 12 }
                }
                Component { id: overviewC; OverviewPage { onGo: p => root.page = p } }
                Component { id: servicesC; ServicesPage {} }
                Component { id: timersC; TimersPage {} }
                Component { id: failuresC; FailuresPage {} }
                Component { id: agentC; AgentPage {} }
                Component { id: snapshotsC; SnapshotsPage {} }
                Component { id: journalC; JournalPage {} }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        spacing: 12
                        Text { Layout.fillWidth: true; text: Store.status; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { text: Store.units.user.length + " user · " + Store.units.system.length + " system units"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
