import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// systemd services, user and system
Item {
    id: page
    property string scope: "user"
    property string filter: ""
    property bool showAll: false

    readonly property var rows: {
        const q = filter.trim().toLowerCase()
        const files = Store.unitFiles[scope] || {}
        let list = Store.units[scope] || []
        if (!showAll) list = list.filter(u => u.active !== "inactive" || (files[u.unit] && files[u.unit] !== "generated" && files[u.unit] !== "transient" && files[u.unit] !== "static"))
        if (!showAll) list = list.filter(u => !/^app-|^run-|^dbus-:/.test(u.unit) || u.active === "failed")
        if (q) list = list.filter(u => (u.unit + " " + u.description).toLowerCase().indexOf(q) !== -1)
        const rank = u => u.active === "failed" ? 0 : u.active === "activating" ? 1 : u.active === "active" ? 2 : 3
        return list.slice().sort((a, b) => rank(a) - rank(b) || a.unit.localeCompare(b.unit)).map(u => Object.assign({ enabled: files[u.unit] || "" }, u))
    }
    function stateColor(u) { return u.active === "failed" ? Ui.red : u.active === "active" ? Ui.green : u.active === "activating" || u.active === "deactivating" ? Ui.yellow : Ui.overlay }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            UiButton { label: "User"; primary: page.scope === "user"; onClicked: page.scope = "user" }
            UiButton { label: "System"; primary: page.scope === "system"; onClicked: page.scope = "system" }
            UiField { Layout.fillWidth: true; placeholderText: "filter services"; onTextChanged: page.filter = text }
            Text { text: "show all"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiSwitch { checked: page.showAll; onToggled: v => page.showAll = v }
            Text { text: page.rows.length + " units"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshUnits() }
        }
        Text {
            visible: page.scope === "system"
            Layout.leftMargin: 12; Layout.bottomMargin: 8
            text: "actions on system units ask for your password (polkit)"
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: parent.width
                spacing: 1
                Repeater {
                    model: page.rows
                    Rectangle {
                        id: r
                        required property var modelData
                        readonly property var u: modelData
                        Layout.fillWidth: true
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        implicitHeight: 44
                        radius: Ui.radius
                        color: rm.containsMouse ? Ui.faint : "transparent"
                        MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                            spacing: 10
                            Rectangle { width: 8; height: 8; radius: 4; color: page.stateColor(r.u) }
                            ColumnLayout {
                                Layout.preferredWidth: 330
                                spacing: 1
                                Text { Layout.fillWidth: true; text: r.u.unit; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; font.bold: r.u.active === "failed"; elide: Text.ElideMiddle }
                                Text { Layout.fillWidth: true; text: r.u.description; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                            }
                            Text { Layout.preferredWidth: 130; text: r.u.active + " (" + r.u.sub + ")"; color: page.stateColor(r.u); font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Text { Layout.preferredWidth: 80; text: r.u.enabled; color: r.u.enabled === "enabled" ? Ui.accent : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                            Item { Layout.fillWidth: true }
                            RowLayout {
                                spacing: 4
                                opacity: rm.containsMouse ? 1 : 0.35
                                UiButton { icon: "󰍜"; small: true; tooltip: "journal"; onClicked: Store.showJournal(page.scope, r.u.unit) }
                                UiButton { icon: "󰐊"; small: true; tooltip: "start"; visible: r.u.active !== "active"; onClicked: Store.unitAction(page.scope, "start", r.u.unit) }
                                UiButton { icon: "󰑐"; small: true; tooltip: "restart"; onClicked: Store.unitAction(page.scope, "restart", r.u.unit) }
                                UiButton { icon: "󰓛"; small: true; tooltip: "stop"; visible: r.u.active === "active" || r.u.active === "activating"; onClicked: Store.unitAction(page.scope, "stop", r.u.unit) }
                                UiButton { icon: "󰁪"; small: true; tooltip: "reset-failed"; visible: r.u.active === "failed"; onClicked: Store.unitAction(page.scope, "reset-failed", r.u.unit) }
                                UiButton { label: r.u.enabled === "enabled" ? "disable" : "enable"; small: true; visible: r.u.enabled === "enabled" || r.u.enabled === "disabled"
                                    onClicked: Store.unitAction(page.scope, r.u.enabled === "enabled" ? "disable" : "enable", r.u.unit) }
                            }
                        }
                    }
                }
                Item { height: 16 }
            }
        }
    }
}
