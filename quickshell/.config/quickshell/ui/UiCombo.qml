import QtQuick
import QtQuick.Controls

// a drop-down. `entries` is [{ label, value }]; `editable` also accepts typed text (string values)
ComboBox {
    id: combo
    property var entries: []
    property var value: undefined
    property bool bad: false
    signal picked(var value)

    model: entries.map(e => e.label)
    implicitHeight: 30
    implicitWidth: Math.max(120, contentItem.implicitWidth + 44)
    font.family: Ui.font
    font.pixelSize: Ui.fontSize

    function indexOfValue_(v) {
        for (let i = 0; i < entries.length; i++) if (String(entries[i].value) === String(v)) return i
        return -1
    }
    function sync() {
        const i = indexOfValue_(value)
        if (i >= 0) currentIndex = i
        else if (editable) editText = value === undefined ? "" : String(value)
    }
    onValueChanged: sync()
    onEntriesChanged: sync()
    Component.onCompleted: sync()

    onActivated: idx => { if (idx >= 0 && idx < entries.length) picked(entries[idx].value) }
    onAccepted: if (editable) { const i = indexOfValue_(editText); picked(i >= 0 ? entries[i].value : editText); focus = false }

    contentItem: TextField {
        leftPadding: 10; rightPadding: 28
        enabled: combo.editable            // not editable: the combo itself handles the click
        text: combo.editable ? combo.editText : combo.displayText
        color: Ui.text
        selectionColor: Ui.accent
        selectedTextColor: Ui.crust
        font: combo.font
        verticalAlignment: Text.AlignVCenter
        background: null
        onTextEdited: combo.editText = text
        onAccepted: combo.accepted()
        onTextChanged: if (!combo.editable) cursorPosition = 0      // show the start of a long label, not its end
    }
    indicator: Text {
        x: combo.width - width - 10
        y: (combo.height - height) / 2
        text: "󰅀"
        color: Ui.subtext
        font.family: Ui.iconFont
        font.pixelSize: Ui.fontSize
    }
    background: Rectangle {
        radius: Ui.radius
        color: Ui.sunken
        border.width: 1
        border.color: combo.bad ? Ui.red : (combo.activeFocus || combo.popup.visible ? Ui.accent : Ui.surface)
    }
    delegate: ItemDelegate {
        id: item
        required property int index
        required property var modelData
        width: combo.width
        height: 28
        highlighted: combo.highlightedIndex === index
        contentItem: Text {
            text: item.modelData
            color: item.highlighted ? Ui.crust : Ui.text
            font: combo.font
            verticalAlignment: Text.AlignVCenter
            leftPadding: 4
        }
        background: Rectangle { color: item.highlighted ? Ui.accent : "transparent"; radius: 6 }
    }
    popup: Popup {
        y: combo.height + 2
        width: combo.width
        implicitHeight: Math.min(320, contentItem.implicitHeight + 8)
        padding: 4
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: combo.popup.visible ? combo.delegateModel : null
            currentIndex: combo.highlightedIndex
            ScrollBar.vertical: ScrollBar {}
        }
        background: Rectangle { color: Ui.raised; border.width: 1; border.color: Ui.surface; radius: Ui.radius }
    }
}
