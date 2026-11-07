import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// what the search field found: artists, albums, tracks
Item {
    id: page
    property var menu: null
    property string query: ""
    readonly property var result: Store.search(query)

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 16; anchors.rightMargin: 10
        spacing: 10
        Text {
            visible: page.query.trim() === ""
            text: "Type in the search field: artists, albums and tracks."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
        Flow {
            Layout.fillWidth: true
            visible: page.result.artists.length > 0
            spacing: 6
            Text { text: "Artists"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; font.bold: true; width: 60; height: 26; verticalAlignment: Text.AlignVCenter }
            Repeater {
                model: page.result.artists
                Rectangle {
                    required property var modelData
                    width: at.implicitWidth + 24; height: 26; radius: 13
                    color: am.containsMouse ? Ui.surface : Ui.raised
                    border.width: 1; border.color: Ui.surface
                    Text { id: at; anchors.centerIn: parent; text: parent.modelData.name + "  " + parent.modelData.albums.length; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                    MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.goArtist(parent.modelData.name) }
                }
            }
        }
        Text { visible: page.result.albums.length > 0; text: "Albums"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; font.bold: true }
        AlbumGrid {
            visible: page.result.albums.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(2, Math.ceil(page.result.albums.length / Math.max(1, Math.floor(width / 150)))) * 194 + 8
            cell: 150
            albums: page.result.albums
            menu: page.menu
            onPicked: a => Store.goAlbum(a.key)
        }
        Text { visible: page.result.tracks.length > 0; text: "Tracks"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; font.bold: true }
        TrackList {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.query.trim() !== ""
            tracks: page.result.tracks
            showYear: true
            menu: page.menu
            empty: "No track matches."
        }
    }
}
