import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the last run, the schedule, the repository
Item {
    id: page
    readonly property var l: Store.last
    readonly property var s: l.summary || null
    readonly property bool ran: !!l.at

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: !Store.configured ? "Backup not set up" : !page.ran ? "Backup never ran" : (page.l.ok ? "Last backup ok" : "Last backup FAILED") + "  ·  " + Store.ago(page.l.at * 1000)
                subtitle: !Store.configured ? "barch backup init creates the repository and the password (keep it in Bitwarden)"
                        : page.ran ? Qt.formatDateTime(new Date(page.l.at * 1000), "dddd dd/MM/yyyy HH:mm") + (page.l.error ? "  ·  " + page.l.error : "") : ""
                headerItems: [
                    UiButton { label: "Run backup now"; icon: "󰐊"; primary: true; small: true; enabledBtn: Store.configured; onClicked: Store.runBackup() },
                    UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshAll() }
                ]
                Flow {
                    visible: page.s !== null
                    Layout.fillWidth: true
                    spacing: 10
                    component Tile: Rectangle {
                        property string label: ""
                        property string value: ""
                        width: 190; height: 62; radius: Ui.radius
                        color: Ui.sunken; border.width: 1; border.color: Ui.surface
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 10; spacing: 2
                            Text { text: parent.parent.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Text { text: parent.parent.value; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                        }
                    }
                    Tile { label: "files processed"; value: page.s ? String(page.s.total_files_processed) : "" }
                    Tile { label: "new / changed"; value: page.s ? page.s.files_new + " / " + page.s.files_changed : "" }
                    Tile { label: "data added"; value: page.s ? Store.human(page.s.data_added) + " (" + Store.human(page.s.data_added_packed) + " packed)" : ""; width: 260 }
                    Tile { label: "took"; value: page.s ? Number(page.s.total_duration).toFixed(1) + " s" : "" }
                    Tile { label: "snapshot"; value: page.s ? Store.short(page.s.snapshot_id) : "" }
                }
            }
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Repository"
                subtitle: Store.repo
                headerItems: [ UiButton { icon: "󰏫"; small: true; tooltip: "open the folder"; onClicked: Quickshell.execDetached(["xdg-open", Store.repo]) } ]
                RowLayout {
                    spacing: 8
                    Text { Layout.preferredWidth: 160; text: "next scheduled run"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Text { text: Store.nextRun || "timer not enabled (systemctl --user enable --now barch-backup.timer)"; color: Store.nextRun ? Ui.text : Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                }
                RowLayout {
                    spacing: 8
                    Text { Layout.preferredWidth: 160; text: "snapshots"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Text { text: Store.ready ? Store.snapshots.length + "  (14 daily, 8 weekly, 12 monthly kept; pruned on Sundays)" : "reading…"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                }
                RowLayout {
                    spacing: 8
                    Text { Layout.preferredWidth: 160; text: "password"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Text { text: Store.passPath + (Store.configured ? "" : "  (missing)"); color: Store.configured ? Ui.text : Ui.red; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                }
                RowLayout {
                    spacing: 8
                    Text { Layout.preferredWidth: 160; text: "what goes in"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Text { text: "backup/include.txt and exclude.txt in the repo; the root-only files come through barch-backup-root.timer"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                }
                RowLayout {
                    spacing: 6
                    UiButton { label: "Check repository"; small: true; tooltip: "restic check in a terminal"; onClicked: Store.terminal("restic check", "RESTIC_REPOSITORY=" + Store.repo + " RESTIC_PASSWORD_FILE=" + Store.passPath + " restic check") }
                    UiButton { label: "Unlock"; small: true; tooltip: "restic unlock: remove a stale lock after an interrupted run"; onClicked: Store.terminal("restic unlock", "RESTIC_REPOSITORY=" + Store.repo + " RESTIC_PASSWORD_FILE=" + Store.passPath + " restic unlock") }
                    UiButton { label: "Backup journal"; small: true; onClicked: Store.terminal("barch-backup", "journalctl --user -u barch-backup.service -n 100 --no-pager") }
                }
            }
            Item { height: 12 }
        }
    }
}
