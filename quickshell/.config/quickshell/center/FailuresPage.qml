import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the logs `barch failure` saved, grouped by unit; the ignore list of the repo
Item {
    id: page
    property string filter: ""
    property var expanded: ({})

    readonly property var groups: {
        const q = filter.trim().toLowerCase()
        const map = {}, order = []
        for (const f of Store.failures) {
            if (q && f.unit.toLowerCase().indexOf(q) === -1) continue
            if (!map[f.unit]) { map[f.unit] = { unit: f.unit, items: [], last: f.time }; order.push(f.unit) }
            map[f.unit].items.push(f)
        }
        return order.map(u => map[u]).sort((a, b) => b.last - a.last)
    }
    function toggle(u) { const e = Object.assign({}, expanded); e[u] = !e[u]; expanded = e }
    function addIgnore(glob) {
        if (Store.ignoreGlobs.indexOf(glob) !== -1) return
        Store.setIgnore(Store.ignore.filter((l, i, a) => !(i === a.length - 1 && l === "")).concat([glob]))
    }
    function removeIgnore(glob) { Store.setIgnore(Store.ignore.filter(l => l !== glob)) }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            UiField { Layout.fillWidth: true; placeholderText: "filter by unit"; onTextChanged: page.filter = text }
            Text { text: Store.failures.length + " logs"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshFailures() }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: parent.width
                spacing: 8
                Repeater {
                    model: page.groups
                    Card {
                        id: g
                        required property var modelData
                        readonly property bool open: !!page.expanded[modelData.unit]
                        Layout.leftMargin: 12; Layout.rightMargin: 12
                        title: modelData.unit
                        subtitle: modelData.items.length + " failure" + (modelData.items.length === 1 ? "" : "s") + "  ·  last " + Store.ago(modelData.last) + (Store.ignored(modelData.unit) ? "  ·  ignored from now on" : "")
                        headerItems: [
                            UiButton { label: "latest log"; small: true; onClicked: Store.showFile(g.modelData.items[0].name, g.modelData.items[0].path) },
                            UiButton { label: "Investigate"; icon: "󰚩"; small: true; tooltip: "Claude reads the latest log in a terminal"; onClicked: Store.investigate(g.modelData.items[0].path) },
                            UiButton { label: g.open ? "hide" : "all " + g.modelData.items.length; small: true; onClicked: page.toggle(g.modelData.unit) },
                            UiButton { icon: "󰛑"; small: true; tooltip: "ignore this unit's failures (agent/failure-ignore)"; visible: !Store.ignored(g.modelData.unit); onClicked: page.addIgnore(g.modelData.unit) },
                            UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "delete every log of this unit"; onClicked: Store.deleteFailuresOf(g.modelData.unit) }
                        ]
                        Repeater {
                            model: g.open ? g.modelData.items : []
                            RowLayout {
                                id: it
                                required property var modelData
                                spacing: 8
                                Text { Layout.preferredWidth: 170; text: Store.stampToDate(it.modelData.stamp); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                                Text { Layout.fillWidth: true; text: it.modelData.name + "  ·  " + Math.round(it.modelData.size / 100) / 10 + " kB"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle }
                                UiButton { icon: "󰈙"; small: true; tooltip: "view"; onClicked: Store.showFile(it.modelData.name, it.modelData.path) }
                                UiButton { icon: "󰚩"; small: true; tooltip: "Investigate"; onClicked: Store.investigate(it.modelData.path) }
                                UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "delete"; onClicked: Store.deleteFailure(it.modelData.path) }
                            }
                        }
                    }
                }
                Text { visible: page.groups.length === 0; Layout.margins: 12; text: "no failure logs"; color: Ui.green; font.family: Ui.font; font.pixelSize: Ui.fontSize }

                Card {
                    Layout.margins: 12
                    title: "Ignored units"
                    subtitle: "agent/failure-ignore in the repo: failures of these units are not reported (shell globs)"
                    headerItems: [ UiButton { icon: "󰏫"; small: true; tooltip: "open the file"; onClicked: Store.openPath(Store.ignorePath) } ]
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: Store.ignoreGlobs
                            Rectangle {
                                required property var modelData
                                width: gt.implicitWidth + 36; height: 26; radius: 13
                                color: Ui.sunken; border.width: 1; border.color: Ui.surface
                                Text { id: gt; x: 10; anchors.verticalCenter: parent.verticalCenter; text: parent.modelData; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                                Text { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: "󰅖"; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize - 2
                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: page.removeIgnore(parent.parent.modelData) } }
                            }
                        }
                    }
                    RowLayout {
                        spacing: 6
                        UiField { id: newGlob; Layout.preferredWidth: 280; mono: true; placeholderText: "unit or glob (foo.service, app-*)" }
                        UiButton { label: "Add"; small: true; enabledBtn: newGlob.text.trim() !== ""; onClicked: { page.addIgnore(newGlob.text.trim()); newGlob.text = "" } }
                    }
                }
            }
        }
    }
}
