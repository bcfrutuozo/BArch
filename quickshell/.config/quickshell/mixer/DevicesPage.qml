import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// outputs and inputs
Item {
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
                title: "Outputs"
                subtitle: "speakers, headsets, HDMI; the starred one is where new apps play"
                Repeater {
                    model: Store.sinks
                    NodeRow { required property var modelData; node: modelData; isDevice: true; isDefault: Store.defaultSink === modelData; onMakeDefault: Store.setDefaultSink(modelData) }
                }
                Text { visible: Store.sinks.length === 0; text: "no outputs"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Inputs"
                subtitle: "microphones; the starred one is what apps record from"
                Repeater {
                    model: Store.sources
                    NodeRow { required property var modelData; node: modelData; isDevice: true; isDefault: Store.defaultSource === modelData; onMakeDefault: Store.setDefaultSource(modelData) }
                }
                Text { visible: Store.sources.length === 0; text: "no inputs"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
            Item { height: 12 }
        }
    }
}
