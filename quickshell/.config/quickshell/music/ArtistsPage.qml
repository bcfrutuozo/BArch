pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the library's artists tied to Lidarr's MusicBrainz artists (server/music/barch_music/artists.py), the
// way the Library page ties the albums. Every artist folder of /music should be one Lidarr artist with
// the right MusicBrainz id at that folder, or Lidarr never maps its files. The folders without one (or
// with a namesake: Lidarr maps none of their tagged albums) wait here with the MusicBrainz artists their
// own albums are credited to: Link one. Lidarr artists with no folder yet (an import list added them) can
// be replaced by the right one or removed; "Add an artist" tracks one the library does not have yet.
Item {
    id: page
    property string filter: "decide"          // decide | skipped | lidarr | all
    property string selected: ""              // a row's key, or "__add__"
    property string search: ""
    readonly property var rows: (Store.artistsData.artists || []).filter(r =>
        (filter === "all" || (filter === "decide" && Store.decideStates.indexOf(r.state) !== -1)
         || (filter === "skipped" && (r.state === "skipped" || r.state === "pending")) || (filter === "lidarr" && r.state === "no-folder"))
        && (!search || page.norm(r.folder || (r.lidarr || {}).name || "").indexOf(page.norm(search)) !== -1))
    readonly property var entry: (Store.artistsData.artists || []).filter(r => r.key === selected)[0] || null
    readonly property bool adding: selected === "__add__"
    readonly property var counts: Store.artistsData.counts || {}
    function norm(s) { return (s || "").normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase() }
    function count(states) { return states.reduce((a, s) => a + (page.counts[s] || 0), 0) }

    Component.onCompleted: if (Store.configured) Store.refreshArtists()
    Timer { interval: 30000; running: Store.configured; repeat: true; onTriggered: Store.refreshArtists() }
    onRowsChanged: if (!selected && rows.length) selected = rows[0].key

    // the MusicBrainz artists for the selected row (or the name typed)
    property var cands: null
    property bool candBusy: false
    property string candKey: ""
    function loadCandidates(q) {
        const folder = page.entry ? page.entry.folder : ""
        const name = q || folder || (page.entry && page.entry.lidarr ? page.entry.lidarr.name : "")
        if (!name) { cands = null; return }
        const key = selected + "|" + (q || "")
        candKey = key; candBusy = true; cands = null
        Store.artistCandidates(q ? "" : folder, q ? q : (folder ? "" : name), d => {
            if (page.candKey !== key) return
            page.candBusy = false
            page.cands = d
        })
    }
    // later: the handler runs before the `entry` binding follows `selected`
    onSelectedChanged: { confirmRemove = false; confirmMove = ""; cands = null; candKey = ""; Qt.callLater(opened) }
    function opened() {
        query.text = adding ? "" : entry ? (entry.folder || (entry.lidarr || {}).name || "") : ""
        if (!adding && entry) loadCandidates("")
    }
    property bool confirmRemove: false
    property string confirmMove: ""            // the candidate whose Move waits for its second click
    Timer { id: moveTimer; interval: 8000; onTriggered: page.confirmMove = "" }
    Timer { id: confirmTimer; interval: 8000; onTriggered: page.confirmRemove = false }

    function stateColor(s) { return s === "linked" ? Ui.green : s === "suspect" ? Ui.red : s === "missing" ? Ui.yellow : s === "pending" ? Ui.accent : Ui.overlay }
    function label(r) { return r.folder || (r.lidarr ? r.lidarr.name : "") }

    component Label: Text { color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
    component Chip: Rectangle {
        id: chip
        property string value
        property string text
        readonly property bool on: page.filter === value
        implicitWidth: ct.implicitWidth + 18; implicitHeight: 24; radius: 12
        color: on ? Ui.accent : cm.containsMouse ? Ui.faint : "transparent"
        border.width: on ? 0 : 1; border.color: Ui.surface
        Text { id: ct; anchors.centerIn: parent; text: chip.text; color: chip.on ? Ui.crust : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
        MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { page.filter = chip.value; page.selected = "" } }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        Text {
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 12; Layout.fillWidth: true
            text: (page.counts.linked || 0) + " of " + ((Store.artistsData.artists || []).filter(r => r.folder).length) + " artist folders tied to a Lidarr artist  ·  "
                + page.count(["missing", "suspect"]) + " to decide  ·  " + (page.counts["no-folder"] || 0) + " Lidarr artists with nothing in /music yet"
            color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
        Text {
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
            text: "Lidarr knows an artist by its MusicBrainz id and keeps one folder of /music for it; an album's files only map when their folder belongs to the artist MusicBrainz credits the release to. Link each folder to its artist: the ones its own albums are credited to come first."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.leftMargin: 12; Layout.rightMargin: 12
            spacing: 6
            Chip { value: "decide"; text: "To decide  " + page.count(["missing", "suspect"]) }
            Chip { value: "skipped"; text: "Skipped & waiting  " + page.count(["skipped", "pending"]) }
            Chip { value: "lidarr"; text: "Not in /music yet  " + (page.counts["no-folder"] || 0) }
            Chip { value: "all"; text: "All" }
            UiField { Layout.preferredWidth: 220; placeholderText: "filter"; onTextChanged: page.search = text }
            Item { Layout.fillWidth: true }
            UiButton { label: "Add an artist"; icon: "󰐕"; small: true; primary: page.adding; tooltip: "track an artist you do not have yet (one an import list could not map): Lidarr brings its official albums"; onClicked: page.selected = "__add__" }
            UiButton { icon: "󰑓"; small: true; tooltip: "read Lidarr and /music again"; onClicked: Store.refreshArtists() }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            ListView {
                Layout.preferredWidth: 340
                Layout.fillHeight: true
                clip: true
                model: page.rows
                spacing: 2
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: item
                    required property var modelData
                    width: ListView.view.width - 10; x: 6
                    implicitHeight: il.implicitHeight + 10
                    radius: Ui.radius
                    color: page.selected === modelData.key ? Ui.surface : im.containsMouse ? Ui.faint : "transparent"
                    ColumnLayout {
                        id: il
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 8 }
                        spacing: 1
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { Layout.fillWidth: true; text: page.label(item.modelData); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                            Badge { text: item.modelData.state; tint: page.stateColor(item.modelData.state) }
                        }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: (item.modelData.folder ? item.modelData.albums + (item.modelData.albums === 1 ? " album" : " albums") + (item.modelData.tagged ? ", " + item.modelData.tagged + " tied" : "") + "  ·  " : "") + (item.modelData.why || "")
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3
                        }
                    }
                    MouseArea { id: im; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: page.selected = item.modelData.key }
                }
                Text {
                    anchors.centerIn: parent; visible: page.rows.length === 0
                    text: (Store.artistsData.artists || []).length ? "Nothing here." : "Asking the pipeline…"
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                }
            }
            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true
                visible: page.adding || !!page.entry
                ColumnLayout {
                    width: parent.width
                    spacing: 12
                    Item { implicitHeight: 2 }
                    // the row itself
                    Card {
                        Layout.leftMargin: 14; Layout.rightMargin: 14
                        visible: !page.adding && !!page.entry
                        title: page.entry ? page.label(page.entry) : ""
                        subtitle: page.entry ? (page.entry.folder ? "/music/" + page.entry.folder + "  ·  " + page.entry.albums + " album folders, " + page.entry.tagged + " tied to MusicBrainz" : "a Lidarr artist with no folder in /music yet") + "\n" + (page.entry.why || "") : ""
                        RowLayout {
                            Layout.fillWidth: true
                            visible: !!(page.entry && page.entry.lidarr)
                            spacing: 8
                            Badge { text: "Lidarr"; tint: Ui.accent }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight
                                text: page.entry && page.entry.lidarr ? page.entry.lidarr.name + "  ·  " + page.entry.lidarr.mbid + "  ·  " + (page.entry.lidarr.files || 0) + " files mapped  ·  " + page.entry.lidarr.path : ""
                                color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                            }
                            UiButton { icon: "󰌹"; small: true; tooltip: "the artist on MusicBrainz"; onClicked: Store.openUrl("https://musicbrainz.org/artist/" + page.entry.lidarr.mbid) }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            UiButton {
                                visible: !!(page.entry && page.entry.folder); label: "Open folder"; icon: "󰉋"; small: true
                                onClicked: Store.openUrl("file:///mnt/nasfrutuozo/media/music/" + page.entry.folder)
                            }
                            UiButton {
                                visible: !!(page.entry && page.entry.folder && page.entry.state !== "linked" && page.entry.state !== "skipped")
                                label: "Skip"; icon: "󰒭"; small: true
                                tooltip: "leave this folder without a Lidarr artist (a credit MusicBrainz has no artist for, or a second folder of one Lidarr keeps elsewhere)"
                                onClicked: Store.artistAct("skip", { folder: page.entry.folder })
                            }
                            UiButton {
                                visible: !!(page.entry && page.entry.state === "skipped"); label: "Unskip"; icon: "󰑐"; small: true
                                onClicked: Store.artistAct("unskip", { folder: page.entry.folder })
                            }
                            UiButton {
                                visible: !!(page.entry && page.entry.lidarr && !page.entry.lidarr.files)
                                label: "Remove from Lidarr"; icon: "󰆴"; small: true; danger: true; armed: page.confirmRemove
                                tooltip: "the artist leaves Lidarr (no file is touched; it maps none); click twice"
                                onClicked: {
                                    if (!page.confirmRemove) { page.confirmRemove = true; confirmTimer.restart(); return }
                                    page.confirmRemove = false
                                    Store.artistAct("remove", { id: page.entry.lidarr.id }, () => page.selected = "")
                                }
                            }
                            Text {
                                visible: page.confirmRemove; height: 24; verticalAlignment: Text.AlignVCenter
                                text: "click again: the artist leaves Lidarr"
                                color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                            }
                        }
                    }
                    // the MusicBrainz artists
                    Card {
                        Layout.leftMargin: 14; Layout.rightMargin: 14
                        title: page.adding ? "Add an artist" : "MusicBrainz artists"
                        subtitle: page.candBusy ? "asking MusicBrainz… (one request a second; the folder's albums are looked up the first time)"
                            : page.adding ? "Search by name (or paste an artist's MusicBrainz URL); Add tracks it in Lidarr at the folder its name gives, and the hourly check brings its official albums."
                            : page.entry && page.entry.folder ? "Link makes /music/" + page.entry.folder + " that artist in Lidarr" + (page.entry.lidarr ? " (" + page.entry.lidarr.name + " leaves Lidarr; the files stay)" : "") + "."
                            : "Replace removes " + (page.entry && page.entry.lidarr ? page.entry.lidarr.name : "this artist") + " from Lidarr and tracks the one you pick instead."
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            UiField { id: query; Layout.fillWidth: true; placeholderText: "artist name, MusicBrainz id or URL"; onAccepted: page.loadCandidates(text) }
                            UiButton { label: "Search"; icon: "󰍉"; small: true; enabledBtn: query.text.trim() !== ""; onClicked: page.loadCandidates(query.text) }
                        }
                        Label { visible: !!(page.cands && page.cands.tied); text: page.cands ? page.cands.tied + " of the folder's tied albums looked at" : "" }
                        Repeater {
                            model: page.cands ? page.cands.candidates : []
                            Rectangle {
                                id: cand
                                required property var modelData
                                readonly property var at: modelData.lidarr
                                readonly property bool here: !!(at && page.entry && page.entry.folder && at.path.split("/").pop() === page.entry.folder)
                                readonly property bool elsewhere: !!(at && !here && at.files > 0)
                                Layout.fillWidth: true
                                implicitHeight: cc.implicitHeight + 12
                                radius: Ui.radius
                                color: here ? Qt.rgba(Ui.green.r, Ui.green.g, Ui.green.b, 0.12) : Ui.sunken
                                RowLayout {
                                    id: cc
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 8 }
                                    spacing: 10
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text {
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            text: cand.modelData.name + (cand.modelData.disambiguation ? "  (" + cand.modelData.disambiguation + ")" : "")
                                            color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: true
                                        }
                                        Label { text: [cand.modelData.type, cand.modelData.country, cand.modelData.years, cand.modelData.score ? "score " + cand.modelData.score : ""].filter(x => x).join("  ·  ") }
                                        Label {
                                            visible: cand.modelData.releases > 0
                                            text: "credited on " + cand.modelData.releases + " of the folder's tied albums"
                                            color: Ui.green
                                        }
                                        Label {
                                            visible: !!cand.at
                                            Layout.fillWidth: true; wrapMode: Text.Wrap
                                            text: cand.at ? (cand.here ? "this folder's artist in Lidarr now" : "in Lidarr at " + cand.at.path + " (" + cand.at.files + " files mapped)"
                                                + (cand.elsewhere ? ": Lidarr keeps one folder per artist; Move puts these albums there (or Skip this folder)" : "")) : ""
                                            color: cand.elsewhere ? Ui.yellow : Ui.overlay
                                        }
                                    }
                                    UiButton { icon: "󰌹"; small: true; tooltip: "open in MusicBrainz"; onClicked: Store.openUrl(cand.modelData.url) }
                                    UiButton {
                                        visible: !page.adding && !!(page.entry && page.entry.folder)
                                        label: cand.here ? "Linked" : "Link"; small: true; primary: cand.modelData.releases > 0 && !cand.here
                                        enabledBtn: !cand.here && !cand.elsewhere
                                        tooltip: "make /music/" + (page.entry ? page.entry.folder : "") + " this artist in Lidarr"
                                        onClicked: Store.artistAct("link", { folder: page.entry.folder, mbid: cand.modelData.mbid })
                                    }
                                    UiButton {
                                        // the credited artist keeps another folder: the albums go there, so Lidarr maps them
                                        readonly property string into: cand.elsewhere ? cand.at.path.split("/").pop() : ""
                                        visible: cand.elsewhere && !page.adding && !!(page.entry && page.entry.folder)
                                        label: "Move into " + into; icon: "󰉒"; small: true; primary: page.confirmMove !== cand.modelData.mbid; danger: page.confirmMove === cand.modelData.mbid
                                        armed: page.confirmMove === cand.modelData.mbid
                                        tooltip: "the album folders of /music/" + (page.entry ? page.entry.folder : "") + " move into /music/" + into + " (names kept; one with a name already there stays), Lidarr rescans it, Plex and the Player's catalog follow; click twice"
                                        onClicked: {
                                            if (page.confirmMove !== cand.modelData.mbid) { page.confirmMove = cand.modelData.mbid; moveTimer.restart(); return }
                                            page.confirmMove = ""
                                            Store.artistAct("move", { folder: page.entry.folder, into: into }, () => page.selected = "")
                                        }
                                    }
                                    UiButton {
                                        visible: !page.adding && !!(page.entry && !page.entry.folder)
                                        label: "Replace"; small: true
                                        enabledBtn: !cand.at
                                        tooltip: "remove " + (page.entry && page.entry.lidarr ? page.entry.lidarr.name : "") + " from Lidarr and track this artist instead"
                                        onClicked: {
                                            const id = page.entry.lidarr.id, mbid = cand.modelData.mbid
                                            Store.artistAct("remove", { id: id }, () => Store.artistAct("add", { mbid: mbid }, () => page.selected = ""))
                                        }
                                    }
                                    UiButton {
                                        visible: page.adding
                                        label: cand.at ? "In Lidarr" : "Add"; small: true; primary: !cand.at
                                        enabledBtn: !cand.at
                                        onClicked: Store.artistAct("add", { mbid: cand.modelData.mbid }, () => page.loadCandidates(query.text))
                                    }
                                }
                            }
                        }
                        Label { visible: !!(page.cands && !page.cands.candidates.length); text: "MusicBrainz has no artist by that name." }
                    }
                    Item { implicitHeight: 8 }
                }
            }
        }
    }
}
