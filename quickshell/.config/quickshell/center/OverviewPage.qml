import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the state of the machine at a glance
Item {
    id: page
    signal go(string p)

    readonly property var h: Store.health
    readonly property bool hOk: h.loaded === true
    readonly property int failures24h: Store.failures.filter(f => Date.now() - f.time < 86400000).length
    readonly property var nextTimers: Store.timers.user.concat(Store.timers.system).filter(t => t.next).sort((a, b) => a.next - b.next).slice(0, 6)
    readonly property var openSnapshots: Store.snapshots.filter(s => s.post === null || s.post === undefined)
    readonly property var latestByTask: {
        const seen = {}, out = []
        for (const r of Store.reports) if (!seen[r.task]) { seen[r.task] = true; out.push(r) }
        return out
    }
    function statusColor(s) { return s === "ok" ? Ui.green : s === "warn" ? Ui.yellow : s === "alert" ? Ui.red : Ui.subtext }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12

            // ---------- health ----------
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: "System health" + (page.hOk ? (page.h.issues === 0 ? "  ·  ok" : "  ·  " + page.h.issues + " issue" + (page.h.issues === 1 ? "" : "s")) : "")
                subtitle: page.hOk ? "checked " + Store.ago(page.h.checkedAt) + (page.h.running ? "  ·  checking…" : "") : "not checked yet (the bar checks ~45 s after it starts)"
                headerItems: [ UiButton { label: "Check now"; icon: "󰑐"; small: true; onClicked: Store.refreshHealth(true) } ]
                Flow {
                    Layout.fillWidth: true
                    spacing: 10
                    component Tile: Rectangle {
                        property string label: ""
                        property string value: ""
                        property color tint: Ui.subtext
                        property string page_: ""
                        width: 200; height: 64; radius: Ui.radius
                        color: Ui.sunken; border.width: 1; border.color: Ui.surface
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 10; spacing: 2
                            Text { text: parent.parent.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Text { text: parent.parent.value; color: parent.parent.tint; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: parent.page_ ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: if (parent.page_) page.go(parent.page_) }
                    }
                    Tile { label: "failed units now"; value: String(Store.failedNow.length); tint: Store.failedNow.length ? Ui.red : Ui.green; page_: "services" }
                    Tile { label: "failures in 24 h"; value: String(page.failures24h); tint: page.failures24h ? Ui.yellow : Ui.green; page_: "failures" }
                    Tile { label: ".pacnew / .pacsave"; value: page.hOk ? String((page.h.pacnew || []).length) : "—"; tint: page.hOk && page.h.pacnew.length ? Ui.yellow : Ui.green }
                    Tile { label: "TPM unlock"; value: page.hOk ? String(page.h.tpm || "?") : "—"; tint: page.h.tpm === "failed" ? Ui.red : Ui.green }
                    Tile {
                        label: "backup"
                        readonly property var b: page.h.backup || ({})
                        value: !page.hOk ? "—" : b.configured === false && !b.at ? "not set up" : !b.at ? "never ran" : (b.ok ? "ok" : "FAILED") + "  ·  " + Store.ago(b.at * 1000)
                        tint: page.hOk && b.ok && !page.h.backupLate ? Ui.green : Ui.yellow
                    }
                    Tile { label: "cleanup"; value: page.hOk && page.h.clean ? (page.h.cleanupDue ? "due" : "not due") + "  ·  cache " + page.h.clean.cache + ", journal " + page.h.clean.journal + ", " + page.h.clean.orphans + " orphans" : "—"; tint: page.hOk && page.h.cleanupDue ? Ui.yellow : Ui.subtext; width: 420 }
                    Tile { label: "open safety snapshots"; value: String(page.openSnapshots.length) + (page.openSnapshots.length ? "  (session running or never ended)" : ""); tint: Ui.subtext; page_: "snapshots"; width: 300 }
                }
                Text { visible: page.hOk && page.h.tpm === "failed"; text: String(page.h.reenroll || ""); color: Ui.yellow; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                Repeater { model: page.hOk ? page.h.pacnew : []; Text { required property var modelData; text: modelData; color: Ui.yellow; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 } }
            }

            // ---------- failed now ----------
            Card {
                visible: Store.failedNow.length > 0
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Failed units"
                Repeater {
                    model: Store.failedNow
                    RowLayout {
                        required property var modelData
                        spacing: 8
                        Text { Layout.fillWidth: true; text: modelData.unit + "  (" + modelData.scope + ")"; color: Ui.red; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        UiButton { label: "journal"; small: true; onClicked: Store.showJournal(parent.modelData.scope, parent.modelData.unit) }
                        UiButton { label: "restart"; small: true; onClicked: Store.unitAction(parent.modelData.scope, "restart", parent.modelData.unit) }
                        UiButton { label: "reset"; small: true; tooltip: "systemctl reset-failed"; onClicked: Store.unitAction(parent.modelData.scope, "reset-failed", parent.modelData.unit) }
                    }
                }
            }

            // ---------- agent ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Agent reports"
                subtitle: "the latest run of each scheduled task"
                headerItems: [ UiButton { label: "Agent"; icon: "󰁔"; small: true; onClicked: page.go("agent") } ]
                Repeater {
                    model: page.latestByTask
                    RowLayout {
                        id: rr
                        required property var modelData
                        spacing: 8
                        Rectangle { width: 8; height: 8; radius: 4; color: page.statusColor(rr.modelData.status) }
                        Text { Layout.preferredWidth: 130; text: rr.modelData.task; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.fillWidth: true; text: rr.modelData.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                        Text { text: String(rr.modelData.time).slice(0, 16).replace("T", " "); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        UiButton { icon: "󰈙"; small: true; tooltip: "open the report"; onClicked: Store.showFile(rr.modelData.task + " · " + rr.modelData.title, rr.modelData.report) }
                    }
                }
                Text { visible: page.latestByTask.length === 0; text: "no reports yet"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }

            // ---------- timers ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Next timers"
                headerItems: [ UiButton { label: "Timers"; icon: "󰁔"; small: true; onClicked: page.go("timers") } ]
                Repeater {
                    model: page.nextTimers
                    RowLayout {
                        required property var modelData
                        spacing: 8
                        Text { Layout.preferredWidth: 300; text: modelData.unit; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { Layout.fillWidth: true; text: Store.pretty(modelData.next); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    }
                }
            }
            Item { height: 12 }
        }
    }
}
