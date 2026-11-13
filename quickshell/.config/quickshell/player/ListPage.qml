pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// a list of tracks with a header: the queue, the liked tracks, the recently played, or one playlist
// (hand-made: drag to reorder, remove; smart: its rules, evaluated on the fly)
Item {
    id: page
    property var menu: null
    property string kind: "queue"        // queue | favorites | recent | playlist
    property string playlistId: ""
    property var dialog: null
    readonly property var playlist: kind === "playlist" ? Store.playlist(playlistId) : null
    readonly property var tracks: kind === "queue" ? Player.queue.map(k => Store.byKey[k] || { key: k, title: k.split("/").pop(), artist: "", album: "", length: 0 })
                                  : kind === "favorites" ? Store.likedTracks
                                  : kind === "recent" ? Store.recentTracks
                                  : Store.playlistTracks(playlist)
    readonly property string title: kind === "queue" ? "Queue" : kind === "favorites" ? "Favorites" : kind === "recent" ? "Recently played" : (playlist ? playlist.name : "Playlist")
    readonly property string icon: kind === "queue" ? "󰐑" : kind === "favorites" ? "󰋑" : kind === "recent" ? "󰥔" : (playlist && playlist.smart ? "󰛨" : "󰲸")
    readonly property real total: tracks.reduce((a, t) => a + (t.length || 0), 0)
    readonly property bool editable: kind === "queue" || (kind === "playlist" && playlist && !playlist.smart)
    function describe(r) {
        const bits = []
        if (r.artist) bits.push("artist ~ " + r.artist)
        if (r.album) bits.push("album ~ " + r.album)
        if (r.genre) bits.push("genre ~ " + r.genre)
        if (r.title) bits.push("title ~ " + r.title)
        if (r.yearFrom || r.yearTo) bits.push("year " + (r.yearFrom || "…") + "–" + (r.yearTo || "…"))
        if (r.liked) bits.push("liked")
        if (r.minPlays) bits.push("plays ≥ " + r.minPlays)
        if (r.maxPlays !== undefined && r.maxPlays !== null && r.maxPlays !== "") bits.push("plays ≤ " + r.maxPlays)
        if (r.playedDays) bits.push("played in the last " + r.playedDays + " days")
        if (r.notPlayedDays) bits.push("not played for " + r.notPlayedDays + " days")
        return (bits.length ? bits.join(" · ") : "every track") + " · sorted by " + (r.sort || "artist") + (r.limit ? " · " + r.limit + " at most" : "")
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
            spacing: 14
            Rectangle {
                implicitWidth: 72; implicitHeight: 72; radius: Ui.radius
                color: Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.15)
                Text { anchors.centerIn: parent; text: page.icon; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 34 }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: page.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 8; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: page.tracks.length + (page.tracks.length === 1 ? " track" : " tracks") + (page.total ? " · " + Store.hours(page.total) : ""); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                Text {
                    visible: !!(page.playlist && page.playlist.smart)
                    Layout.fillWidth: true
                    text: page.playlist && page.playlist.smart ? page.describe(page.playlist.smart) : ""
                    color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight
                }
            }
            UiButton { primary: true; icon: "󰐊"; label: "Play"; enabledBtn: page.tracks.length > 0; visible: page.kind !== "queue"; onClicked: Player.playList(page.tracks, 0) }
            UiButton { icon: "󰒝"; label: "Shuffle"; enabledBtn: page.tracks.length > 0; onClicked: Player.playShuffled(page.tracks) }
            UiButton { visible: page.kind !== "queue"; icon: "󰐕"; label: "Queue"; enabledBtn: page.tracks.length > 0; onClicked: Player.enqueue(page.tracks) }
            UiButton { visible: page.kind === "queue"; icon: "󰆴"; label: "Clear"; enabledBtn: page.tracks.length > 0; onClicked: Player.clearQueue() }
            UiButton { visible: page.kind === "queue" || page.kind === "favorites" || page.kind === "recent"; icon: "󰲸"; label: "Save as playlist"; enabledBtn: page.tracks.length > 0; onClicked: Store.newPlaylistWith(page.tracks.map(t => t.key)) }
            UiButton { visible: page.kind === "playlist"; icon: "󰏫"; label: page.playlist && page.playlist.smart ? "Rules" : "Rename"; onClicked: if (page.dialog) page.dialog.edit(page.playlistId) }
            UiButton { visible: page.kind === "playlist"; danger: true; icon: "󰆴"; tooltip: "delete the playlist"; onClicked: { Store.deletePlaylist(page.playlistId); Store.goPage("albums") } }
        }
        TrackList {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 6; Layout.rightMargin: 6
            tracks: page.tracks
            showYear: true
            editable: page.editable
            queueMode: page.kind === "queue"
            menu: page.menu
            empty: page.kind === "queue" ? "The queue is empty: play an album, or add tracks with the row menu." : page.kind === "favorites" ? "No liked tracks yet (the heart on a row, or L while it plays)." : page.kind === "recent" ? "Nothing played yet." : (page.playlist && page.playlist.smart ? "No track fits the rules." : "Empty: add tracks from any list's menu, or drag the queue here.")
            onReorder: (from, to) => { if (page.kind === "queue") Player.move(from, to); else Store.updatePlaylist(page.playlistId, p => { const [x] = p.tracks.splice(from, 1); p.tracks.splice(to, 0, x) }) }
            onRemove: i => { if (page.kind === "queue") Player.removeAt(i); else Store.updatePlaylist(page.playlistId, p => { p.tracks.splice(i, 1) }) }
        }
    }
}
