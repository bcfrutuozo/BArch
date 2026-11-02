import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// systemd timers, user and system: when they ran, when they run next, run now
Item {
    id: page

    readonly property var rows: {
        const out = []
        for (const scope of ["user", "system"])
            for (const t of Store.timers[scope] || []) out.push(Object.assign({ scope: scope, enabled: (Store.unitFiles[scope] || {})[t.unit] || "" }, t))
        return out.sort((a, b) => (a.next || 9e18) - (b.next || 9e18))
    }

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
                Text { text: page.rows.length + " timers, next first"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; Layout.fillWidth: true }
                UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshUnits() }
            }
            Repeater {
                model: page.rows
                Rectangle {
                    id: r
                    required property var modelData
                    readonly property var t: modelData
                    Layout.fillWidth: true
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    implicitHeight: 44
                    radius: Ui.radius
                    color: rm.containsMouse ? Ui.faint : "transparent"
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                        spacing: 10
                        ColumnLayout {
                            Layout.preferredWidth: 320
                            spacing: 1
                            Text { Layout.fillWidth: true; text: r.t.unit; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                            Text { Layout.fillWidth: true; text: "→ " + r.t.activates + "  ·  " + r.t.scope; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                        }
                        ColumnLayout {
                            Layout.preferredWidth: 220
                            spacing: 1
                            Text { text: "next  " + Store.pretty(r.t.next); color: r.t.next ? Ui.text : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Text { text: "last  " + (r.t.last ? Store.pretty(r.t.last) + "  (" + Store.ago(r.t.last / 1000) + ")" : "never"); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                        }
                        Text { Layout.preferredWidth: 80; text: r.t.enabled; color: r.t.enabled === "enabled" ? Ui.accent : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        Item { Layout.fillWidth: true }
                        RowLayout {
                            spacing: 4
                            opacity: rm.containsMouse ? 1 : 0.35
                            UiButton { icon: "󰍜"; small: true; tooltip: "journal of the service"; onClicked: Store.showJournal(r.t.scope, r.t.activates) }
                            UiButton { icon: "󰐊"; small: true; tooltip: "run the service now"; onClicked: Store.unitAction(r.t.scope, "start", r.t.activates) }
                            UiButton { label: r.t.enabled === "enabled" ? "disable" : "enable"; small: true; visible: r.t.enabled === "enabled" || r.t.enabled === "disabled"
                                onClicked: Store.unitAction(r.t.scope, r.t.enabled === "enabled" ? "disable" : "enable", r.t.unit) }
                        }
                    }
                }
            }
            Item { height: 16 }
        }
    }
}
