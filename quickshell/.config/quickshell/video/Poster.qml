pragma ComponentBehavior: Bound
import QtQuick

// a poster from TMDB/TVDB (the URL video.py gives), or a placeholder with the first letter
Rectangle {
    id: c
    property string source: ""
    property string title: ""
    implicitWidth: 60
    implicitHeight: 90
    radius: 4
    color: Ui.sunken
    clip: true
    Text {
        anchors.centerIn: parent
        visible: img.status !== Image.Ready
        text: (c.title || "?").charAt(0).toUpperCase()
        color: Ui.overlay; font.family: Ui.font; font.pixelSize: c.height / 3; font.bold: true
    }
    Image {
        id: img
        anchors.fill: parent
        source: c.source
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: c.width * 2
    }
}
