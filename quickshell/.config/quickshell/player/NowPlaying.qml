pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the bar at the bottom: what plays, like, the transport, the seek bar, volume, queue and lyrics
Rectangle {
    id: bar
    property var menu: null
    signal showQueue()
    signal showLyrics()
    property bool queueOn: false
    property bool lyricsOn: false
    readonly property var t: Player.current
    readonly property var album: t ? Store.albumByKey[t.albumKey] : null
    implicitHeight: 86
    color: Ui.raised
    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Ui.surface }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14; anchors.rightMargin: 14
        spacing: 14

        // what plays
        RowLayout {
            Layout.preferredWidth: Math.max(260, bar.width * 0.28)
            Layout.maximumWidth: bar.width * 0.3
            spacing: 12
            Cover {
                album: bar.album; size: 60
                MouseArea { anchors.fill: parent; enabled: !!bar.t; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: Store.goAlbum(bar.t.albumKey) }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                    Layout.fillWidth: true
                    text: bar.t ? bar.t.title : "Nothing playing"
                    color: tm.containsMouse ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight
                    MouseArea { id: tm; anchors.fill: parent; hoverEnabled: true; enabled: !!bar.t; cursorShape: Qt.PointingHandCursor; onClicked: Store.goAlbum(bar.t.albumKey) }
                }
                Text {
                    Layout.fillWidth: true
                    text: bar.t ? bar.t.artist : (Player.queue.length ? Player.queue.length + " in the queue" : "pick an album, or press Space to resume the last queue")
                    color: am.containsMouse ? Ui.accent : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight
                    MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; enabled: !!bar.t; cursorShape: Qt.PointingHandCursor; onClicked: Store.goArtist(bar.t.albumArtist) }
                }
                RowLayout {
                    spacing: 6
                    Text { text: bar.t ? bar.t.album + (bar.t.year ? " · " + bar.t.year : "") : ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight; Layout.maximumWidth: 240 }
                    Badge { visible: !!bar.t && bar.t.bits > 0; text: bar.t ? bar.t.bits + "/" + (bar.t.rate / 1000).toFixed(bar.t.rate % 1000 ? 1 : 0) : ""; tint: bar.t && bar.t.bits > 16 ? Ui.accent : Ui.overlay; tip: bar.t ? bar.t.bits + "-bit, " + bar.t.rate + " Hz FLAC" : "" }
                }
            }
            MiniViz { visible: Viz.settings.mini && Player.hasTrack; Layout.preferredWidth: 90; Layout.preferredHeight: 26 }
            IconButton {
                readonly property bool on: !!bar.t && Store.liked(bar.t.key)
                icon: on ? "󰋑" : "󰋕"; active: on; enabledBtn: !!bar.t
                tooltip: on ? "Unlike (L)" : "Like (L)"
                onClicked: Player.likeCurrent()
            }
        }

        // transport + seek
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 4
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 10
                IconButton { icon: "󰒝"; active: Player.shuffle; tooltip: "Shuffle (S)"; onClicked: Player.toggleShuffle() }
                IconButton { icon: "󰒮"; enabledBtn: Player.queue.length > 0; tooltip: "Previous (P)"; onClicked: Player.prev() }
                IconButton { primary: true; size: 40; glyphSize: Ui.fontSize + 10; icon: Player.playing ? "󰏤" : "󰐊"; enabledBtn: Player.queue.length > 0; tooltip: Player.playing ? "Pause (Space)" : "Play (Space)"; onClicked: Player.toggle() }
                IconButton { icon: "󰒭"; enabledBtn: Player.queue.length > 0; tooltip: "Next (N)"; onClicked: Player.next() }
                IconButton { icon: Player.repeat === "one" ? "󰑘" : "󰑖"; active: Player.repeat !== "off"; tooltip: "Repeat: " + Player.repeat + " (R)"; onClicked: Player.cycleRepeat() }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: Store.time(seek.dragging ? seek.dragValue : Player.position); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
                UiSlider {
                    id: seek
                    Layout.fillWidth: true
                    property bool dragging: false
                    property real dragValue: 0
                    from: 0; to: Math.max(1, Player.duration)
                    value: dragging ? dragValue : Player.position
                    enabledSl: Player.hasTrack
                    onMoved: v => { dragging = true; dragValue = v }
                    onReleased: v => { dragging = false; Player.seek(v) }
                }
                Text { text: Store.time(Player.duration); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; Layout.preferredWidth: 40 }
            }
        }

        // right: lyrics, queue, volume
        RowLayout {
            Layout.preferredWidth: Math.max(220, bar.width * 0.22)
            Layout.alignment: Qt.AlignRight
            spacing: 6
            Item { Layout.fillWidth: true }
            IconButton { icon: "󰨖"; active: bar.lyricsOn; tooltip: "Lyrics (Y)"; onClicked: bar.showLyrics() }
            IconButton { icon: "󰐑"; active: bar.queueOn; tooltip: "Queue (Q) · " + Player.queue.length; onClicked: bar.showQueue() }
            IconButton {
                icon: Player.muted || Player.volume === 0 ? "󰝟" : Player.volume < 50 ? "󰖀" : "󰕾"
                tooltip: Player.muted ? "Unmute (M)" : "Mute (M)"
                onClicked: Player.toggleMute()
            }
            UiSlider {
                Layout.preferredWidth: 110
                from: 0; to: 100; step: 1
                value: Player.volume
                onMoved: v => Player.setVolume(v)
                onReleased: v => Player.setVolume(v)
            }
            Text { text: Math.round(Player.volume); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; Layout.preferredWidth: 30; horizontalAlignment: Text.AlignRight }
        }
    }
}
