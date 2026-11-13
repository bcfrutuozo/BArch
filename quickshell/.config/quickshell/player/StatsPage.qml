pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// what was listened to, from the history of plays: today, this week, this month, this year, all time;
// the top artists, albums and genres by minutes, and a leaderboard's top 100 tracks
Item {
    id: page
    property var menu: null
    property string range: "week"
    readonly property var ranges: [{ id: "day", label: "Day", s: 86400 }, { id: "week", label: "Week", s: 7 * 86400 }, { id: "month", label: "Month", s: 30 * 86400 }, { id: "year", label: "Year", s: 365 * 86400 }, { id: "all", label: "All time", s: 0 }]
    readonly property var st: Store.stats((ranges.filter(r => r.id === range)[0] || { s: 0 }).s)
    property var pick: null            // { kind: "artist"|"album"|"genre", key, name }
    readonly property var pickTracks: {
        if (!pick) return []
        const f = pick.kind === "artist" ? t => Store.byKey[t.key].albumArtist === pick.key : pick.kind === "album" ? t => Store.byKey[t.key].albumKey === pick.key : t => Store.byKey[t.key].genre === pick.key
        return st.tracks.filter(t => Store.byKey[t.key] && f(t)).slice(0, 100).map(t => Store.byKey[t.key])
    }
    onRangeChanged: pick = null

    component Tile: Rectangle {
        id: tile
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        implicitHeight: 64
        radius: Ui.cardRadius
        color: Ui.raised
        border.width: 1; border.color: Ui.surface
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 12
            spacing: 2
            Text { text: tile.value; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 8; font.bold: true }
            Text { text: tile.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
        }
    }
    component Board: Card {
        id: board
        property string kind: ""
        property var rows: []
        readonly property real most: rows.length ? rows[0].seconds : 1
        Layout.fillHeight: true
        Repeater {
            model: board.rows.slice(0, 10)
            delegate: Item {
                id: r
                required property var modelData
                required property int index
                Layout.fillWidth: true
                implicitHeight: 34
                Rectangle { anchors.fill: parent; radius: Ui.radius - 2; color: rm.containsMouse ? Ui.faint : "transparent" }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                    spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: r.index + 1; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; Layout.preferredWidth: 16 }
                        Text { Layout.fillWidth: true; text: r.modelData.name + (r.modelData.artist ? "  ·  " + r.modelData.artist : ""); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Text { text: Store.hours(r.modelData.seconds) + " · " + r.modelData.plays; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.leftMargin: 22
                        implicitHeight: 3; radius: 2; color: Ui.surface
                        Rectangle { width: parent.width * (r.modelData.seconds / board.most); height: parent.height; radius: 2; color: Ui.accent }
                    }
                }
                MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.pick = { kind: board.kind, key: r.modelData.key, name: r.modelData.name } }
            }
        }
        Text { visible: board.rows.length === 0; text: "nothing in this range"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 16; anchors.rightMargin: 16
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            Repeater {
                model: page.ranges
                Rectangle {
                    required property var modelData
                    readonly property bool on: page.range === modelData.id
                    implicitWidth: rt.implicitWidth + 24; implicitHeight: 28; radius: 14
                    color: on ? Ui.accent : (tm.containsMouse ? Ui.surface : "transparent")
                    border.width: on ? 0 : 1; border.color: Ui.surface
                    Text { id: rt; anchors.centerIn: parent; text: parent.modelData.label; color: parent.on ? Ui.crust : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: parent.on }
                    MouseArea { id: tm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.range = parent.modelData.id }
                }
            }
            Item { Layout.fillWidth: true }
            Text { text: "a play counts once a track passes half its length (or four minutes)"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Tile { label: "plays"; value: page.st.plays }
            Tile { label: "listened"; value: Store.hours(page.st.seconds) }
            Tile { label: "artists"; value: page.st.artists.length }
            Tile { label: "albums"; value: page.st.albums.length }
            Tile { label: "tracks"; value: page.st.tracks.length }
        }
        RowLayout {
            visible: !page.pick
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10
            Board { title: "Artists"; subtitle: "by minutes played"; kind: "artist"; rows: page.st.artists }
            Board { title: "Albums"; subtitle: "by minutes played"; kind: "album"; rows: page.st.albums }
            Board { title: "Genres"; subtitle: "by minutes played"; kind: "genre"; rows: page.st.genres }
        }
        ColumnLayout {
            visible: !!page.pick
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6
            RowLayout {
                UiButton { icon: "󰅁"; label: "Back"; small: true; onClicked: page.pick = null }
                Text { text: page.pick ? page.pick.name + " · top " + page.pickTracks.length + " tracks by plays" : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true }
            }
            TrackList { Layout.fillWidth: true; Layout.fillHeight: true; tracks: page.pickTracks; showYear: true; menu: page.menu; empty: "no plays" }
        }
    }
}
