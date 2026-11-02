import QtQuick

// a small label: "app", "files", "theme"
Rectangle {
    id: badge
    property string text: ""
    property color tint: Ui.accent
    property string tip: ""
    implicitWidth: t.implicitWidth + 12
    implicitHeight: 16
    radius: 8
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.18)
    Text { id: t; anchors.centerIn: parent; text: badge.text; color: badge.tint; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
    MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
    Tip { text: badge.tip; when: m.containsMouse }
}
