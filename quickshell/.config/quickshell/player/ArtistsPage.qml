pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the artists on the left, the albums of the chosen one on the right
Item {
    id: page
    property var menu: null
    property string selected: ""
    property string filter: ""
    readonly property var artist: Store.artistByName[selected] || null
    readonly property var list: { const f = Store.fold(filter).trim(); return f ? Store.artists.filter(a => a.s.includes(f)) : Store.artists }
    function select(name) { selected = name; const i = Store.artists.findIndex(a => a.name === name); if (i >= 0) view.positionViewAtIndex(i, ListView.Contain) }
    Component.onCompleted: if (!selected && Store.artists.length) selected = Store.artists[0].name

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            Layout.preferredWidth: 260
            Layout.fillHeight: true
            Layout.leftMargin: 10
            spacing: 6
            UiField { Layout.fillWidth: true; Layout.rightMargin: 8; placeholderText: "filter " + Store.artists.length + " artists"; onTextChanged: page.filter = text }
            ListView {
                id: view
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: page.list
                reuseItems: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool current: page.selected === modelData.name
                    width: ListView.view.width - 8
                    height: 36
                    radius: Ui.radius
                    color: current ? Ui.surface : (rm.containsMouse ? Ui.faint : "transparent")
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        spacing: 6
                        Text { Layout.fillWidth: true; text: row.modelData.name; color: row.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                        Text { text: row.modelData.albums.length; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    }
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.selected = row.modelData.name }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
                spacing: 14
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: page.artist ? page.artist.name : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 8; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text {
                        text: page.artist ? page.artist.albums.length + (page.artist.albums.length === 1 ? " album" : " albums") + " · " + page.artist.tracks + " tracks · " + Store.hours(page.artist.length)
                              + (page.artist.albums.some(a => a.genre) ? " · " + Array.from(new Set(page.artist.albums.map(a => a.genre).filter(g => g))).slice(0, 3).join(", ") : "") : ""
                        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                    }
                }
                UiButton { primary: true; icon: "󰐊"; label: "Play all"; enabledBtn: !!page.artist; onClicked: Player.playList(page.artist.albums.flatMap(a => a.tracks), 0) }
                UiButton { icon: "󰒝"; label: "Shuffle"; enabledBtn: !!page.artist; onClicked: Player.playShuffled(page.artist.albums.flatMap(a => a.tracks)) }
                UiButton { icon: "󰐕"; label: "Queue"; enabledBtn: !!page.artist; onClicked: Player.enqueue(page.artist.albums.flatMap(a => a.tracks)) }
            }
            AlbumGrid {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 8; Layout.rightMargin: 8
                albums: page.artist ? page.artist.albums : []
                showArtist: false
                menu: page.menu
                empty: Store.artists.length ? "Pick an artist." : "Loading the library…"
                onPicked: a => Store.goAlbum(a.key)
            }
        }
    }
}
