import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the text panel on the right: a unit's journal, a failure log, a report
Rectangle {
    id: panel
    visible: Store.logOpen
    Layout.fillHeight: true
    Layout.preferredWidth: 560
    color: Ui.raised
    border.width: 1
    border.color: Ui.surface
    radius: Ui.cardRadius

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8
        RowLayout {
            spacing: 6
            Text { Layout.fillWidth: true; text: Store.logTitle; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideMiddle }
            UiButton { visible: Store.logPath !== ""; icon: "󰏫"; small: true; tooltip: "open in the editor"; onClicked: Store.openPath(Store.logPath) }
            UiButton { icon: "󰆏"; small: true; tooltip: "copy the text"; onClicked: Store.copy(Store.logText) }
            UiButton { icon: "󰅖"; small: true; tooltip: "close"; onClicked: Store.logOpen = false }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Ui.radius
            color: Ui.sunken
            border.width: 1; border.color: Ui.surface
            ScrollView {
                id: sv
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                contentWidth: availableWidth
                TextEdit {
                    id: body
                    width: sv.availableWidth
                    readOnly: true
                    selectByMouse: true
                    text: Store.logText
                    color: Ui.text
                    selectionColor: Ui.accent; selectedTextColor: Ui.crust
                    font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                    wrapMode: TextEdit.Wrap
                    onTextChanged: Qt.callLater(() => { sv.ScrollBar.vertical.position = Math.max(0, 1 - sv.ScrollBar.vertical.size) })
                }
            }
        }
    }
}
