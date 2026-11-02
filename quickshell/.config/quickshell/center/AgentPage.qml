import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the scheduled tasks, their reports, ask Claude
Item {
    id: page
    property string openTask: ""

    function statusColor(s) { return s === "ok" ? Ui.green : s === "warn" ? Ui.yellow : s === "alert" ? Ui.red : Ui.subtext }
    function next(t) { return t.next ? t.next.replace(/ -03$| [A-Z]{3,4}$/, "") : "" }

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
                title: "Ask Claude"
                subtitle: "a new session in ~/BArch, in a terminal (the launcher's \"a \")"
                RowLayout {
                    spacing: 6
                    UiField { id: ask; Layout.fillWidth: true; placeholderText: "why is the boot slower this week?"; onAccepted: if (text.trim()) { Store.ask(text.trim()); text = "" } }
                    UiButton { label: "Ask"; primary: true; enabledBtn: ask.text.trim() !== ""; onClicked: { Store.ask(ask.text.trim()); ask.text = "" } }
                }
            }

            Repeater {
                model: Store.tasks
                Card {
                    id: tc
                    required property var modelData
                    readonly property var t: modelData
                    readonly property var last: t.last || null
                    readonly property var history: Store.reports.filter(r => r.task === tc.t.task)
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    title: t.task + "  ·  " + t.description
                    subtitle: "timer " + t.timer + (page.next(t) ? "  ·  next " + page.next(t) : "")
                    headerItems: [
                        UiButton { label: "Run now"; icon: "󰐊"; small: true; onClicked: Store.runTask(tc.t.task) },
                        UiButton { label: tc.history.length ? "history (" + tc.history.length + ")" : "history"; small: true; enabledBtn: tc.history.length > 0; onClicked: page.openTask = page.openTask === tc.t.task ? "" : tc.t.task }
                    ]
                    RowLayout {
                        visible: tc.last !== null
                        spacing: 8
                        Rectangle { width: 10; height: 10; radius: 5; color: page.statusColor(tc.last ? tc.last.status : "") }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { Layout.fillWidth: true; text: tc.last ? tc.last.title : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; wrapMode: Text.Wrap }
                            Text { Layout.fillWidth: true; text: tc.last ? tc.last.summary : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap }
                            Text { text: tc.last ? String(tc.last.time).slice(0, 16).replace("T", " ") + "  ·  $" + Number(tc.last.cost || 0).toFixed(2) : ""; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                        UiButton { label: "Report"; icon: "󰈙"; small: true; onClicked: Store.showFile(tc.t.task + " · " + tc.last.title, tc.last.report) }
                        UiButton { label: "Continue"; icon: "󰚩"; small: true; tooltip: "resume the session in a terminal"; onClicked: Store.continueSession(tc.last.session) }
                    }
                    Text { visible: tc.last === null; text: "never ran"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Repeater {
                        model: page.openTask === tc.t.task ? tc.history : []
                        RowLayout {
                            id: hr
                            required property var modelData
                            spacing: 8
                            Rectangle { width: 8; height: 8; radius: 4; color: page.statusColor(hr.modelData.status) }
                            Text { Layout.preferredWidth: 130; text: String(hr.modelData.time).slice(0, 16).replace("T", " "); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                            Text { Layout.fillWidth: true; text: hr.modelData.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                            Text { text: "$" + Number(hr.modelData.cost || 0).toFixed(2); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                            UiButton { icon: "󰈙"; small: true; tooltip: "report"; onClicked: Store.showFile(hr.modelData.task + " · " + hr.modelData.title, hr.modelData.report) }
                            UiButton { icon: "󰚩"; small: true; tooltip: "continue this session"; onClicked: Store.continueSession(hr.modelData.session) }
                        }
                    }
                }
            }
            Text { visible: Store.tasks.length === 0; Layout.margins: 12; text: "no tasks (agent/tasks/*.md)"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
            Item { height: 12 }
        }
    }
}
