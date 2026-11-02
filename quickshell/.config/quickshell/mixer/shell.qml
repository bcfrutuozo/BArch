// shell.qml — BArch Mixer: PipeWire in one window. Outputs and inputs with volume, mute, peak
// meters and the default; every app playing or recording with its own volume and the device it
// is routed to; sample rate and quantum; the Bluetooth codec. Own Shell ID; controls from ../ui.
//
//   qs -p ~/.config/quickshell/mixer             barch mixer [devices|apps|settings]

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "devices"
    readonly property var pages: [
        { id: "devices",  label: "Devices",  icon: "󰕾" },
        { id: "apps",     label: "Apps",     icon: "󰎆" },
        { id: "settings", label: "Settings", icon: "󰒓" }
    ]
    function open(p) { if (p && pages.some(x => x.id === p)) page = p; win.visible = true }
    Component.onCompleted: { const p = Quickshell.env("BARCH_MIXER_PAGE"); if (p) open(p) }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function close(): void { Qt.quit() }
        // scripting / debugging: every audio node as JSON
        function nodes(): string {
            return JSON.stringify(Store.nodes.map(n => ({ id: n.id, name: n.name, description: n.description, isSink: n.isSink, isStream: n.isStream, type: Number(n.type), hasAudio: !!n.audio, cls: Store.cls(n), serial: Store.prop(n, "object.serial") })))
        }
    }

    FloatingWindow {
        id: win
        title: "BArch Mixer"
        implicitWidth: 1240
        implicitHeight: 800
        minimumSize: Qt.size(900, 520)
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
                        Text { text: "󰕾"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        ColumnLayout {
                            spacing: 0
                            Text { text: "Mixer"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                            Text { text: "PipeWire " + (Store.settings["clock.rate"] ? Store.settings["clock.rate"] + " Hz" : ""); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                    Repeater {
                        model: root.pages
                        Rectangle {
                            id: nav
                            required property var modelData
                            readonly property bool current: root.page === modelData.id
                            readonly property int marks: modelData.id === "apps" ? Store.playback.length + Store.recording.length : 0
                            Layout.fillWidth: true
                            implicitHeight: 32
                            radius: Ui.radius
                            color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 8
                                Text { text: nav.modelData.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                Text { Layout.fillWidth: true; text: nav.modelData.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                                Text { visible: nav.marks > 0; text: nav.marks; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                            }
                            MouseArea { id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.page = nav.modelData.id }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 54; radius: Ui.radius
                        color: Ui.sunken; border.width: 1; border.color: Ui.surface
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 8; spacing: 1
                            Text { text: "default output"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                            Text { Layout.fillWidth: true; text: Store.title(Store.defaultSink) || "—"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        }
                    }
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
                    sourceComponent: root.page === "apps" ? appsC : root.page === "settings" ? settingsC : devicesC
                }
                Component { id: devicesC; DevicesPage {} }
                Component { id: appsC; AppsPage {} }
                Component { id: settingsC; SettingsPage {} }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        Text { Layout.fillWidth: true; text: Store.status; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { text: Store.sinks.length + " outputs · " + Store.sources.length + " inputs · " + Store.playback.length + " playing"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
