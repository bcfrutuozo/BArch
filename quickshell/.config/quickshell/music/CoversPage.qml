pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the covers of albums already in /music: the pipeline looks for scans with a frame and for the
// clean artwork of the same album (stores, Cover Art Archive, confirmed visually); each one is
// replaced only here, with Replace (cover.jpg, the art embedded in every track, Plex's poster)
Item {
    id: page
    property bool all: false
    // one artist at a time: picked from the library's list (filtered as you type), nothing shown before that
    readonly property string artist: Store.coversArtist
    property string filterText: ""
    readonly property var filtered: {
        const q = page.norm(page.filterText)
        return Store.artists.filter(a => !q || page.norm(a.name).indexOf(q) !== -1)
    }
    function norm(s) { return String(s || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase() }
    onFilteredChanged: {
        // the typed filter narrows the combo; the first match becomes the choice when the current one left
        if (filtered.length && !filtered.some(a => a.name === page.artist)) Store.coversArtist = filtered[0].name
    }
    // every album folder of the artist, with what the check found when it ran ("unchecked" otherwise);
    // without "show all" the fine ones are left out, the rest (to look at, not yet checked) stay
    // "to decide": the albums of every artist whose check found a cleaner cover, still unanswered (the tab's badge)
    property bool pending: Store.coversToLook > 0 && !Store.coversArtist      // the tab opens on them when there are any
    readonly property var list: {
        if (pending) return Store.covers.entries.filter(e => e.verdict === "better" && !e.applied)
        if (!artist) return []
        const found = {}
        for (const e of Store.covers.entries) if (e.folder.indexOf(artist + "/") === 0) found[e.folder] = e
        return Store.albums.map(a => found[a.folder] || { folder: a.folder, verdict: "unchecked", has_cover: a.cover })
            .filter(e => all || !(e.verdict === "fine" || e.verdict === "kept" || e.verdict === "nothing") || e.applied || e.queued)
    }
    readonly property int unchecked: list.filter(e => e.verdict === "unchecked").length
    // what the ListView shows: frozen while a check runs (the overlay says how far it is) and updated in
    // place, row by row (a Check, a picked candidate change one row only): a new array as the model would
    // rebuild every delegate and throw the scroll back to the top
    ListModel { id: shown }
    function sync() {
        if (Store.coversBusy && shown.count) return
        const rows = list.map(e => ({ folder: e.folder, json: JSON.stringify(e) }))
        const keep = {}
        for (const r of rows) keep[r.folder] = true
        for (let i = shown.count - 1; i >= 0; i--) if (!keep[shown.get(i).folder]) shown.remove(i)
        for (let i = 0; i < rows.length; i++) {
            let j = i
            while (j < shown.count && shown.get(j).folder !== rows[i].folder) j++
            if (j === shown.count) { shown.insert(i, rows[i]); continue }
            if (j !== i) shown.move(j, i, 1)
            if (shown.get(i).json !== rows[i].json) shown.setProperty(i, "json", rows[i].json)
        }
    }
    onListChanged: sync()
    // another artist (or the "to decide" view) starts at the top; a row changing does not
    onArtistChanged: Qt.callLater(() => albumList.positionViewAtBeginning())
    onPendingChanged: Qt.callLater(() => albumList.positionViewAtBeginning())
    Connections { target: Store; function onCoversBusyChanged() { page.sync() } }
    // the progress of the check: the queue is longest right after Check, the rest is done
    property int total: 0
    readonly property int remaining: Store.coversBusy ? (Store.covers.queued || 0) + (Store.covers.running ? 1 : 0) : 0
    onRemainingChanged: { if (remaining > total) total = remaining; if (!remaining) total = 0 }
    Component.onCompleted: if (!Store.artists.length) Store.loadArtists()

    function verdictText(e) {
        return e.verdict === "unchecked" ? (e.has_cover === false ? "no cover.jpg · not checked yet" : "not checked yet")
             : e.verdict === "better" ? "a cleaner cover exists" : e.verdict === "framed" ? "a scan, nothing cleaner found"
             : e.verdict === "fine" ? "fine" : e.verdict === "kept" ? "kept as it is" : e.verdict === "nothing" ? "no image anywhere"
             : e.verdict === "queued" ? "waiting to be checked" : e.verdict === "error" ? "error: " + (e.error || "") : e.verdict
    }
    function verdictColor(e) {
        return e.applied ? Ui.green : e.verdict === "better" ? Ui.yellow : e.verdict === "framed" || e.verdict === "error" ? Ui.red : Ui.subtext
    }

    component Thumb: Rectangle {
        id: th
        property string folder: ""
        property string which: "current"
        property real stamp: 0
        property string label: ""
        property string src: ""
        property int size: 168
        property bool marked: false
        signal picked()
        implicitWidth: size; implicitHeight: size + (label ? 18 : 0)
        color: "transparent"
        function load() { th.src = ""; if (folder) Store.coverImage(folder, which, stamp, p => { if (th) th.src = p }) }   // the row may be gone when the image arrives
        onStampChanged: load()
        onWhichChanged: load()
        Component.onCompleted: load()
        Rectangle {
            id: frame
            width: th.size; height: th.size; radius: Ui.radius
            color: Ui.sunken; clip: true
            border.width: th.marked ? 2 : 0; border.color: Ui.accent
            Image { anchors.fill: parent; source: th.src; fillMode: Image.PreserveAspectFit; asynchronous: true; cache: false; sourceSize: Qt.size(th.size * 2, th.size * 2) }
            Text { anchors.centerIn: parent; visible: th.src === ""; text: "󰝚"; color: Ui.overlay; font.family: Ui.iconFont; font.pixelSize: 34 }
            MouseArea {
                anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: th.src ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: m => { if (!th.src) return; if (m.button === Qt.RightButton || th.size >= 168) big.show(th.src); else th.picked() }
            }
        }
        Text { visible: th.label !== ""; anchors.top: frame.bottom; anchors.topMargin: 3; width: th.size; text: th.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12; Layout.bottomMargin: 0
            spacing: 8
            UiField {
                id: filter; Layout.preferredWidth: 200
                placeholderText: "filter artists…"
                onTextChanged: page.filterText = text          // Enter picks nothing more: only the Check buttons check
            }
            UiCombo {
                id: artistCombo; Layout.preferredWidth: 300
                entries: page.filtered.map(a => ({ label: a.name + "  (" + a.albums + ")", value: a.name }))
                value: page.artist
                onPicked: v => { page.pending = false; Store.coversArtist = String(v) }
            }
            UiButton {
                visible: Store.coversToLook > 0 || page.pending
                label: Store.coversToLook + " to decide"; icon: "󰋩"; small: true; primary: page.pending
                tooltip: "every album, of any artist, whose check found a cleaner cover and still waits for Replace or Keep mine"
                onClicked: page.pending = !page.pending
            }
            UiButton {
                label: "Load"; icon: "󰑐"; primary: true
                enabledBtn: page.artist !== "" && !Store.coversBusy
                tooltip: "read the artist's folders again (an album added or changed meanwhile) and what the checks found; nothing is checked here, each row has its own Check"
                onClicked: { Store.loadArtists(); Store.loadAlbums(page.artist); Store.refreshCovers() }
            }
            Text {
                visible: page.artist !== "" && page.unchecked > 0
                text: page.unchecked + " not checked yet"
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
            }
            Item { Layout.fillWidth: true }
            UiSwitch { implicitWidth: 32; implicitHeight: 18; checked: page.all; onToggled: v => page.all = v }
            Text { text: "show all"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
        }
        Text {
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
            text: "Every album of the artist, with its cover as it is. Check (one album at a time) looks for a scan frame and for the label's clean artwork of the same album (iTunes, Deezer, Cover Art Archive, Discogs), confirmed by comparing the pictures. Replace writes cover.jpg, the picture embedded in every track and Plex's poster; Undo puts the old ones back. Click a cover to see it large."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap
        }
        Text {
            Layout.leftMargin: 14
            visible: shown.count === 0 && !Store.coversBusy
            text: page.pending ? "Nothing waits for a decision." : !page.artist ? "Pick an artist (type to filter the list)."
                : Store.albums.length === 0 ? "No album folder with FLAC files under " + page.artist + "."
                : "Every cover of " + page.artist + " is fine (show all to see them)."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
        ListView {
            id: albumList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: shown
            enabled: !Store.coversBusy
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                id: row
                required property string json
                readonly property var e: JSON.parse(json)
                width: ListView.view.width - 28
                x: 14
                implicitHeight: rl.implicitHeight + 20
                radius: Ui.cardRadius
                color: Ui.raised
                border.width: 1; border.color: Ui.surface
                RowLayout {
                    id: rl
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                    spacing: 14
                    Thumb {
                        folder: row.e.folder; which: row.e.applied ? "previous" : "current"; stamp: row.e.checked || 0
                        label: row.e.applied ? "before" : row.e.current && row.e.current.w ? row.e.current.w + "×" + row.e.current.h + (row.e.current.framed ? " · scan frame" : " · clean") : row.e.verdict === "unchecked" && row.e.has_cover !== false ? "cover.jpg" : "no cover.jpg"
                    }
                    Text { visible: !!row.e.proposal; text: "󰁔"; color: Ui.overlay; font.family: Ui.iconFont; font.pixelSize: 26; Layout.alignment: Qt.AlignVCenter }
                    Thumb {
                        visible: !!row.e.proposal
                        folder: row.e.folder; which: row.e.applied ? "current" : "proposal"; stamp: (row.e.checked || 0) + (row.e.applied_at || 0)
                        label: row.e.proposal ? row.e.proposal.source.replace(/:.*/, "") + " · " + row.e.proposal.orig + (row.e.proposal.same ? " · same art " + row.e.proposal.same.toFixed(2) : "") : ""
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: 4
                        Text { Layout.fillWidth: true; text: row.e.folder; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; elide: Text.ElideRight }
                        Text { text: (row.e.queued ? "checking again · " : "") + (row.e.applied ? "replaced" + (row.e.applied_at ? " " + Store.when(row.e.applied_at) : "") : page.verdictText(row.e)); color: page.verdictColor(row.e); font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text {
                            Layout.fillWidth: true
                            text: (row.e.tried || []).filter(t => / \d+x\d+, /.test(t)).join("\n")
                            color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.Wrap
                        }
                        Item { implicitHeight: 4 }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            UiButton { visible: !!row.e.proposal && !row.e.applied; label: "Replace"; icon: "󰄬"; primary: true; small: true; tooltip: "cover.jpg, every track's embedded art and Plex's poster"; onClicked: Store.coverAct("apply", row.e.folder) }
                            UiButton { visible: !!row.e.proposal && !row.e.applied; label: "Keep mine"; small: true; onClicked: Store.coverAct("keep", row.e.folder) }
                            UiButton { visible: !!row.e.applied; label: "Undo"; icon: "󰕌"; small: true; danger: true; onClicked: Store.coverAct("undo", row.e.folder) }
                            UiButton { visible: !row.e.queued && row.e.verdict !== "queued"; label: row.e.verdict === "unchecked" ? "Check" : "Check again"; icon: "󰑐"; small: true; tooltip: "this album only"; onClicked: Store.checkCovers(row.e.folder) }
                        }

                        // every candidate: click makes it the proposal, right-click shows it large
                        Text {
                            visible: (row.e.alts || []).length > 0; Layout.topMargin: 6
                            text: "Candidates · click to propose, right-click to see large"
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            Repeater {
                                model: row.e.alts || []
                                Thumb {
                                    id: alt
                                    required property var modelData
                                    required property int index
                                    size: 76
                                    folder: row.e.folder; which: "alt:" + index; stamp: (row.e.checked || 0) + index + (modelData.kind === "claude" ? 0.5 : 0)
                                    marked: !!row.e.proposal && row.e.proposal.alt === index
                                    opacity: modelData.trusted === false ? 0.45 : 1
                                    onPicked: Store.pickCover(row.e.folder, index)
                                    Tip {
                                        text: alt.modelData.source + " · " + alt.modelData.orig + (alt.modelData.framed ? " · scan frame" : "") + (alt.modelData.same !== null && alt.modelData.same !== undefined ? " · same art " + alt.modelData.same.toFixed(2) : "") + (alt.modelData.trusted === false ? " · other artwork" : "")
                                        when: altHover.hovered
                                    }
                                    HoverHandler { id: altHover }
                                }
                            }
                        }

                        // none is right: tell Claude what is wrong
                        RowLayout {
                            Layout.fillWidth: true; Layout.topMargin: 4
                            spacing: 6
                            readonly property var ask: Store.asks[row.e.folder] || null
                            UiField {
                                id: complaint
                                Layout.fillWidth: true
                                enabled: !(parent.ask && parent.ask.running)
                                placeholderText: "None of these? Say what is wrong (e.g. keep the red frame of the LP, the colors are washed out, this is the reissue art…)"
                                onAccepted: if (text.trim()) Store.askCover(row.e.folder, text.trim())
                            }
                            UiButton {
                                label: parent.ask && parent.ask.running ? "Claude is working…" : "Ask Claude"; icon: "󰚩"; small: true
                                enabledBtn: complaint.text.trim() !== "" && !(parent.ask && parent.ask.running)
                                tooltip: "Claude looks at these images, adapts one or searches the web for another, and adds it here as the proposal (Replace is still yours)"
                                onClicked: Store.askCover(row.e.folder, complaint.text.trim())
                            }
                        }
                        Text {
                            readonly property var ask: Store.asks[row.e.folder] || null
                            visible: !!ask
                            Layout.fillWidth: true
                            text: ask ? ask.text : ""
                            color: ask && ask.bad ? Ui.red : ask && ask.running ? Ui.accent : Ui.text
                            font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }
    }

    // a check running: the list stays as it was under a veil, the cursor waits, the text says how far
    Rectangle {
        anchors.fill: parent
        visible: Store.coversBusy
        color: Qt.rgba(Ui.base.r, Ui.base.g, Ui.base.b, 0.72)
        MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.BusyCursor; onWheel: w => w.accepted = true }
        ColumnLayout {
            anchors.centerIn: parent
            spacing: 8
            width: Math.min(parent.width - 80, 520)
            Text {
                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                text: page.total ? Math.round(100 * (page.total - page.remaining) / page.total) + " %" : "…"
                color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 14; font.bold: true
            }
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 6; radius: 3; color: Ui.surface
                Rectangle { width: page.total ? parent.width * (page.total - page.remaining) / page.total : 0; height: parent.height; radius: 3; color: Ui.accent }
            }
            Text {
                Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                text: (page.total ? (page.total - page.remaining) + " of " + page.total + " albums checked · " : "") + "now: " + (Store.covers.running || "…")
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle
            }
        }
    }

    // a cover large, over the page (click to close)
    Rectangle {
        id: big
        anchors.fill: parent
        visible: false
        color: Qt.rgba(0, 0, 0, 0.75)
        function show(src) { bigImg.source = src; visible = true }
        Image { id: bigImg; anchors.centerIn: parent; width: Math.min(parent.width, parent.height) - 40; height: width; fillMode: Image.PreserveAspectFit; cache: false }
        MouseArea { anchors.fill: parent; onClicked: big.visible = false }
    }
}
