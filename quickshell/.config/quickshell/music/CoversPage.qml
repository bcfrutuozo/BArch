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
    readonly property var list: !artist ? [] : Store.covers.entries.filter(e => e.folder.indexOf(artist + "/") === 0
        && (all || e.verdict === "better" || e.verdict === "framed" || e.applied || e.queued || e.verdict === "queued"))
    Component.onCompleted: if (!Store.artists.length) Store.loadArtists()

    function verdictText(e) {
        return e.verdict === "better" ? "a cleaner cover exists" : e.verdict === "framed" ? "a scan, nothing cleaner found"
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
        function load() { th.src = ""; if (folder) Store.coverImage(folder, which, stamp, p => th.src = p) }
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
                onTextChanged: page.filterText = text
                onAccepted: if (page.artist) Store.checkCovers(page.artist)
            }
            UiCombo {
                id: artistCombo; Layout.preferredWidth: 300
                entries: page.filtered.map(a => ({ label: a.name + "  (" + a.albums + ")", value: a.name }))
                value: page.artist
                onPicked: v => Store.coversArtist = String(v)
            }
            UiButton {
                label: "Check"; icon: "󰍉"; primary: true; enabledBtn: page.artist !== "" && !Store.covers.entries.some(e => e.folder.indexOf(page.artist + "/") === 0 && e.queued)
                tooltip: "look at every album of this artist: a scan with a frame, and the clean artwork of the same album in the stores and the archive (a few seconds per album)"
                onClicked: Store.checkCovers(page.artist)
            }
            UiButton { icon: "󰑐"; small: true; tooltip: "reload the list of artists"; onClicked: Store.loadArtists() }
            Item { Layout.fillWidth: true }
            Text {
                visible: Store.covers.running !== ""
                text: "checking " + Store.covers.running + (Store.covers.queued ? "  (+" + Store.covers.queued + ")" : "")
                color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle; Layout.maximumWidth: 380
            }
            UiSwitch { implicitWidth: 32; implicitHeight: 18; checked: page.all; onToggled: v => page.all = v }
            Text { text: "show all"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
        }
        Text {
            Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.fillWidth: true
            text: "A scan of an old sleeve usually brings a frame (the scanner bed, the cardboard edge). The check looks for the label's clean artwork of the same album (iTunes, Deezer, Cover Art Archive), confirmed by comparing the pictures. Replace writes cover.jpg, the picture embedded in every track and Plex's poster; Undo puts the old ones back. Click a cover to see it large."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.Wrap
        }
        Text {
            Layout.leftMargin: 14
            visible: page.list.length === 0
            text: !page.artist ? "Pick an artist (type to filter the list) and press Check."
                : Store.covers.entries.some(e => e.folder.indexOf(page.artist + "/") === 0)
                    ? "Every checked cover of " + page.artist + " is fine (show all to see them)."
                    : page.artist + " was not checked yet: press Check."
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: page.list
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property var e: modelData
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
                        label: row.e.applied ? "before" : row.e.current && row.e.current.w ? row.e.current.w + "×" + row.e.current.h + (row.e.current.framed ? " · scan frame" : " · clean") : "no cover.jpg"
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
                            UiButton { visible: !row.e.queued && row.e.verdict !== "queued"; label: "Check again"; icon: "󰑐"; small: true; onClicked: Store.checkCovers(row.e.folder.split("/")[0]) }
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
