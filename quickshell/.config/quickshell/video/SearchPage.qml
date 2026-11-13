pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TMDB (Radarr) and TVDB (Sonarr) lookups: type, Enter, and each result is added with a profile.
// "auto" adds it with BArch 4K, looks at the 2160p releases that fit, and falls back to BArch 1080p
// when none does (video.py add); then the search starts.
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
            UiButton { label: "Movies"; icon: "󰎁"; primary: Store.kind === "movie"; onClicked: { Store.kind = "movie"; if (field.text) Store.search(field.text, "movie") } }
            UiButton { label: "Series"; icon: "󰟞"; primary: Store.kind === "series"; onClicked: { Store.kind = "series"; if (field.text) Store.search(field.text, "series") } }
            UiField {
                id: field
                Layout.fillWidth: true
                text: Store.query
                placeholderText: Store.kind === "movie" ? "a movie title (or tmdb:603)" : "a series title (or tvdb:153021)"
                onAccepted: Store.search(text)
            }
            UiButton { label: Store.searching ? "Searching…" : "Search"; icon: "󰍉"; primary: true; enabledBtn: !Store.searching; onClicked: Store.search(field.text) }
        }
        Text {
            visible: Store.results.length === 0
            Layout.fillWidth: true
            text: Store.searching ? "Asking " + (Store.kind === "movie" ? "Radarr (TMDB)" : "Sonarr (TVDB)") + "…"
                : Store.query ? "Nothing found."
                : "Search a movie or a series. Add puts it in Radarr or Sonarr with the BArch 4K profile (or 1080p when no 4K release fits) and starts the search; the PT-BR pipeline then muxes the dub into the file."
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
            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property string key: modelData.kind + ":" + modelData.id
                readonly property bool have: !!modelData.library_id
                width: list.width
                implicitHeight: Math.max(108, info.implicitHeight + 16)
                radius: Ui.cardRadius
                color: Ui.raised
                RowLayout {
                    anchors.fill: parent; anchors.margins: 8
                    spacing: 12
                    Poster { source: row.modelData.poster || ""; title: row.modelData.title; Layout.preferredWidth: 60; Layout.preferredHeight: 90 }
                    ColumnLayout {
                        id: info
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            spacing: 6
                            Text {
                                Layout.fillWidth: true
                                text: row.modelData.title + (row.modelData.year ? " (" + row.modelData.year + ")" : "")
                                color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; elide: Text.ElideRight
                            }
                            Badge { visible: row.have; text: "in library"; tint: Ui.green }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: [row.modelData.original ? "original: " + row.modelData.original : "",
                                   row.modelData.runtime ? row.modelData.runtime + " min" : "",
                                   row.modelData.network || "",
                                   row.modelData.seasons ? row.modelData.seasons + " seasons" : "",
                                   row.modelData.status || ""].filter(x => x).join(" · ")
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight
                        }
                        Text {
                            visible: text !== ""
                            Layout.fillWidth: true
                            text: row.modelData.overview || ""
                            color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                            wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
                        }
                    }
                    ColumnLayout {
                        spacing: 4
                        Layout.preferredWidth: 150
                        UiCombo {
                            id: prof
                            visible: !row.have
                            Layout.fillWidth: true
                            entries: [{ label: "auto (4K, else 1080p)", value: "auto" }, { label: "BArch 4K", value: "4k" }, { label: "BArch 1080p", value: "1080p" }]
                            value: "auto"
                            onPicked: v => value = v
                        }
                        UiButton {
                            visible: !row.have
                            Layout.fillWidth: true
                            label: Store.adding[row.key] ? "Adding…" : "Add"
                            icon: "󰐕"; primary: true
                            enabledBtn: !Store.adding[row.key]
                            onClicked: Store.add(row.modelData, prof.value)
                        }
                        UiButton {
                            visible: row.have
                            Layout.fillWidth: true
                            label: "Open"; icon: "󰁔"
                            onClicked: {
                                if (row.modelData.kind === "movie") { Store.openMovie(row.modelData.library_id); Store.navigate("movies") }
                                else { Store.openShow(row.modelData.library_id); Store.navigate("series") }
                            }
                        }
                    }
                }
            }
        }
    }
}
