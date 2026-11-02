import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the options of one section (or the search results across all of them)
Item {
    id: page
    property string section: "general"
    property string query: ""

    readonly property bool searching: query.trim() !== ""
    readonly property var model: {
        const q = query.trim().toLowerCase()
        const out = []
        let last = null
        const list = searching
            ? Store.options.filter(o => (o.name + " " + o.desc).toLowerCase().indexOf(q) !== -1).slice(0, 120)
            : Store.options.filter(o => o.section === section)
        for (const o of list) {
            const header = searching ? null : (o.group !== last ? o.group : null)
            if (!searching) last = o.group
            out.push({ opt: o, header: header })
        }
        return out
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 2
            Text {
                Layout.leftMargin: 12; Layout.topMargin: 10; Layout.bottomMargin: 6
                text: page.searching ? page.model.length + " result" + (page.model.length === 1 ? "" : "s") + (page.model.length === 120 ? " (first 120)" : "") : ""
                visible: page.searching
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
            }
            Repeater {
                model: page.model
                delegate: ColumnLayout {
                    id: item
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        visible: item.modelData.header !== null && item.modelData.header !== ""
                        Layout.leftMargin: 12; Layout.topMargin: 14; Layout.bottomMargin: 2
                        text: item.modelData.header || ""
                        color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true
                    }
                    OptionRow { opt: item.modelData.opt; showSection: page.searching }
                }
            }
            Text {
                visible: page.model.length === 0
                Layout.margins: 20
                text: Store.ready ? "nothing here" : "reading hyprctl…"
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            Item { height: 20 }
        }
    }
}
