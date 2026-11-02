import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the installed packages: explicit by default, every one with "all"; details on the right
Item {
    id: page
    property string filter: ""
    property string scope: "explicit"       // explicit | aur | all | orphans
    property string sort: "name"            // name | size | date
    property var confirm: null              // { names, plan } while asking

    readonly property var rows: {
        const q = filter.trim().toLowerCase()
        let list = Store.all
        if (scope === "explicit") list = list.filter(p => p.explicit)
        else if (scope === "aur") list = list.filter(p => p.foreign)
        else if (scope === "orphans") list = list.filter(p => Store.orphans.indexOf(p.name) !== -1)
        if (q) list = list.filter(p => (p.name + " " + p.description).toLowerCase().indexOf(q) !== -1)
        if (sort === "size") list = list.slice().sort((a, b) => b.size - a.size)
        else if (sort === "date") list = list.slice().sort((a, b) => Date.parse(b.date) - Date.parse(a.date))
        return list
    }
    readonly property real totalSize: rows.reduce((s, p) => s + p.size, 0)

    function askRemove(names) {
        Store.removePlan(names, (plan, err) => { confirm = { names: names, plan: plan, error: err } })
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 6
            Repeater {
                model: [{ id: "explicit", label: "Explicit" }, { id: "aur", label: "AUR" }, { id: "orphans", label: "Orphans" }, { id: "all", label: "All" }]
                UiButton {
                    required property var modelData
                    label: modelData.label + (modelData.id === "orphans" && Store.orphans.length ? " " + Store.orphans.length : "")
                    primary: page.scope === modelData.id
                    danger: modelData.id === "orphans" && Store.orphans.length > 0 && page.scope !== "orphans"
                    onClicked: page.scope = modelData.id
                }
            }
            UiField { Layout.fillWidth: true; placeholderText: "filter by name or description"; onTextChanged: page.filter = text }
            UiCombo { entries: [{ label: "by name", value: "name" }, { label: "by size", value: "size" }, { label: "by install date", value: "date" }]; value: page.sort; onPicked: v => page.sort = v }
            Text { text: page.rows.length + " packages · " + Store.human(page.totalSize); color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            UiButton { visible: page.scope === "orphans" && Store.orphans.length > 0; label: "Remove all orphans"; danger: true; small: true; onClicked: page.askRemove(Store.orphans) }
            UiField { id: installField; Layout.preferredWidth: 180; placeholderText: "install… (paru -S)"; onAccepted: if (text.trim()) { Store.install(text.trim()); text = "" } }
        }

        // ---------- confirmation ----------
        Card {
            visible: page.confirm !== null
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 10
            title: page.confirm ? "Remove " + page.confirm.names.join(", ") + "?" : ""
            subtitle: page.confirm ? (page.confirm.plan ? "pacman -Rns would remove " + page.confirm.plan.length + " package" + (page.confirm.plan.length === 1 ? "" : "s") + " (with their unneeded dependencies). polkit asks your password." : "pacman refuses: " + page.confirm.error) : ""
            Text { Layout.fillWidth: true; visible: !!(page.confirm && page.confirm.plan); text: page.confirm && page.confirm.plan ? page.confirm.plan.join("   ") : ""; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap }
            RowLayout {
                Item { Layout.fillWidth: true }
                UiButton { label: "Cancel"; onClicked: page.confirm = null }
                UiButton { label: "Remove"; danger: true; enabledBtn: !!(page.confirm && page.confirm.plan); onClicked: { Store.remove(page.confirm.names); page.confirm = null } }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    width: parent.width
                    spacing: 1
                    Repeater {
                        model: page.rows
                        Rectangle {
                            id: r
                            required property var modelData
                            readonly property var p: modelData
                            readonly property bool orphan: Store.orphans.indexOf(p.name) !== -1
                            Layout.fillWidth: true
                            Layout.leftMargin: 12; Layout.rightMargin: 6
                            implicitHeight: 44
                            radius: Ui.radius
                            color: Store.detailName === p.name ? Ui.surface : (rm.containsMouse ? Ui.faint : "transparent")
                            MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; onClicked: Store.showDetails(r.p.name) }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                                spacing: 10
                                ColumnLayout {
                                    Layout.preferredWidth: 260
                                    spacing: 1
                                    RowLayout {
                                        spacing: 6
                                        Text { text: r.p.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; font.bold: true }
                                        Badge { visible: r.p.foreign; text: "AUR"; tint: Ui.yellow }
                                        Badge { visible: r.orphan; text: "orphan"; tint: Ui.red; tip: "installed as a dependency, needed by nothing" }
                                        Badge { visible: !r.p.explicit && !r.orphan && page.scope === "all"; text: "dep"; tint: Ui.subtext }
                                    }
                                    Text { Layout.fillWidth: true; text: r.p.version; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                                }
                                Text { Layout.fillWidth: true; text: r.p.description; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                                Text { Layout.preferredWidth: 70; horizontalAlignment: Text.AlignRight; text: Store.human(r.p.size); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                                Text { Layout.preferredWidth: 110; text: r.p.date.slice(0, 15); color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                                RowLayout {
                                    spacing: 4
                                    opacity: rm.containsMouse || Store.detailName === r.p.name ? 1 : 0.3
                                    UiButton { visible: r.p.url !== ""; icon: "󰖟"; small: true; tooltip: r.p.url; onClicked: Store.openUrl(r.p.url) }
                                    UiButton { visible: !r.p.explicit; icon: "󰐕"; small: true; tooltip: "mark as explicitly installed (keeps it from being an orphan)"; onClicked: Store.markExplicit(r.p.name, true) }
                                    UiButton { visible: r.p.explicit; icon: "󰍴"; small: true; tooltip: "mark as a dependency (removed when nothing needs it)"; onClicked: Store.markExplicit(r.p.name, false) }
                                    UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove (pacman -Rns)"; enabledBtn: r.p.requiredBy.length === 0; onClicked: page.askRemove([r.p.name]) }
                                }
                            }
                        }
                    }
                    Text { visible: page.rows.length === 0; Layout.margins: 12; text: Store.ready ? "nothing here" : "reading pacman…"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                    Item { height: 16 }
                }
            }

            // ---------- details ----------
            Rectangle {
                visible: Store.detailName !== ""
                Layout.fillHeight: true
                Layout.preferredWidth: 440
                Layout.rightMargin: 12; Layout.bottomMargin: 12
                color: Ui.raised
                border.width: 1; border.color: Ui.surface
                radius: Ui.cardRadius
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                    RowLayout {
                        Text { Layout.fillWidth: true; text: Store.detailName; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize; font.bold: true }
                        UiButton { icon: "󰅖"; small: true; onClicked: Store.detailName = "" }
                    }
                    ScrollView {
                        id: dsv
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true; contentWidth: availableWidth
                        TextEdit {
                            width: dsv.availableWidth
                            readOnly: true; selectByMouse: true
                            text: Store.detailText + (Store.detailFiles ? "\n\nFiles (first 400):\n" + Store.detailFiles : "")
                            color: Ui.text; selectionColor: Ui.accent; selectedTextColor: Ui.crust
                            font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                            wrapMode: TextEdit.Wrap
                        }
                    }
                }
            }
        }
    }
}
