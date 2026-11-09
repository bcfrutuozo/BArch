import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the library tied to MusicBrainz (server/music/barch_music/library.py): the pipeline goes over every
// album of /music while idle and writes the MusicBrainz ids on the files it is sure about; the rest
// waits here. Pick the release after comparing it with the files (Tag; Reorder when the files are the
// same songs in another order: they are renumbered and renamed to MusicBrainz's order, then tagged), send
// an album MusicBrainz lacks to its release editor (Add to MusicBrainz, then Tag with the new release),
// Delete the files you have (the album goes back to Lidarr's search), or Skip it.
Item {
    id: page
    readonly property var lib: Store.library
    readonly property var counts: lib.counts || {}
    readonly property int judged: Object.keys(counts).reduce((a, k) => a + counts[k], 0)
    property string selected: ""
    readonly property var entry: (lib.decide || []).filter(e => e.folder === selected)[0] || null

    // the list, updated in place (no jump to the top when the sweep moves on)
    ListModel { id: rows }
    function sync() {
        const list = (lib.decide || []).map(e => ({ folder: e.folder, json: JSON.stringify({ state: e.state, why: e.why }) }))
        const keep = {}
        for (const r of list) keep[r.folder] = true
        for (let i = rows.count - 1; i >= 0; i--) if (!keep[rows.get(i).folder]) rows.remove(i)
        for (let i = 0; i < list.length; i++) {
            let j = i
            while (j < rows.count && rows.get(j).folder !== list[i].folder) j++
            if (j === rows.count) { rows.insert(i, list[i]); continue }
            if (j !== i) rows.move(j, i, 1)
            if (rows.get(i).json !== list[i].json) rows.setProperty(i, "json", list[i].json)
        }
        if (!selected && list.length) selected = list[0].folder
    }
    onLibChanged: sync()
    Component.onCompleted: { if (Store.configured) Store.refreshLibrary(); sync() }    // before the config is read, Store.refresh() does it
    Timer { interval: 10000; running: Store.configured; repeat: true; onTriggered: Store.refreshLibrary() }

    // the release in the field, next to the album's files
    property var cmp: null
    property string cmpKey: ""
    property bool cmpBusy: false
    function releaseId(t) { const m = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.exec(t || ""); return m ? m[0] : "" }
    function loadCompare() {
        const id = releaseId(release.text), key = selected + "|" + id
        if (key === cmpKey) return
        cmpKey = key; cmp = null
        if (!id || !selected) return
        cmpBusy = true
        const folder = selected
        Store.api("GET", "/api/library/compare?folder=" + encodeURIComponent(folder) + "&release=" + id, null, d => {
            if (page.cmpKey !== folder + "|" + id) return
            page.cmpBusy = false
            page.cmp = d
        })
    }
    Timer { id: cmpTimer; interval: 400; onTriggered: page.loadCompare() }
    onSelectedChanged: { release.text = ""; cmp = null; cmpKey = ""; confirmDelete = false }
    readonly property var moves: cmp && cmp.reorder ? cmp.reorder.filter(r => r.moves) : []
    function pos(d, i) { return d + "." + String(i).padStart(2, "0") }
    property bool confirmDelete: false
    Timer { id: confirmTimer; interval: 8000; onTriggered: page.confirmDelete = false }

    component Label: Text { color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        // progress
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12; Layout.bottomMargin: 0
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    text: page.judged + " of " + page.lib.albums + " albums looked at  ·  " + ((page.counts.tagged || 0) + (page.counts.had || 0)) + " tied to MusicBrainz"
                        + "  ·  " + (Store.libraryToDecide) + " to decide" + (page.counts.skipped ? "  ·  " + page.counts.skipped + " skipped" : "")
                    color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 6; radius: 3; color: Ui.surface
                    Rectangle { width: page.lib.albums ? parent.width * page.judged / page.lib.albums : 0; height: parent.height; radius: 3; color: Ui.accent }
                }
                Label {
                    text: page.lib.paused ? "paused" : page.lib.current ? "now: " + page.lib.current : page.judged >= page.lib.albums ? "every album looked at" : "waits for the pipeline's queue to be empty"
                    elide: Text.ElideMiddle; Layout.fillWidth: true
                }
            }
            UiButton {
                label: page.lib.paused ? "Resume" : "Pause"; icon: page.lib.paused ? "󰐊" : "󰏤"; small: true
                tooltip: "the sweep runs one album at a time while no download waits; pausing keeps what it did"
                onClicked: Store.libraryAct("sweep", { action: page.lib.paused ? "resume" : "pause" })
            }
        }
        Text {
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
            text: "Every album of /music is matched to MusicBrainz with the lengths of its own files. A sure match gets the MusicBrainz ids written on its files (nothing else changes, an undo log is kept) and Lidarr maps it; these are the ones the matcher could not settle."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            // the albums to decide
            ListView {
                Layout.preferredWidth: 340
                Layout.fillHeight: true
                clip: true
                model: rows
                spacing: 2
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: item
                    required property string folder
                    required property string json
                    readonly property var e: JSON.parse(json)
                    width: ListView.view.width - 10; x: 6
                    implicitHeight: il.implicitHeight + 10
                    radius: Ui.radius
                    color: page.selected === folder ? Ui.surface : im.containsMouse ? Ui.faint : "transparent"
                    ColumnLayout {
                        id: il
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 8 }
                        spacing: 1
                        Text { Layout.fillWidth: true; text: item.folder; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: (item.e.state === "none" ? "not on MusicBrainz? " : item.e.state === "error" ? "error: " : item.e.state === "deleting" ? "deleting… " : "") + (item.e.why || "")
                            color: item.e.state === "error" ? Ui.red : item.e.state === "none" ? Ui.yellow : item.e.state === "deleting" ? Ui.accent : Ui.subtext
                            font.family: Ui.font; font.pixelSize: Ui.fontSize - 3
                        }
                    }
                    MouseArea { id: im; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.selected = item.folder }
                }
                Text {
                    anchors.centerIn: parent; visible: rows.count === 0
                    text: page.judged ? "Nothing to decide." : "The sweep has not started yet."
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
            // the selected album
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true
                visible: !!page.entry
                ColumnLayout {
                    width: parent.width
                    spacing: 12
                    Item { implicitHeight: 2 }
                    Card {
                        Layout.leftMargin: 14; Layout.rightMargin: 14
                        title: page.entry ? page.entry.folder : ""
                        subtitle: page.entry ? (page.entry.why || "") + "  ·  " + (page.entry.tracks || []).length + " files" : ""
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            UiButton { label: "Add to MusicBrainz"; icon: "󰐕"; small: true; tooltip: "opens MusicBrainz's release editor filled in with this album (titles, lengths); submit it there, then paste the new release below and Tag"; onClicked: Store.libraryMbAdd(page.selected) }
                            UiButton { label: "Look again"; icon: "󰑐"; small: true; tooltip: "the matcher tries this album again in the next idle step (MusicBrainz may have it now)"; onClicked: Store.libraryAct("retry", { folder: page.selected }) }
                            UiButton { label: "Skip"; icon: "󰒭"; small: true; tooltip: "leave this album without MusicBrainz ids (not asked again)"; onClicked: Store.libraryAct("skip", { folder: page.selected }) }
                            UiButton {
                                // the label never changes: a longer one made the button wrap to the next line of the
                                // Flow, out from under the cursor, so the second click missed it
                                label: "Delete"; icon: "󰆴"; small: true; danger: true
                                armed: page.confirmDelete
                                enabledBtn: !page.entry || page.entry.state !== "deleting"
                                tooltip: "the files you have leave /music (kept 30 days in /music/.library-trash), Plex drops the album and Lidarr monitors and searches it again, so the pipeline brings a catalogued edition; click twice; it runs in the background and the entry shows \"deleting\" meanwhile"
                                onClicked: {
                                    if (!page.confirmDelete) { page.confirmDelete = true; confirmTimer.restart(); return }
                                    page.confirmDelete = false
                                    Store.libraryAct("delete", { folder: page.selected, release: page.releaseId(release.text) })
                                }
                            }
                            Text {
                                visible: page.confirmDelete
                                height: 24; verticalAlignment: Text.AlignVCenter
                                text: "click Delete again: the files go to the trash and Lidarr searches the album"
                                color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                            }
                        }
                    }
                    Card {
                        Layout.leftMargin: 14; Layout.rightMargin: 14
                        visible: page.entry && (page.entry.candidates || []).length > 0
                        title: "MusicBrainz candidates"
                        subtitle: "Use one to compare it with the files below."
                        Repeater {
                            model: page.entry ? page.entry.candidates || [] : []
                            Rectangle {
                                id: cand
                                required property var modelData
                                readonly property bool chosen: release.text.indexOf(modelData.mbid) !== -1
                                Layout.fillWidth: true
                                implicitHeight: cc.implicitHeight + 12
                                radius: Ui.radius
                                color: chosen ? Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.15) : Ui.sunken
                                RowLayout {
                                    id: cc
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 8 }
                                    spacing: 10
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text { Layout.fillWidth: true; text: cand.modelData.artist + " – " + cand.modelData.title + (cand.modelData.reordered ? "  (same songs, other order)" : ""); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true; elide: Text.ElideRight }
                                        Label { text: [cand.modelData.date, cand.modelData.country, cand.modelData.tracks + " tracks", "score " + cand.modelData.score].filter(x => x).join("  ·  ") }
                                        Label { Layout.fillWidth: true; text: (cand.modelData.why || []).join("; "); wrapMode: Text.Wrap; color: Ui.overlay }
                                    }
                                    UiButton { icon: "󰌹"; small: true; tooltip: "open in MusicBrainz"; onClicked: Store.openUrl(cand.modelData.url) }
                                    UiButton { label: cand.chosen ? "Chosen" : "Use"; small: true; primary: cand.chosen; onClicked: release.text = cand.chosen ? "" : cand.modelData.mbid }
                                }
                            }
                        }
                    }
                    Card {
                        Layout.leftMargin: 14; Layout.rightMargin: 14
                        title: "Release"
                        subtitle: page.cmpBusy ? "asking MusicBrainz…" : page.cmp ? cmpTable.subtitle() : "A candidate above, or any MusicBrainz release id or URL."
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            UiField { id: release; Layout.fillWidth: true; mono: true; placeholderText: "MusicBrainz release id or URL"; onTextChanged: cmpTimer.restart() }
                            UiButton {
                                label: "Tag"; icon: "󰓹"; primary: page.moves.length === 0
                                enabledBtn: page.releaseId(release.text) !== ""
                                tooltip: "write this release's MusicBrainz ids on the album's files (only the ids; undo log kept) and let Lidarr map it"
                                onClicked: Store.libraryAct("tag", { folder: page.selected, release: release.text })
                            }
                            UiButton {
                                label: "Reorder"; icon: "󰒺"; primary: true
                                visible: page.moves.length > 0
                                tooltip: "the files are renumbered and renamed to this release's order (TRACKNUMBER and the \"D.TT - \" of the name; titles and audio untouched, undo log kept), then tagged with its ids"
                                onClicked: Store.libraryAct("reorder", { folder: page.selected, release: release.text })
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: page.moves.length > 0
                            text: "The same songs in another order. Reorder moves " + page.moves.map(r => page.pos(r.disc, r.index) + " → " + page.pos(r.to_disc, r.to_pos) + " (" + r.title + ")").join(", ") + "."
                            color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap
                        }
                        CompareTable { id: cmpTable; cmp: page.cmp; oursLabel: "your files" }
                    }
                    Item { implicitHeight: 8 }
                }
            }
        }
    }
}
