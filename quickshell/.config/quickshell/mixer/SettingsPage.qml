import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the PipeWire clock (sample rate, quantum), Bluetooth, external mixers
Item {
    id: page
    readonly property var s: Store.settings
    property bool hasPavu: false
    property bool hasQpw: false
    property bool hasHelvum: false
    Component.onCompleted: { Store.has("pavucontrol", v => hasPavu = v); Store.has("qpwgraph", v => hasQpw = v); Store.has("helvum", v => hasHelvum = v) }

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
                title: "Sample rate"
                subtitle: "PipeWire follows the stream (clock.allowed-rates in audio/.config/pipewire) unless a rate is forced here; forcing applies at once and lasts until PipeWire restarts. The permanent values live in the repo's audio/ configs."
                RowLayout {
                    spacing: 10
                    Text { Layout.preferredWidth: 160; text: "graph rate now"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Text { text: (page.s["clock.rate"] || "?") + " Hz" + (page.s["clock.force-rate"] && page.s["clock.force-rate"] !== "0" ? "  (forced " + page.s["clock.force-rate"] + ")" : "  (automatic)"); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                }
                RowLayout {
                    spacing: 10
                    Text { Layout.preferredWidth: 160; text: "force rate"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    UiCombo {
                        Layout.preferredWidth: 220
                        entries: [{ label: "automatic", value: "0" }].concat(Store.allowedRates.map(r => ({ label: r + " Hz", value: String(r) })))
                        value: page.s["clock.force-rate"] || "0"
                        onPicked: v => Store.setSetting("clock.force-rate", v)
                    }
                    Text { text: "allowed: " + Store.allowedRates.join(", "); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                }
                RowLayout {
                    spacing: 10
                    Text { Layout.preferredWidth: 160; text: "quantum (latency)"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    UiCombo {
                        Layout.preferredWidth: 220
                        entries: [{ label: "automatic", value: "0" }].concat([32, 64, 128, 256, 512, 1024, 2048].map(q => ({ label: q + " samples", value: String(q) })))
                        value: page.s["clock.force-quantum"] || "0"
                        onPicked: v => Store.setSetting("clock.force-quantum", v)
                    }
                    Text { text: "now " + (page.s["clock.quantum"] || "?") + "  ·  min " + (page.s["clock.min-quantum"] || "?") + "  ·  max " + (page.s["clock.max-quantum"] || "?") + (page.s["clock.rate"] && page.s["clock.quantum"] ? "  ·  " + (Number(page.s["clock.quantum"]) / Number(page.s["clock.rate"]) * 1000).toFixed(1) + " ms" : ""); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                }
                ColumnLayout {
                    spacing: 2
                    Text { text: "device formats (pactl)"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    Repeater {
                        model: Object.keys(Store.deviceFormats)
                        RowLayout {
                            required property var modelData
                            Text { Layout.preferredWidth: 520; text: modelData; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle }
                            Text { text: Store.deviceFormats[modelData]; color: Ui.accent; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                    }
                }
            }
            Card {
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Bluetooth"
                subtitle: "headsets are output only here (audio/.config/wireplumber): AAC first, then SBC-XQ, SBC; the headset profile (HFP, 16 kHz mono) is off so a call never degrades the music"
                Repeater {
                    model: Store.bluetooth
                    RowLayout {
                        id: br
                        required property var modelData
                        spacing: 10
                        Text { text: "󰂯"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 4 }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: Store.title(br.modelData); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true }
                            Text { text: Store.prop(br.modelData, "api.bluez5.address") + "  ·  " + br.modelData.name; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                        }
                        Badge { text: "codec " + (Store.prop(br.modelData, "api.bluez5.codec") || "?").toUpperCase(); tint: Ui.green }
                        Badge { text: Store.prop(br.modelData, "api.bluez5.profile") || "a2dp"; tint: Ui.subtext }
                    }
                }
                Text { visible: Store.bluetooth.length === 0; text: "no Bluetooth audio device connected (the Bluetooth tile of the bar connects them)"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "More"
                RowLayout {
                    spacing: 6
                    UiButton { visible: page.hasPavu; label: "pavucontrol"; small: true; onClicked: Store.launch("pavucontrol") }
                    UiButton { visible: page.hasQpw; label: "qpwgraph (patchbay)"; small: true; onClicked: Store.launch("qpwgraph") }
                    UiButton { visible: page.hasHelvum; label: "helvum"; small: true; onClicked: Store.launch("helvum") }
                    UiButton { label: "wpctl status"; small: true; onClicked: Quickshell.execDetached(["setsid", "-f", "foot", "-T", "wpctl status", "-e", "sh", "-c", 'wpctl status; printf "\\n[Enter to close] "; read -r _']) }
                    UiButton { label: "restart PipeWire"; small: true; danger: true; tooltip: "systemctl --user restart pipewire pipewire-pulse wireplumber"; onClicked: Quickshell.execDetached(["systemctl", "--user", "restart", "pipewire", "pipewire-pulse", "wireplumber"]) }
                }
            }
            Item { height: 12 }
        }
    }
}
