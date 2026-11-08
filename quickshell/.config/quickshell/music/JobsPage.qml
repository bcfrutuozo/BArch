import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the jobs on the left (the review queue, or all of them with a filter), the chosen one on the right
Item {
    id: page
    property string fixedState: ""        // "review": only the queue; "": every job, filterable
    property string filter: ""
    property string query: ""

    readonly property var list: Store.jobs.filter(j =>
        (fixedState ? j.state === fixedState : (!filter || j.state === filter))
        && (!query || (j.name + " " + (j.folder || "") + " " + (j.match || "")).toLowerCase().indexOf(query.toLowerCase()) !== -1))

    Component.onCompleted: if (list.length && !list.some(j => j.id === Store.selected)) Store.select(list[0].id)

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            Layout.preferredWidth: 360
            Layout.maximumWidth: 360
            Layout.fillWidth: false
            Layout.fillHeight: true
            spacing: 6
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 12; Layout.bottomMargin: 0
                spacing: 6
                UiField { Layout.fillWidth: true; placeholderText: "filter"; onTextChanged: page.query = text }
                UiCombo {
                    visible: !page.fixedState
                    Layout.preferredWidth: 120
                    entries: [{ label: "all", value: "" }].concat(Store.states.map(s => ({ label: s, value: s })))
                    value: page.filter
                    onPicked: v => page.filter = v
                }
            }
            // one decision for every album that waits only because no source has the day of its release
            UiButton {
                visible: page.fixedState === "review" && Store.yearOnly.length > 0
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.fillWidth: true
                label: Store.acceptingYear ? "Accepting the year…" : "Accept the year for " + Store.yearOnly.length + " album" + (Store.yearOnly.length === 1 ? "" : "s")
                enabled: !Store.acceptingYear
                tooltip: "These wait only for a full release date that MusicBrainz, Wikidata and Wikipedia do not have. This resolves them all with --date-year-only (DATE becomes YYYY-01-01):\n" + Store.yearOnly.map(j => "  " + j.name).join("\n")
                onClicked: Store.acceptYear()
            }
            Text {
                Layout.leftMargin: 14
                visible: page.list.length === 0
                text: page.fixedState === "review" ? "Nothing waits for a decision." : "No jobs."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 2
                model: page.list
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool current: Store.selected === modelData.id
                    width: ListView.view.width - 16
                    x: 8
                    implicitHeight: rc.implicitHeight + 14
                    radius: Ui.radius
                    color: current ? Ui.surface : (rm.containsMouse ? Ui.faint : "transparent")
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.select(row.modelData.id) }
                    ColumnLayout {
                        id: rc
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 10 }
                        spacing: 2
                        RowLayout {
                            spacing: 6
                            Rectangle { implicitWidth: 8; implicitHeight: 8; radius: 4; color: Store.stateColor(row.modelData.state) }
                            Text { Layout.fillWidth: true; text: row.modelData.name; color: row.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: (row.modelData.problems || [])[0] || row.modelData.folder || row.modelData.state
                            color: (row.modelData.problems || []).length ? Ui.yellow : Ui.subtext
                            font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight
                        }
                        Text { text: Store.when(row.modelData.updated) + " · " + row.modelData.kind; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                    }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Text {
                anchors.centerIn: parent
                visible: !Store.selected
                text: "Pick an album on the left."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
            // a new JobDetail per job, so its form starts empty
            Repeater {
                model: Store.selected ? [Store.selected] : []
                JobDetail { required property var modelData; anchors.fill: parent; jobId: modelData }
            }
        }
    }
}
