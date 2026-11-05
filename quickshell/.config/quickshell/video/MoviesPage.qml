import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Radarr's movies as posters, each with its checklist (orig / PT-BR / EN sub / PT sub), what it is
// waiting for, and the dub job. A click opens the movie on the right: file, media, profile, the dub,
// Search now and the interactive releases.
Item {
    id: page
    property string filter: "all"
    property string needle: ""

    function keep(m) {
        if (needle && m.title.toLowerCase().indexOf(needle.toLowerCase()) < 0) return false
        if (filter === "missing") return !m.has_file
        if (filter === "incomplete") return m.has_file && !m.complete
        if (filter === "downloading") return !!m.queue
        if (filter === "ok") return m.complete
        return true
    }
    function stateOf(m) {
        if (m.queue) return { text: "downloading " + Math.floor(m.queue.progress) + " %", tint: Ui.accent }
        if (!m.has_file) return { text: m.monitored ? "wanted" : "not monitored", tint: m.monitored ? Ui.yellow : Ui.overlay }
        if (m.complete) return { text: "complete", tint: Ui.green }
        return { text: m.dub ? "dub: " + m.dub : "incomplete", tint: m.dub ? Store.dubTint(m.dub) : Ui.yellow }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 16; Layout.topMargin: 8
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                UiField { Layout.fillWidth: true; placeholderText: "filter by title"; onTextChanged: page.needle = text }
                UiCombo {
                    entries: [{ label: "All", value: "all" }, { label: "Wanted (no file)", value: "missing" }, { label: "Incomplete (audio/subs)", value: "incomplete" },
                              { label: "Downloading", value: "downloading" }, { label: "Complete", value: "ok" }]
                    value: page.filter
                    onPicked: v => page.filter = v
                }
                UiButton { label: "Reload"; icon: "󰑓"; small: true; onClicked: Store.loadMovies() }
            }
            Text {
                text: Store.moviesLoading && !Store.movies.length ? "Reading Radarr…"
                    : grid.count + " of " + Store.movies.length + " movies · " + Store.movies.filter(m => m.complete).length + " complete · "
                      + Store.movies.filter(m => !m.has_file).length + " wanted"
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
            }
            GridView {
                id: grid
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                cellWidth: Math.max(140, Math.floor(width / Math.max(1, Math.floor(width / 160))))
                cellHeight: 300
                model: Store.movies.filter(m => page.keep(m))
                ScrollBar.vertical: ScrollBar {}
                delegate: Item {
                    id: cell
                    required property var modelData
                    width: grid.cellWidth; height: grid.cellHeight
                    readonly property var st: page.stateOf(modelData)
                    readonly property bool current: Store.movie && Store.movie.id === modelData.id
                    Rectangle {
                        anchors.fill: parent; anchors.margins: 4
                        radius: Ui.cardRadius
                        color: cell.current ? Ui.surface : (cm.containsMouse ? Ui.faint : "transparent")
                    }
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 10
                        spacing: 4
                        Poster {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: Math.min(cell.width - 20, 124); Layout.preferredHeight: Layout.preferredWidth * 1.5
                            source: cell.modelData.poster || ""; title: cell.modelData.title
                        }
                        Text { Layout.fillWidth: true; text: cell.modelData.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter }
                        Text {
                            Layout.fillWidth: true
                            text: (cell.modelData.year || "") + (cell.modelData.quality ? " · " + cell.modelData.quality : "") + " · " + cell.modelData.profile.replace("BArch ", "")
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter
                        }
                        Checks { Layout.alignment: Qt.AlignHCenter; check: cell.modelData.check; compact: true; visible: cell.modelData.has_file }
                        Badge { Layout.alignment: Qt.AlignHCenter; text: cell.st.text; tint: cell.st.tint }
                        Item { Layout.fillHeight: true }
                    }
                    MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.openMovie(cell.modelData.id) }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface; visible: Store.movie !== null || Store.detailLoading }
        MovieDetail {
            Layout.fillHeight: true
            Layout.preferredWidth: 460
            visible: Store.movie !== null || Store.detailLoading
        }
    }
}
