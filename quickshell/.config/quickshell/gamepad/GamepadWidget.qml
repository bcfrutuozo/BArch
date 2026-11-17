// Gamepads on Bluetooth (the Xbox Series controller): an icon and the battery in the bar while one
// is connected, the same place and look as the AirPods. Everything comes from BlueZ
// (Quickshell.Bluetooth: a device whose icon is "input-gaming"), so there is no daemon.
// Left click: the panel (battery of each controller, vibrate to tell which is which, disconnect).
// Right click: vibrate. A notification when a battery reaches lowLevel, once per discharge.
// IPC "gamepad" (barch gamepad): status, rumble, disconnect.

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import "../theme"

Item {
    id: root

    // the bar's island this widget sits in; the panel lines up with it
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    readonly property int lowLevel: 15
    readonly property string rumbleScript: Quickshell.shellDir + "/gamepad/rumble.py"

    readonly property var pads: Bluetooth.devices.values
        .filter(d => d.connected && d.icon === "input-gaming")
        .sort((a, b) => a.name.localeCompare(b.name))
    // the emptiest battery is the one the bar shows
    readonly property var barPad: pads.length === 0 ? null : pads.reduce((low, d) =>
        (level(d) >= 0 && (level(low) < 0 || level(d) < level(low))) ? d : low)

    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight
    visible: pads.length > 0

    function level(d) { return d && d.batteryAvailable ? Math.round(d.battery * 100) : -1 }
    function levelText(d) { const l = level(d); return l < 0 ? "?" : l + "%" }
    function glyph(d) {
        const xbox = d && d.name.toLowerCase().includes("xbox")
        if (!xbox) return String.fromCodePoint(0xF0297)              // md-gamepad_variant
        const l = level(d)
        if (l < 0) return String.fromCodePoint(0xF05BA)              // md-microsoft_xbox_controller
        return String.fromCodePoint(l <= root.lowLevel ? 0xF074B     // ..._battery_alert
            : l <= 40 ? 0xF074E : l <= 75 ? 0xF074F : 0xF074D)       // _low, _medium, _full
    }
    function low(d) { const l = level(d); return l >= 0 && l <= root.lowLevel }

    function find(address) {
        if (!address) return root.pads.length > 0 ? root.pads[0] : null
        return root.pads.find(d => d.address.toLowerCase() === address.toLowerCase()) || null
    }
    function rumble(d) {
        if (!d) return
        Quickshell.execDetached(["python3", "-I", root.rumbleScript, d.address, "400", "70"])
    }
    function status() {
        return {
            ok: true,
            gamepads: root.pads.map(d => ({
                name: d.name, address: d.address, battery: root.level(d),
                adapter: d.adapter ? d.adapter.name : ""
            }))
        }
    }

    // ---- low battery: one notification per discharge (again only after it climbs back) ----
    property var warned: ({})
    function checkBattery() {
        const next = {}
        for (const d of root.pads) {
            const l = root.level(d)
            if (l < 0) continue
            const was = root.warned[d.address] === true
            if (l <= root.lowLevel && !was)
                Quickshell.execDetached(["barch", "notify", d.name, "Battery at " + l + "%: charge it or swap the batteries.",
                                         "--app", "Gamepad"])
            next[d.address] = l <= root.lowLevel || (was && l < root.lowLevel + 10)
        }
        root.warned = next
    }
    Instantiator {
        model: root.pads
        delegate: Connections {
            required property var modelData
            target: modelData
            function onBatteryChanged() { root.checkBattery() }
        }
    }
    onPadsChanged: checkBattery()

    IpcHandler {
        target: "gamepad"
        function status(): string { return JSON.stringify(root.status()) }
        function rumble(address: string): string {
            const d = root.find(address)
            if (!d) return JSON.stringify({ ok: false, error: address ? "no connected gamepad " + address : "no gamepad connected" })
            root.rumble(d)
            return JSON.stringify(root.status())
        }
        function disconnect(address: string): string {
            const d = root.find(address)
            if (!d) return JSON.stringify({ ok: false, error: address ? "no connected gamepad " + address : "no gamepad connected" })
            d.disconnect()
            return JSON.stringify({ ok: true, disconnected: d.address })
        }
    }

    // ---- bar item: icon and battery, spaced like the volume and the AirPods ----
    Row {
        id: pill
        spacing: 5
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(root.barPad)
            color: root.low(root.barPad) ? Theme.crit : Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize + 2
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.levelText(root.barPad) + (root.pads.length > 1 ? "  ×" + root.pads.length : "")
            color: root.low(root.barPad) ? Theme.crit : Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) root.rumble(root.barPad)
            else Popups.toggle(popup)
        }
    }

    component Label: Text {
        color: Theme.fg
        font.family: Theme.font
        font.pixelSize: Theme.fontSize
    }

    component Entry: Rectangle {
        id: entry
        property string label: ""
        property color tone: Theme.fg
        signal activated()
        Layout.fillWidth: true
        implicitHeight: 30
        radius: 6
        color: hover.containsMouse ? Theme.border : "transparent"
        Label {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 8
            text: entry.label
            color: entry.tone
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: entry.activated()
        }
    }

    // ---- panel ----
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 300
        implicitHeight: body.implicitHeight + 24
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            radius: Theme.popupRadius

            ColumnLayout {
                id: body
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Repeater {
                    model: root.pads
                    delegate: ColumnLayout {
                        id: pad
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            visible: pad.index > 0
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: Theme.border
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label {
                                text: root.glyph(pad.modelData)
                                font.pixelSize: Theme.fontSize + 8
                                color: root.low(pad.modelData) ? Theme.crit : Theme.fg
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Label { text: pad.modelData.name; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                Label {
                                    text: "Bluetooth" + (pad.modelData.adapter ? "  ·  " + pad.modelData.adapter.name : "")
                                    color: Theme.dim
                                    font.pixelSize: Theme.fontSize - 2
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            Label {
                                text: root.levelText(pad.modelData)
                                font.pixelSize: Theme.fontSize + 4
                                color: root.low(pad.modelData) ? Theme.crit : Theme.fg
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 4
                            radius: 2
                            color: Theme.border
                            Rectangle {
                                width: parent.width * Math.max(0, root.level(pad.modelData)) / 100
                                height: parent.height
                                radius: 2
                                color: root.low(pad.modelData) ? Theme.crit : Theme.good
                            }
                        }
                        Entry { label: "Vibrate"; onActivated: root.rumble(pad.modelData) }
                        Entry { label: "Disconnect"; tone: Theme.dim; onActivated: pad.modelData.disconnect() }
                    }
                }
            }
        }
    }
}
