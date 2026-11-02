import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the journal of this boot: warnings and errors, or everything, with a filter
Item {
    id: page
    property string priority: "warning"
    property string unit: ""
    property string grep: ""
    property int lines: 400

    function load() {
        const args = ["-b", "-n", String(lines)]
        if (priority !== "all") args.push("-p", priority)
        if (unit.trim()) args.push("-u", unit.trim())
        if (grep.trim()) args.push("-g", grep.trim())
        Store.refreshJournal(args)
    }
    Component.onCompleted: load()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            UiCombo { entries: [{ label: "errors", value: "err" }, { label: "warnings and errors", value: "warning" }, { label: "notice and above", value: "notice" }, { label: "everything", value: "all" }]; value: page.priority; onPicked: v => { page.priority = v; page.load() } }
            UiField { Layout.preferredWidth: 220; placeholderText: "unit (optional)"; onCommitted: v => { page.unit = v; page.load() } }
            UiField { Layout.fillWidth: true; placeholderText: "grep (regex, optional)"; onCommitted: v => { page.grep = v; page.load() } }
            UiCombo { entries: [200, 400, 1000, 3000].map(n => ({ label: n + " lines", value: n })); value: page.lines; onPicked: v => { page.lines = v; page.load() } }
            UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: page.load() }
            UiButton { icon: "󰆏"; small: true; tooltip: "copy"; onClicked: Store.copy(Store.journal) }
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 12
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
                    width: sv.availableWidth
                    readOnly: true
                    selectByMouse: true
                    text: Store.journal || "(nothing)"
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
