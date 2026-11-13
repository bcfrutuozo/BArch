pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the genres (from the GENRE tag the pipeline puts on every track), the albums of the chosen one
Item {
    id: page
    property var menu: null
    property string selected: ""
    readonly property var genre: Store.genres.filter(g => g.name === selected)[0] || null
    Component.onCompleted: if (!selected && Store.genres.length) selected = Store.genres[0].name

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ListView {
            Layout.preferredWidth: 240
            Layout.fillHeight: true
            Layout.leftMargin: 10
            clip: true
            model: Store.genres
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
                    Text { Layout.fillWidth: true; text: row.modelData.name; color: row.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                    Text { text: row.modelData.albums.length; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                }
                MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.selected = row.modelData.name }
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
                    Text { text: page.genre ? page.genre.name : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 8; font.bold: true }
                    Text { text: page.genre ? page.genre.albums.length + " albums · " + page.genre.tracks + " tracks · " + new Set(page.genre.albums.map(a => a.artist)).size + " artists" : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                }
                UiButton { primary: true; icon: "󰒝"; label: "Shuffle"; enabledBtn: !!page.genre; onClicked: Player.playShuffled(page.genre.albums.flatMap(a => a.tracks)) }
                UiButton { icon: "󰐊"; label: "Play all"; enabledBtn: !!page.genre; onClicked: Player.playList(page.genre.albums.flatMap(a => a.tracks), 0) }
            }
            AlbumGrid {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 8; Layout.rightMargin: 8
                albums: page.genre ? page.genre.albums : []
                menu: page.menu
                empty: Store.genres.length ? "Pick a genre." : "No genres yet."
                onPicked: a => Store.goAlbum(a.key)
            }
        }
    }
}
