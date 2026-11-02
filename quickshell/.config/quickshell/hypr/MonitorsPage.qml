import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// every output: what it is doing now (hyprctl monitors) and the fields of hl.monitor
Item {
    id: page

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12
            Text {
                Layout.margins: 12; Layout.bottomMargin: 0
                Layout.fillWidth: true
                text: "A field changed here is saved for that output and applied on top of conf/monitors.lua (BArch.monitors); the bar's own live changes (HDR, SDR brightness) still win while the session runs."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
            }
            Repeater {
                model: Store.monitors
                Card {
                    id: card
                    required property var modelData
                    readonly property string name: modelData.name
                    readonly property var live: H.monitorLive(modelData)
                    readonly property var saved: Store.monitorSettings(name)
                    readonly property var hw: modelData.hardwareDetails || ({})
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    title: name + "  ·  " + (modelData.description || "")
                    subtitle: live.mode + "  ·  at " + live.position + "  ·  scale " + live.scale + "  ·  " + (modelData.currentFormat || "") + "  ·  " + (modelData.colorManagementPreset || "")
                              + (hw.hdr ? "  ·  HDR on" : "") + (hw.vrrCapable ? "  ·  VRR capable" : "") + (modelData.disabled ? "  ·  DISABLED" : "")
                    headerItems: [
                        UiButton { label: "Reset output"; small: true; danger: true; enabledBtn: Object.keys(card.saved).length > 0; onClicked: Store.resetMonitor(card.name) }
                    ]
                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: 24
                        rowSpacing: 4
                        Repeater {
                            model: H.MONITOR_FIELDS
                            RowLayout {
                                id: f
                                required property var modelData
                                readonly property string fid: modelData.id
                                readonly property bool set: fid in card.saved
                                readonly property var value: set ? card.saved[fid] : card.live[fid]
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    Layout.preferredWidth: 150
                                    text: f.modelData.label
                                    color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize
                                    MouseArea { id: lm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                    Tip { text: f.modelData.hint || ""; when: lm.containsMouse }
                                }
                                Loader {
                                    Layout.fillWidth: f.modelData.kind !== "bool"
                                    sourceComponent: {
                                        switch (f.modelData.kind) {
                                        case "bool": return boolC
                                        case "enum": return enumC
                                        case "choice": case "mode": case "pos": return choiceC
                                        case "float": case "int": return f.value === undefined ? textC : numC
                                        default: return textC
                                        }
                                    }
                                    Component { id: boolC; UiSwitch { checked: f.value === true; onToggled: v => Store.setMonitor(card.name, f.fid, v) } }
                                    Component { id: enumC; UiCombo { entries: f.modelData.values; value: f.value; onPicked: v => Store.setMonitor(card.name, f.fid, v) } }
                                    Component {
                                        id: choiceC
                                        UiCombo {
                                            editable: true
                                            entries: (f.modelData.kind === "mode" ? ["preferred", "highres", "highrr"].concat(H.uniqueModes(card.modelData.availableModes))
                                                    : f.modelData.kind === "pos" ? H.POSITIONS : f.modelData.choices).map(c => ({ label: c, value: c }))
                                            value: f.value === undefined ? "" : String(f.value)
                                            onPicked: v => Store.setMonitor(card.name, f.fid, String(v))
                                        }
                                    }
                                    Component {
                                        id: numC
                                        UiNumber {
                                            value: Number(f.value)
                                            min: f.modelData.min; max: f.modelData.max
                                            integer: f.modelData.kind === "int"
                                            step: f.modelData.step || (f.modelData.kind === "int" ? 1 : 0.01)
                                            onChanged: v => Store.setMonitor(card.name, f.fid, v)
                                        }
                                    }
                                    Component {
                                        id: textC
                                        UiField {
                                            text: f.value === undefined ? "" : String(f.value)
                                            placeholderText: f.modelData.hint || "not set"
                                            onCommitted: v => {
                                                if (v.trim() === "") { if (f.set) Store.resetMonitorField(card.name, f.fid); return }
                                                const n = Number(v)
                                                Store.setMonitor(card.name, f.fid, (f.modelData.kind === "int" || f.modelData.kind === "float") && !isNaN(n) ? n : v)
                                            }
                                        }
                                    }
                                }
                                Item { Layout.fillWidth: f.modelData.kind === "bool" }
                                Badge { visible: f.set; text: "app"; tint: Ui.accent; tip: "saved by this app" }
                                UiButton { icon: "󰦛"; small: true; tooltip: "forget this field (back to conf/monitors.lua)"; opacity: f.set ? 1 : 0; enabledBtn: f.set; onClicked: Store.resetMonitorField(card.name, f.fid) }
                            }
                        }
                    }
                }
            }
            // outputs saved but not connected now
            Repeater {
                model: Object.keys(Store.settings.monitors || {}).filter(n => !Store.monitors.some(m => m.name === n))
                Card {
                    id: gone
                    required property var modelData
                    Layout.leftMargin: 12; Layout.rightMargin: 12
                    title: modelData + "  ·  not connected"
                    subtitle: JSON.stringify(Store.monitorSettings(modelData))
                    headerItems: [ UiButton { label: "Forget"; small: true; danger: true; onClicked: Store.resetMonitor(gone.modelData) } ]
                }
            }
            Item { height: 12 }
        }
    }
}
