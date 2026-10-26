// SectionTitle.qml — título de seção do painel do SysMonitor.

import QtQuick
import QtQuick.Layouts

RowLayout {
    id: sec

    required property var widget      // o SysMonitor (cores e fontes)
    property string icon: ""
    property string title: ""

    Layout.fillWidth: true
    Layout.topMargin: 4
    spacing: 8

    Text {
        text: sec.icon
        color: sec.widget.accent
        font.family: sec.widget.fontFamily
        font.pixelSize: sec.widget.fontSize + 1
    }
    Text {
        Layout.fillWidth: true
        text: sec.title
        color: sec.widget.fg
        font.family: sec.widget.fontFamily
        font.pixelSize: sec.widget.fontSize
        font.bold: true
    }
}
