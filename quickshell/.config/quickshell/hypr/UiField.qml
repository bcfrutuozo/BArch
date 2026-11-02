import QtQuick
import QtQuick.Controls

// a text field; `committed` fires on Enter or when it loses focus with a changed text
TextField {
    id: field
    property bool mono: false
    property bool bad: false
    signal committed(string value)
    property string lastCommitted: ""

    color: Ui.text
    placeholderTextColor: Ui.overlay
    selectionColor: Ui.accent
    selectedTextColor: Ui.crust
    font.family: mono ? Ui.monoFont : Ui.font
    font.pixelSize: mono ? Ui.fontSize - 1 : Ui.fontSize
    leftPadding: 10; rightPadding: 10; topPadding: 5; bottomPadding: 5
    implicitHeight: 30
    background: Rectangle {
        radius: Ui.radius
        color: Ui.sunken
        border.width: 1
        border.color: field.bad ? Ui.red : (field.activeFocus ? Ui.accent : Ui.surface)
    }
    function commit() {
        if (text !== lastCommitted) { lastCommitted = text; committed(text) }
    }
    onAccepted: { commit(); focus = false }
    onActiveFocusChanged: if (!activeFocus) commit()
    onTextChanged: if (!activeFocus) lastCommitted = text
    Component.onCompleted: lastCommitted = text
}
