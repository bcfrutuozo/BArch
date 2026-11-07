import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// one album: the cover, what it is, Play / Shuffle / queue / playlist, and its tracks
Item {
    id: page
    property var album: null
    property var menu: null
    readonly property var tracks: album ? album.tracks : []
    readonly property bool playingThis: Player.hasTrack && album && Player.current.albumKey === album.key
    function format() {
        if (!tracks.length) return ""
        const rates = new Set(tracks.map(t => t.rate)), bits = new Set(tracks.map(t => t.bits))
        const r = rates.size === 1 ? (tracks[0].rate / 1000).toFixed(tracks[0].rate % 1000 ? 1 : 0) + " kHz" : "mixed rates"
        const b = bits.size === 1 ? tracks[0].bits + "-bit" : "mixed"
        return b + " · " + r
    }
    readonly property int likedCount: tracks.filter(t => Store.liked(t.key)).length
    readonly property int playCount: tracks.reduce((a, t) => a + Store.plays(t.key), 0)

    ColumnLayout {
        anchors.fill: parent
        spacing: 14
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16
            spacing: 20
            Cover { album: page.album; size: 200 }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignBottom
                spacing: 4
                Text { text: "ALBUM"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; font.bold: true }
                Text {
                    Layout.fillWidth: true
                    text: page.album ? page.album.album : ""
                    color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 12; font.bold: true
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                }
                RowLayout {
                    spacing: 6
                    Text {
                        text: page.album ? page.album.artist : ""
                        color: am.containsMouse ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true
                        MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.goArtist(page.album.artist) }
                    }
                    Text {
                        text: (page.album && page.album.year ? " · " + page.album.year : "") + (page.album && page.album.genre ? " · " + page.album.genre : "")
                              + " · " + page.tracks.length + (page.tracks.length === 1 ? " track" : " tracks") + ", " + Store.hours(page.album ? page.album.length : 0)
                              + (page.album && page.album.discs > 1 ? " · " + page.album.discs + " discs" : "")
                        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                    }
                }
                RowLayout {
                    spacing: 6
                    Badge { text: page.format(); tint: Ui.subtext; visible: text !== "" }
                    Badge { visible: page.playCount > 0; text: page.playCount + (page.playCount === 1 ? " play" : " plays"); tint: Ui.subtext }
                    Badge { visible: page.likedCount > 0; text: page.likedCount + " liked"; tint: Ui.red }
                    Badge { visible: !!(page.album && page.album.date && page.album.date.length > 4); text: page.album ? page.album.date : ""; tint: Ui.overlay; tip: "release date" }
                }
                RowLayout {
                    Layout.topMargin: 8
                    spacing: 8
                    UiButton { primary: true; icon: page.playingThis && Player.playing ? "󰏤" : "󰐊"; label: page.playingThis ? (Player.playing ? "Pause" : "Resume") : "Play"; onClicked: { if (page.playingThis) Player.toggle(); else Player.playList(page.tracks, 0) } }
                    UiButton { icon: "󰒝"; label: "Shuffle"; onClicked: Player.playShuffled(page.tracks) }
                    UiButton { icon: "󰒭"; label: "Play next"; onClicked: Player.playNext(page.tracks) }
                    UiButton { icon: "󰐕"; label: "Queue"; tooltip: "add the album to the end of the queue"; onClicked: Player.enqueue(page.tracks) }
                    UiButton {
                        icon: "󰇘"; tooltip: "more"
                        onClicked: { const p = mapToItem(null, 0, height + 4); if (page.menu) page.menu.show(p.x, p.y, page.menu.albumItems(page.album)) }
                    }
                }
            }
        }
        TrackList {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 6; Layout.rightMargin: 6
            tracks: page.tracks
            showAlbum: false
            showNumber: true
            showArtist: page.tracks.some(t => t.artist !== t.albumArtist)
            menu: page.menu
        }
    }
}
