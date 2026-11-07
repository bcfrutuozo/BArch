import QtQuick
import Quickshell.Widgets

// an album's cover (cover.jpg from the share or the API), or a note glyph when there is none
ClippingRectangle {
    id: cover
    property var album: null          // a Store album, or null
    property int size: 160
    property int glyphSize: Math.round(size / 3)
    implicitWidth: size
    implicitHeight: size
    radius: Ui.radius
    color: Ui.sunken
    readonly property string source: Store.coverUrl(album)

    Image {
        id: img
        anchors.fill: parent
        source: cover.source
        sourceSize.width: Math.min(1000, cover.size * 2)
        sourceSize.height: Math.min(1000, cover.size * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        visible: status === Image.Ready
    }
    Text {
        anchors.centerIn: parent
        visible: img.status !== Image.Ready
        text: "󰝚"
        color: Ui.overlay
        font.family: Ui.iconFont
        font.pixelSize: cover.glyphSize
    }
}
