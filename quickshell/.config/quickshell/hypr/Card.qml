import QtQuick
import QtQuick.Layouts

// a card with a title row and a body (children go into the body)
Rectangle {
    id: card
    property string title: ""
    property string subtitle: ""
    default property alias body: bodyLayout.data
    property alias headerItems: headerRow.data

    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + 28
    radius: Ui.cardRadius
    color: Ui.raised
    border.width: 1
    border.color: Ui.surface

    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            visible: card.title !== "" || headerRow.children.length > 0
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: card.title; visible: text !== ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true }
                Text { text: card.subtitle; visible: text !== ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap; Layout.fillWidth: true }
            }
            RowLayout { id: headerRow; spacing: 6 }
        }
        ColumnLayout {
            id: bodyLayout
            Layout.fillWidth: true
            spacing: 8
        }
    }
}
