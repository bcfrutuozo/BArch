import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// one job of the pipeline: what it found, what it would write, and the inputs of
// `barch music resolve` (release, cover, date, genre, names, titles, replace...) as a form.
// Created anew for every job (JobsPage), so the form starts empty each time.
Item {
    id: detail
    property string jobId: ""
    readonly property var job: Store.job && Store.job.id === jobId ? Store.job : null
    readonly property string st: job ? job.state : ""
    readonly property bool decidable: st === "review" || st === "failed" || st === "rejected" || st === "done"

    // the form, kept here so the 8 s refresh of the job never wipes what was typed
    property var tracks: []               // [{ key: "1.03", file, title }] from the proposal, set once
    property var titles: ({})             // key -> typed title
    property var replaceTracks: ({})      // key -> true
    property bool seeded: false

    function seed() {
        if (seeded || !job) return
        seeded = true
        const h = job.hints || {}
        mbArtist.text = h.artist || ""
        mbAlbum.text = h.album || ""
        tracks = ((job.proposal || {}).tracks || []).map(t => {
            const m = /^(\d+\.\d+)/.exec(t.file || "")
            return { key: m ? m[1] : "", file: t.file, title: t.TITLE || "" }
        }).filter(t => t.key)
    }
    onJobChanged: seed()
    Component.onCompleted: seed()

    // "--replace-tracks 1.07,1.08" in a merge review line or in a problem (a new album whose tracks
    // do not fit MusicBrainz's lengths): the keys it names
    function replaceKeys(line) { const m = /--replace-tracks (\S+)/.exec(line || ""); return m ? m[1].split(",") : [] }
    function suggestedReplace() {
        const out = []
        const j = job || {}
        for (const r of (j.problems || []).concat((j.merge || {}).review || [])) for (const k of replaceKeys(r)) if (!out.includes(k)) out.push(k)
        return out
    }
    function setReplaceAll(keys, on) { const t = Object.assign({}, replaceTracks); for (const k of keys) { if (on) t[k] = true; else delete t[k] } replaceTracks = t }
    function setTitle(k, v) { const t = Object.assign({}, titles); if (v.trim()) t[k] = v; else delete t[k]; titles = t }
    function setReplace(k, on) { const t = Object.assign({}, replaceTracks); if (on) t[k] = true; else delete t[k]; replaceTracks = t }

    // what Resolve sends: only what was filled in
    readonly property var body: {
        const b = {}, ov = {}
        if (fRelease.text.trim()) b.release = fRelease.text.trim()
        if (fCover.text.trim()) b.cover = fCover.text.trim()
        if (fDate.text.trim()) ov.date = fDate.text.trim()
        if (fGenre.text.trim()) ov.genre = fGenre.text.trim()
        if (fAlbum.text.trim()) ov.album = fAlbum.text.trim()
        if (fArtist.text.trim()) ov.artist_folder = fArtist.text.trim()
        if (swYear.checked) ov.date_year_only = true
        const tk = {}
        for (const k in titles) tk[k] = { TITLE: titles[k] }
        if (Object.keys(tk).length) ov.tracks = tk
        if (Object.keys(ov).length) b.overrides = ov
        if (swKeep.checked) b.keep_order = true
        if (swReplace.checked) b.replace = true
        const rt = Object.keys(replaceTracks).sort()
        if (rt.length) b.replace_tracks = rt
        return b
    }
    readonly property string cli: {
        const q = s => /^[\w.:\/-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'"
        const a = ["barch music resolve", jobId], b = body, ov = b.overrides || {}
        if (b.release) a.push("--release", q(b.release))
        if (b.cover) a.push("--cover", q(b.cover))
        if (ov.date) a.push("--date", q(ov.date))
        if (ov.genre) a.push("--genre", q(ov.genre))
        if (ov.album) a.push("--album", q(ov.album))
        if (ov.artist_folder) a.push("--artist", q(ov.artist_folder))
        for (const k in (ov.tracks || {})) a.push("--title", q(k + "=" + ov.tracks[k].TITLE))
        if (ov.date_year_only) a.push("--date-year-only")
        if (b.keep_order) a.push("--keep-order")
        if (b.replace) a.push("--replace")
        if (b.replace_tracks) a.push("--replace-tracks", b.replace_tracks.join(","))
        return a.join(" ")
    }

    component Label: Text { color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
    component Line: Text { Layout.fillWidth: true; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap }
    component Mono: Text { Layout.fillWidth: true; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WrapAnywhere }
    // the header is selectable (drag to select, Ctrl+C), so a name can go straight into a search
    component Sel: TextEdit {
        Layout.fillWidth: true
        readOnly: true; selectByMouse: true; persistentSelection: false
        color: Ui.text; selectionColor: Ui.accent; selectedTextColor: Ui.crust
        font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: TextEdit.Wrap
    }

    Text {
        anchors.centerIn: parent
        visible: !detail.job
        text: "loading " + detail.jobId + "…"
        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
    }

    ScrollView {
        anchors.fill: parent
        visible: !!detail.job
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: parent.width
            spacing: 12

            Item { implicitHeight: 2 }

            // ---------- header ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                RowLayout {
                    spacing: 14
                    Rectangle {
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: 120; implicitHeight: 120
                        radius: Ui.radius
                        color: Ui.sunken
                        clip: true
                        Image {
                            id: coverImg
                            anchors.fill: parent
                            source: Store.coverFile
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true; cache: false
                            sourceSize: Qt.size(240, 240)
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: coverImg.status !== Image.Ready
                            text: "󰝚"; color: Ui.overlay; font.family: Ui.iconFont; font.pixelSize: 40
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        RowLayout {
                            spacing: 8
                            Badge { text: detail.st; tint: Store.stateColor(detail.st) }
                            Badge { text: detail.job ? detail.job.kind : ""; tint: Ui.overlay }
                            Sel { Layout.fillWidth: false; text: detail.job ? detail.jobId + " · " + Store.when(detail.job.updated) : ""; color: Ui.subtext }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Sel { id: nameText; text: detail.job ? detail.job.name : ""; font.pixelSize: Ui.fontSize + 3; font.bold: true }
                            UiButton {
                                Layout.alignment: Qt.AlignTop
                                icon: "󰆏"; small: true; tooltip: "copy the download's name (to search it)"
                                onClicked: { Store.copy(nameText.text); Store.say("copied: " + nameText.text) }
                            }
                        }
                        Sel { text: detail.job ? detail.job.source || "" : ""; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; wrapMode: TextEdit.WrapAnywhere }
                        Sel {
                            readonly property var a: detail.job ? detail.job.audio || {} : {}
                            visible: a.tracks !== undefined
                            text: a.tracks + " track" + (a.tracks === 1 ? "" : "s") + (a.discs > 1 ? " on " + a.discs + " discs" : "") + "  ·  " + (a.format || []).join(", ")
                        }
                        Sel {
                            readonly property var r: detail.job ? detail.job.result || detail.job.proposal || null : null
                            visible: !!(r && r.folder)
                            text: (detail.st === "done" ? "in the library: " : "would go to: ") + (r ? r.folder : "")
                            color: detail.st === "done" ? Ui.green : Ui.text
                        }
                        Item { implicitHeight: 4 }
                        Flow {
                            Layout.fillWidth: true
                            spacing: 6
                            UiButton { label: "Retry"; icon: "󰑐"; small: true; visible: detail.st !== "working" && detail.st !== "queued"; tooltip: "run it again as it is"; onClicked: Store.act(detail.jobId, "retry") }
                            UiButton { label: "Reject"; icon: "󰅖"; small: true; danger: true; visible: detail.st === "review" || detail.st === "failed"; tooltip: "give up on this download (nothing is deleted)"; onClicked: Store.act(detail.jobId, "reject") }
                            UiButton { label: "Undo"; icon: "󰕌"; small: true; danger: true; visible: detail.st === "done"; tooltip: "put back what it changed in /music (removes a new album, restores a merged or replaced one)"; onClicked: Store.act(detail.jobId, "undo") }
                            UiButton { label: "MusicBrainz"; icon: "󰌹"; small: true; visible: !!(detail.job && detail.job.match); onClicked: Store.openUrl(detail.job.match.url) }
                        }
                    }
                }
            }

            // ---------- what is wrong ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                visible: detail.job && ((detail.job.problems || []).length > 0 || ((detail.job.merge || {}).review || []).length > 0)
                title: "Needs a decision"
                Repeater {
                    model: detail.job ? detail.job.problems || [] : []
                    RowLayout {
                        id: pr
                        required property var modelData
                        readonly property var keys: detail.replaceKeys(modelData)
                        spacing: 8
                        Text { text: "󰀦"; color: Ui.red; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize; Layout.alignment: Qt.AlignTop }
                        Line { text: pr.modelData.replace(/ --replace-tracks \S+/, " --replace-tracks") }
                        UiSwitch { visible: pr.keys.length > 0; implicitWidth: 32; implicitHeight: 18; checked: pr.keys.every(k => !!detail.replaceTracks[k]); onToggled: v => detail.setReplaceAll(pr.keys, v) }
                        Label { visible: pr.keys.length > 0; text: "accept" }
                    }
                }
                Repeater {
                    model: detail.job ? (detail.job.merge || {}).review || [] : []
                    RowLayout {
                        id: rv
                        required property var modelData
                        readonly property string key: (/--replace-tracks (\S+)/.exec(modelData) || [])[1] || ""
                        spacing: 8
                        Text { text: "󰀪"; color: Ui.yellow; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize; Layout.alignment: Qt.AlignTop }
                        Line { text: rv.modelData.replace(/: replace it with --replace-tracks \S+/, "") }
                        UiSwitch { visible: rv.key !== ""; implicitWidth: 32; implicitHeight: 18; checked: !!detail.replaceTracks[rv.key]; onToggled: v => detail.setReplace(rv.key, v) }
                        Label { visible: rv.key !== ""; text: "replace" }
                    }
                }
                UiButton {
                    visible: detail.suggestedReplace().length > 1
                    label: "Replace all " + detail.suggestedReplace().length + " suggested tracks"; small: true
                    onClicked: { const t = {}; for (const k of detail.suggestedReplace()) t[k] = true; detail.replaceTracks = t }
                }
            }

            // ---------- candidates ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                visible: detail.job && (detail.job.candidates || []).length > 0
                title: "MusicBrainz candidates"
                subtitle: "✓ = lengths and titles fit. Use one to pick that release."
                Repeater {
                    model: detail.job ? detail.job.candidates || [] : []
                    Rectangle {
                        id: cand
                        required property var modelData
                        readonly property bool chosen: fRelease.text.indexOf(modelData.mbid) !== -1
                        readonly property bool matched: !!(detail.job && detail.job.match && detail.job.match.mbid === modelData.mbid)
                        Layout.fillWidth: true
                        implicitHeight: cc.implicitHeight + 12
                        radius: Ui.radius
                        color: chosen ? Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.15) : Ui.sunken
                        border.width: matched ? 1 : 0
                        border.color: Ui.green
                        RowLayout {
                            id: cc
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 8 }
                            spacing: 10
                            Text { text: cand.modelData.ok ? "󰄬" : "󰅖"; color: cand.modelData.ok ? Ui.green : Ui.red; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Line { text: cand.modelData.artist + " – " + cand.modelData.title + (cand.modelData.reordered ? "  (other track order)" : ""); font.bold: true }
                                Label { text: [cand.modelData.date, cand.modelData.country, cand.modelData.tracks + " tracks", "score " + cand.modelData.score].filter(x => x).join("  ·  ") }
                                Label { Layout.fillWidth: true; text: (cand.modelData.why || []).join("; "); wrapMode: Text.Wrap; color: Ui.overlay }
                            }
                            UiButton { icon: "󰌹"; small: true; tooltip: "open in MusicBrainz"; onClicked: Store.openUrl(cand.modelData.url) }
                            UiButton { label: cand.chosen ? "Chosen" : "Use"; small: true; primary: cand.chosen; onClicked: fRelease.text = cand.chosen ? "" : cand.modelData.mbid }
                        }
                    }
                }
            }

            // ---------- search by hand ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Search MusicBrainz"
                subtitle: "When the right edition is not among the candidates (or there are none)."
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    UiField { id: mbArtist; Layout.preferredWidth: 220; placeholderText: "artist"; onAccepted: Store.mbSearch(mbArtist.text, mbAlbum.text) }
                    UiField { id: mbAlbum; Layout.fillWidth: true; placeholderText: "album"; onAccepted: Store.mbSearch(mbArtist.text, mbAlbum.text) }
                    UiButton { label: Store.mbBusy ? "Searching…" : "Search"; icon: "󰍉"; enabledBtn: !Store.mbBusy; onClicked: Store.mbSearch(mbArtist.text, mbAlbum.text) }
                }
                Repeater {
                    model: Store.mbResults
                    Rectangle {
                        id: res
                        required property var modelData
                        readonly property bool chosen: fRelease.text.indexOf(modelData.mbid) !== -1
                        readonly property bool sameCount: detail.job && detail.job.audio && detail.job.audio.tracks === modelData.tracks
                        Layout.fillWidth: true
                        implicitHeight: rc.implicitHeight + 10
                        radius: Ui.radius
                        color: chosen ? Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.15) : Ui.sunken
                        RowLayout {
                            id: rc
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 10; rightMargin: 8 }
                            spacing: 10
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Line { text: res.modelData.artist + " – " + res.modelData.title + (res.modelData.disambiguation ? "  (" + res.modelData.disambiguation + ")" : "") }
                                Label {
                                    text: [res.modelData.date, res.modelData.country, res.modelData.formats, res.modelData.group, res.modelData.status].filter(x => x).join("  ·  ")
                                }
                            }
                            Badge { text: res.modelData.tracks + " tracks"; tint: res.sameCount ? Ui.green : Ui.overlay; tip: res.sameCount ? "same number of tracks as the download" : "the download has " + (detail.job && detail.job.audio ? detail.job.audio.tracks : "?") }
                            UiButton { icon: "󰌹"; small: true; tooltip: "open in MusicBrainz"; onClicked: Store.openUrl(res.modelData.url) }
                            UiButton { label: res.chosen ? "Chosen" : "Use"; small: true; primary: res.chosen; onClicked: fRelease.text = res.chosen ? "" : res.modelData.mbid }
                        }
                    }
                }
            }

            // ---------- the decision ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Decide"
                subtitle: "Fill in only what should change; empty fields keep what the pipeline found. Resolve queues the album again with these."
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 10; rowSpacing: 6
                    Label { text: "Release" }
                    UiField { id: fRelease; Layout.fillWidth: true; mono: true; placeholderText: detail.job && detail.job.chosen ? detail.job.chosen : "MusicBrainz release id or URL (Use above fills it)" }
                    Label { text: "Date" }
                    RowLayout {
                        spacing: 10
                        UiField {
                            id: fDate; Layout.preferredWidth: 160; mono: true
                            placeholderText: ((detail.job || {}).overrides || {}).date || ((detail.job || {}).proposal || {}).date || "YYYY-MM-DD"
                            bad: text.trim() !== "" && !/^\d{4}-\d{2}-\d{2}$/.test(text.trim())
                        }
                        UiSwitch { id: swYear; implicitWidth: 32; implicitHeight: 18; onToggled: v => checked = v }
                        Label { Layout.fillWidth: true; text: "no day exists anywhere: write YYYY-01-01 (last resort)"; wrapMode: Text.Wrap }
                    }
                    Label { text: "Genre" }
                    UiField { id: fGenre; Layout.fillWidth: true; placeholderText: ((detail.job || {}).proposal || {}).genre || "e.g. Hard Rock" }
                    Label { text: "Album" }
                    UiField { id: fAlbum; Layout.fillWidth: true; placeholderText: ((detail.job || {}).proposal || {}).album || "album title as it should be tagged" }
                    Label { text: "Artist folder" }
                    UiField { id: fArtist; Layout.fillWidth: true; placeholderText: ((detail.job || {}).proposal || {}).artist_folder || "folder under /music" }
                    Label { text: "Cover" }
                    RowLayout {
                        spacing: 8
                        UiField {
                            id: fCover; Layout.fillWidth: true; mono: true
                            placeholderText: detail.job && detail.job.cover ? "chosen: " + (detail.job.cover_label || detail.job.cover) : "image URL (square, ≥ 500 px, 1000 preferred)"
                        }
                        UiButton {
                            label: "Upload…"; icon: "󰕒"; small: true
                            tooltip: "an image from this machine (square, ≥ 500 px): checked and kept with the job; Resolve runs the album with it"
                            onClicked: Store.pickJobCover(detail.jobId)
                        }
                        UiButton { visible: !!(detail.job && detail.job.cover); label: "Clear"; small: true; tooltip: "forget the chosen cover"; onClicked: Store.clearJobCover(detail.jobId) }
                    }
                }
                RowLayout {
                    spacing: 10
                    UiSwitch { id: swKeep; implicitWidth: 32; implicitHeight: 18; onToggled: v => checked = v }
                    Label { text: "keep the download's track order (LP / other edition)" }
                }
                RowLayout {
                    spacing: 10
                    UiSwitch { id: swReplace; implicitWidth: 32; implicitHeight: 18; onToggled: v => checked = v }
                    Label { text: "replace the album in the library (a backup is kept for Undo)"; color: swReplace.checked ? Ui.red : Ui.subtext }
                }

                // titles, track by track
                Text {
                    visible: detail.tracks.length > 0
                    text: "Tracks  ·  type a title to override it; tick to replace the library's file with the download's (or accept one that does not fit MusicBrainz's length)"
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; Layout.topMargin: 6
                }
                Repeater {
                    model: detail.tracks
                    RowLayout {
                        id: tr
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: tr.modelData.key; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; Layout.preferredWidth: 38 }
                        UiField {
                            Layout.fillWidth: true
                            implicitHeight: 26
                            placeholderText: tr.modelData.title
                            text: detail.titles[tr.modelData.key] || ""
                            onTextChanged: if (text !== (detail.titles[tr.modelData.key] || "")) detail.setTitle(tr.modelData.key, text)
                        }
                        UiSwitch {
                            visible: !!(detail.job && detail.job.merge) || detail.suggestedReplace().includes(tr.modelData.key)
                            implicitWidth: 32; implicitHeight: 18
                            checked: !!detail.replaceTracks[tr.modelData.key]
                            onToggled: v => detail.setReplace(tr.modelData.key, v)
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; Layout.topMargin: 6
                    implicitHeight: cliText.implicitHeight + 12
                    radius: Ui.radius; color: Ui.sunken
                    Text {
                        id: cliText
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 8 }
                        text: detail.cli; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WrapAnywhere
                    }
                }
                // the agent: a hint for it, Find cover when only the cover is missing (the music-cover rule does
                // that by itself), Fix with Agent next to Resolve for anything
                RowLayout {
                    Layout.fillWidth: true
                    visible: detail.st === "review" || detail.st === "failed"
                    spacing: 6
                    readonly property var ask: Store.asks[detail.jobId] || null
                    UiField {
                        id: coverHint
                        Layout.fillWidth: true
                        enabled: !(parent.ask && parent.ask.running)
                        placeholderText: "Hint for the agent (optional): the edition, what the download really is, where a date or cover exists, what to avoid"
                    }
                    UiButton {
                        visible: ((detail.job && detail.job.problems) || []).some(x => /^no cover/.test(x))
                        label: parent.ask && parent.ask.running ? "Claude is searching…" : "Find cover"; icon: "󰚩"; small: true
                        enabledBtn: !(parent.ask && parent.ask.running)
                        tooltip: "Claude searches the web for the front cover, checks it (square, ≥ 500 px) and runs the album with it; Undo brings it back if it is wrong"
                        onClicked: Store.askJobCover(detail.jobId, coverHint.text.trim())
                    }
                }
                Text {
                    readonly property var ask: Store.asks[detail.jobId] || null
                    visible: !!ask
                    Layout.fillWidth: true
                    text: ask ? ask.text : ""
                    color: ask && ask.bad ? Ui.red : ask && ask.running ? Ui.accent : Ui.text
                    font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                }
                RowLayout {
                    spacing: 8
                    UiButton {
                        label: "Resolve"; icon: "󰄬"; primary: true
                        enabledBtn: detail.decidable && !fDate.bad && (Object.keys(detail.body).length > 0)
                        tooltip: Object.keys(detail.body).length ? "queue it again with these answers" : "fill something in first (or use Retry)"
                        onClicked: Store.act(detail.jobId, "resolve", detail.body)
                    }
                    UiButton {
                        readonly property var ask: Store.asks[detail.jobId] || null
                        visible: detail.st === "review" || detail.st === "failed"
                        label: ask && ask.running ? "Agent is working…" : "Fix with Agent"; icon: "󰚩"
                        enabledBtn: !(ask && ask.running)
                        tooltip: "Claude takes the album over: finds the release, the date, the genre, the cover, settles the merge, resolves it and follows the run until it is in the library (or tells you the one decision left). Undo brings it back."
                        onClicked: Store.fixJob(detail.jobId, coverHint.text.trim())
                    }
                    UiButton {
                        label: "Clear"; small: true
                        onClicked: { for (const f of [fRelease, fDate, fGenre, fAlbum, fArtist, fCover]) f.text = ""; swYear.checked = swKeep.checked = swReplace.checked = false; detail.titles = {}; detail.replaceTracks = {} }
                    }
                }
            }

            // ---------- what it would write ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                visible: !!(detail.job && detail.job.merge)
                id: mergeCard
                title: "Merge into the library"
                subtitle: "The album is already in /music: only these changes (Bruno's tags win)."
                readonly property var m: detail.job ? detail.job.merge || {} : {}
                Repeater {
                    model: mergeCard.m.add || []
                    Mono { required property var modelData; text: "+ " + modelData; color: Ui.green }
                }
                Repeater {
                    model: mergeCard.m.fix || []
                    Mono {
                        required property var modelData
                        text: "~ " + modelData.file + (modelData.rename ? " → " + modelData.rename : "")
                              + (Object.keys(modelData.set || {}).length ? "   " + Object.keys(modelData.set).map(k => k + "=" + modelData.set[k]).join(", ") : "")
                              + ((modelData.drop || []).length ? "   −" + modelData.drop.join(" −") : "") + (modelData.cover ? "   +cover" : "")
                    }
                }
            }
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                id: propCard
                readonly property var p: detail.job ? detail.job.proposal || null : null
                visible: !!p
                title: "Proposal"
                subtitle: p ? p.folder + "  ·  " + (p.date || "no date") + "  ·  " + (p.genre || "no genre") : ""
                Repeater {
                    model: propCard.p ? propCard.p.tracks || [] : []
                    Mono { required property var modelData; text: modelData.file; color: Ui.subtext }
                }
            }

            // ---------- notes and log ----------
            Card {
                Layout.leftMargin: 14; Layout.rightMargin: 14
                title: "Log"
                Repeater {
                    model: detail.job ? detail.job.notes || [] : []
                    Line { required property var modelData; text: "• " + modelData; color: Ui.subtext }
                }
                Repeater {
                    model: detail.job ? (detail.job.cover_tried || []) : []
                    Line { required property var modelData; text: "cover · " + modelData; color: Ui.overlay }
                }
                Mono { text: detail.job ? (detail.job.log || []).slice(-40).join("\n") : ""; color: Ui.subtext }
            }

            Item { implicitHeight: 8 }
        }
    }
}
