import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// what is playing and recording, each with its own volume and the device it goes to
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
                title: "Playback"
                subtitle: "apps with a stream open; the combo moves the stream to another output (pactl move-sink-input, remembered by WirePlumber for that app)"
                Repeater {
                    model: Store.playback
                    NodeRow { required property var modelData; node: modelData; routeTargets: Store.sinks; peer: Store.peerOf(modelData); onRoute: d => Store.moveStream(modelData, d) }
                }
                Text { visible: Store.playback.length === 0; text: "nothing playing"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "Recording"
                subtitle: "apps using a microphone; the combo picks the input they record from"
                Repeater {
                    model: Store.recording
                    NodeRow { required property var modelData; node: modelData; routeTargets: Store.sources; peer: Store.peerOf(modelData); onRoute: d => Store.moveStream(modelData, d) }
                }
                Text { visible: Store.recording.length === 0; text: "nothing recording"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
            Item { height: 12 }
        }
    }
}
