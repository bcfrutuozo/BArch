pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the reactive rules (agent/rules.json, run by barch-events) and the event log behind them
Item {
    id: page
    property string filter: ""
    readonly property bool running: Store.eventsService === "active"
    readonly property var shown: Store.events.filter(e => page.filter === "" || (e.event + " " + JSON.stringify(e.data)).toLowerCase().includes(page.filter.toLowerCase()))

    function whenText(w) {
        if (!w) return ""
        if (w.event) return "on " + w.event + Object.keys(w).filter(k => k !== "event").map(k => "  " + k + " ~ " + w[k]).join("")
        if (w.metric) return "when " + w.metric + (w.above !== undefined ? " > " + w.above : " < " + w.below) + (w.clear !== undefined ? "  (clears at " + w.clear + ")" : "")
        return JSON.stringify(w)
    }
    function dataText(d) {
        return Object.keys(d || {}).filter(k => d[k] !== "" && d[k] !== null && d[k] !== false).map(k => k + "=" + String(d[k]).slice(0, 50)).join("  ")
    }
    function eventTint(e) {
        if (e.startsWith("rule:")) return Ui.accent
        if (/down|removed|failure|locked$|disconnected|anon.off/.test(e)) return Ui.yellow
        if (/\.up$|added|unlocked|connected|anon.on|boot/.test(e)) return Ui.green
        return Ui.subtext
    }

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
                title: "barch-events  ·  " + (page.running ? "running" : "stopped")
                subtitle: "samples the machine every 30 s, listens to Hyprland, the VPN, the network, the AirPods and the lock, and runs the rules below (agent/rules.json)"
                headerItems: [
                    UiButton { label: page.running ? "Stop" : "Start"; small: true; danger: page.running; onClicked: Store.run(["systemctl", "--user", page.running ? "stop" : "start", "barch-events.service"], () => Store.refreshAutomation()) },
                    UiButton { label: "Edit rules.json"; icon: "󰏫"; small: true; onClicked: Store.editPath(Store.repo + "/agent/rules.json") },
                    UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshAutomation() }
                ]
            }

            // ---------- rules ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Rules"
                subtitle: Store.rules.filter(r => r.enabled).length + " of " + Store.rules.length + " enabled  ·  the switch edits rules.json, Run fires the actions now (the cooldown is ignored)"
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Repeater {
                        model: Store.rules
                        Rectangle {
                            id: row
                            required property var modelData
                            readonly property var r: modelData
                            Layout.fillWidth: true
                            implicitHeight: col.implicitHeight + 16
                            radius: Ui.radius
                            color: rm.containsMouse ? Ui.faint : "transparent"
                            opacity: r.enabled ? 1 : 0.55
                            MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 6; anchors.topMargin: 8; anchors.bottomMargin: 8
                                spacing: 10
                                UiSwitch { checked: row.r.enabled; onToggled: v => Store.ruleEnable(row.r.id, v) }
                                ColumnLayout {
                                    id: col
                                    Layout.fillWidth: true
                                    spacing: 2
                                    RowLayout {
                                        spacing: 8
                                        Text { text: row.r.id; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                                        Text { text: row.r.description; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight; Layout.fillWidth: true }
                                    }
                                    Text { Layout.fillWidth: true; text: page.whenText(row.r.when); color: Ui.accent; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                                    Text {
                                        Layout.fillWidth: true
                                        visible: text !== ""
                                        text: [(row.r.do || []).length ? "do: " + row.r.do.join("; ") : "",
                                               row.r.notify ? "notify: " + row.r.notify : "",
                                               row.r.say ? "say: " + row.r.say : "",
                                               row.r.ask ? "ask: " + row.r.ask : ""].filter(x => x).join("   ·   ")
                                        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight
                                    }
                                    Text {
                                        text: (row.r.last ? "last " + Store.ago(row.r.last * 1000) + (row.r.last_ok === false ? " (failed)" : "") : "never fired")
                                              + "  ·  " + row.r.fired_7d + "× in 7 days  ·  cooldown " + row.r.cooldown
                                        color: row.r.last_ok === false ? Ui.red : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3
                                    }
                                }
                                UiButton { label: "Run"; icon: "󰐊"; small: true; opacity: rm.containsMouse ? 1 : 0.35; onClicked: Store.ruleFire(row.r.id) }
                            }
                        }
                    }
                }
            }

            // ---------- events ----------
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Events"
                subtitle: "the last " + Store.events.length + " (barch events log); rules that fired show as rule:<id>"
                headerItems: [ UiField { implicitWidth: 220; placeholderText: "filter (window, vpn, rule:…)"; onTextChanged: page.filter = text } ]
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text { visible: page.shown.length === 0; text: "nothing yet"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Repeater {
                        model: page.shown
                        RowLayout {
                            id: entry
                            required property var modelData
                            readonly property var e: modelData
                            Layout.fillWidth: true
                            spacing: 10
                            Text { Layout.preferredWidth: 110; text: Qt.formatDateTime(new Date(entry.e.ts * 1000), "dd/MM HH:mm:ss"); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                            Badge { text: parent.e.event; tint: page.eventTint(parent.e.event) }
                            Text { Layout.fillWidth: true; text: page.dataText(parent.e.data); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                        }
                    }
                }
            }
        }
    }
}
