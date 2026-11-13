pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Hardcover through Shelfmark: type, Enter, and each book has its Want to Read switch. Hardcover
// Sync turns the shelf into requests and downloads (Sync now in the sidebar runs it at once).
Item {
    id: page
    Component.onCompleted: field.forceActiveFocus()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16; anchors.topMargin: 8
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            UiField {
                id: field
                Layout.fillWidth: true
                text: Store.query
                placeholderText: "title, author, ISBN or a Hardcover list URL"
                onAccepted: Store.search(text, 1)
            }
            UiButton { label: Store.searching ? "Searching…" : "Search"; icon: "󰍉"; primary: true; enabledBtn: !Store.searching; onClicked: Store.search(field.text, 1) }
        }
        Text {
            visible: Store.results.length === 0
            Layout.fillWidth: true
            text: Store.searching ? "Searching Hardcover…" : Store.query ? "Nothing found." : "Search a book: it goes to Want to Read on Hardcover, and Shelfmark downloads it within the hour (or press Sync now)."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize; wrapMode: Text.WordWrap
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: Store.results
            ScrollBar.vertical: ScrollBar {}
            footer: Item {
                width: list.width; height: Store.resultsMore ? 44 : 0
                UiButton { anchors.centerIn: parent; visible: Store.resultsMore; small: true; label: "More"; onClicked: Store.search(Store.query, Store.resultsPage + 1) }
            }
            delegate: Rectangle {
                id: row
                required property var modelData
                width: list.width
                implicitHeight: Math.max(96, info.implicitHeight + 16)
                radius: Ui.cardRadius
                color: Ui.raised
                RowLayout {
                    anchors.fill: parent; anchors.margins: 8
                    spacing: 12
                    Cover { source: row.modelData.cover_file || ""; title: row.modelData.title; Layout.preferredWidth: 54; Layout.preferredHeight: 80 }
                    ColumnLayout {
                        id: info
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            spacing: 6
                            Text {
                                Layout.fillWidth: true
                                text: row.modelData.title + (row.modelData.subtitle ? ": " + row.modelData.subtitle : "")
                                color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; elide: Text.ElideRight
                            }
                            Badge { visible: !!row.modelData.owned; text: "in library"; tint: Ui.green }
                        }
                        Text {
                            text: Store.authors(row.modelData.authors) + (row.modelData.year ? " · " + row.modelData.year : "")
                                  + (row.modelData.series ? " · " + row.modelData.series + (row.modelData.series_position ? " #" + row.modelData.series_position : "") : "")
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight; Layout.fillWidth: true
                        }
                        Text {
                            visible: text !== ""
                            text: row.modelData.description || ""
                            color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                            wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                    ColumnLayout {
                        spacing: 4
                        UiButton {
                            Layout.fillWidth: true
                            readonly property bool on: !!row.modelData.want
                            label: Store.wanting[row.modelData.id] ? "…" : on ? "On the list" : "Want to Read"
                            icon: on ? "󰄲" : "󰐕"
                            primary: !on
                            tooltip: on ? "click to take it off Want to Read" : "Hardcover's Want to Read: Shelfmark requests and downloads it"
                            enabledBtn: !Store.wanting[row.modelData.id]
                            onClicked: Store.setWant(row.modelData, !on)
                        }
                        UiButton { Layout.fillWidth: true; small: true; label: "Hardcover"; icon: "󰏌"; visible: !!row.modelData.url; onClicked: Store.openUrl(row.modelData.url) }
                    }
                }
            }
        }
    }
}
