import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Pipewire

// one node: icon, name, peak meter, volume slider, mute; optional routing combo and default star
Rectangle {
    id: row
    required property var node
    property bool isDevice: false
    property bool isDefault: false
    property var routeTargets: []            // devices a stream can be moved to
    property var peer: null                  // the device the stream is connected to
    signal makeDefault()
    signal route(var device)

    readonly property bool muted: node && node.audio ? node.audio.muted : false
    readonly property real level: node && node.audio ? node.audio.volume : 0
    readonly property string icon: isDevice ? "" : Store.appIcon(node)

    Layout.fillWidth: true
    implicitHeight: 64
    radius: Ui.radius
    color: Ui.sunken
    border.width: 1
    border.color: isDefault ? Ui.accent : Ui.surface

    PwNodePeakMonitor { id: peak; node: row.node; enabled: true }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12; anchors.rightMargin: 10
        spacing: 12
        Item {
            Layout.preferredWidth: 30; Layout.preferredHeight: 30
            IconImage { anchors.fill: parent; visible: row.icon !== ""; source: row.icon; opacity: row.muted ? 0.4 : 1 }
            Text {
                anchors.centerIn: parent
                visible: row.icon === ""
                text: row.isDevice ? (row.node.isSink ? (row.muted ? "󰝟" : row.level > 0.5 ? "󰕾" : "󰖀") : (row.muted ? "󰍭" : "󰍬")) : (row.muted ? "󰝟" : "󰎆")
                color: row.muted ? Ui.overlay : Ui.text
                font.family: Ui.iconFont; font.pixelSize: 22
            }
        }
        ColumnLayout {
            Layout.preferredWidth: 300
            Layout.maximumWidth: 360
            spacing: 2
            RowLayout {
                spacing: 6
                Text { text: row.isDevice ? Store.title(row.node) : Store.appName(row.node); color: row.muted ? Ui.subtext : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight; Layout.maximumWidth: 280 }
                Badge { visible: row.isDefault; text: "default"; tint: Ui.accent }
                Badge { visible: !!Store.prop(row.node, "api.bluez5.codec"); text: Store.prop(row.node, "api.bluez5.codec").toUpperCase(); tint: Ui.green; tip: "Bluetooth codec in use" }
            }
            Text {
                Layout.fillWidth: true
                text: row.isDevice ? (Store.deviceFormats[row.node.name] || row.node.name) : Store.appDetail(row.node)
                color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle
            }
            // peak meter
            Rectangle {
                Layout.fillWidth: true
                height: 3; radius: 2
                color: Ui.surface
                Rectangle { width: parent.width * Math.min(1, peak.peak); height: parent.height; radius: 2; color: peak.peak > 0.9 ? Ui.red : Ui.green }
            }
        }
        UiButton { icon: row.muted ? "󰝟" : "󰕾"; small: true; tooltip: row.muted ? "unmute" : "mute"; onClicked: Store.toggleMute(row.node) }
        UiSlider {
            Layout.fillWidth: true
            Layout.minimumWidth: 120
            from: 0; to: 1.5; step: 0.01
            value: row.level
            onMoved: v => Store.setVolume(row.node, v)
            onReleased: v => Store.setVolume(row.node, v)
        }
        Text { Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight; text: Math.round(row.level * 100) + "%"; color: row.level > 1 ? Ui.yellow : Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
        UiCombo {
            visible: !row.isDevice
            Layout.preferredWidth: 230
            entries: row.routeTargets.map(d => ({ label: Store.title(d), value: d.name }))
            value: row.peer ? row.peer.name : ""
            onPicked: v => { const d = row.routeTargets.filter(x => x.name === v)[0]; if (d && (!row.peer || row.peer.name !== v)) row.route(d) }
        }
        UiButton { visible: row.isDevice && !row.isDefault; icon: "󰓎"; small: true; tooltip: "make default"; onClicked: row.makeDefault() }
    }
}
