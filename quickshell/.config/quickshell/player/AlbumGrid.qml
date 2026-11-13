pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// albums as covers in a grid; a click opens the album, hovering shows Play, right-click the menu
Item {
    id: grid
    property var albums: []
    property int cell: 190
    property bool showArtist: true
    property string empty: "No albums."
    property var menu: null
    signal picked(var album)

    Text {
        visible: grid.albums.length === 0
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 30 }
        text: grid.empty; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
    }
    GridView {
        id: view
        anchors.fill: parent
        clip: true
        model: grid.albums
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / grid.cell)))
        cellHeight: cellWidth + 44
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        reuseItems: true
        cacheBuffer: cellHeight * 2

        delegate: Item {
            id: tile
            required property var modelData
            width: view.cellWidth
            height: view.cellHeight
            readonly property bool playingThis: Player.hasTrack && Player.current.albumKey === modelData.key
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 4
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: width
                    Cover { id: cv; album: tile.modelData; size: parent.width; anchors.fill: parent }
                    Rectangle {
                        anchors.fill: parent
                        radius: Ui.radius
                        color: Qt.rgba(0, 0, 0, hm.containsMouse ? 0.25 : 0)
                        border.width: tile.playingThis ? 2 : 0
                        border.color: Ui.accent
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    IconButton {
                        anchors { right: parent.right; bottom: parent.bottom; margins: 8 }
                        visible: hm.containsMouse || tile.playingThis
                        primary: true
                        size: 36
                        icon: tile.playingThis && Player.playing ? "󰏤" : "󰐊"
                        tooltip: tile.playingThis ? (Player.playing ? "Pause" : "Play") : "Play the album"
                        onClicked: { if (tile.playingThis) Player.toggle(); else Player.playList(tile.modelData.tracks, 0) }
                    }
                    MouseArea {
                        id: hm
                        anchors.fill: parent
                        hoverEnabled: true
                        z: -1
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) { const p = mapToItem(null, mouse.x, mouse.y); if (grid.menu) grid.menu.show(p.x, p.y, grid.menu.albumItems(tile.modelData)) }
                            else grid.picked(tile.modelData)
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: tile.modelData.album
                    color: tile.playingThis ? Ui.accent : Ui.text
                    font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: (grid.showArtist ? tile.modelData.artist : "") + (grid.showArtist && tile.modelData.year ? " · " : "") + (tile.modelData.year || "")
                    color: Ui.subtext
                    font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight
                }
            }
        }
    }
}
