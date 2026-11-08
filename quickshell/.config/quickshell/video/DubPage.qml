import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The PT-BR pipeline's jobs (server/video): one per movie (m<id>) and per season (s<series>x<season>).
// A job searches a release with the Brazilian dub, downloads it, aligns its audio to the file and muxes
// the PT-BR track (and subtitles) in. On the right: the candidates it found (Use one), the alignment,
// the episodes of a season and the history; Retry / Skip / Unskip; a Prowlarr search with your own
// query or a release by URL; Fix with Agent (barch video fix) hands the job to Claude.
Item {
    id: page
    property string filter: "all"
    Component.onCompleted: Store.loadDubs()

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            readonly property bool split: Store.dub !== null
            Layout.fillWidth: !split
            Layout.preferredWidth: split ? 340 : -1
            Layout.fillHeight: true
            Layout.margins: 16; Layout.topMargin: 8
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                UiCombo {
                    entries: [{ label: "All", value: "all" }, { label: "Review", value: "review" }, { label: "Waiting", value: "waiting" }, { label: "Downloading", value: "downloading" },
                              { label: "Aligning", value: "aligning" }, { label: "Searching", value: "search" }, { label: "Done", value: "done" }, { label: "Skipped", value: "skipped" }]
                    value: page.filter
                    onPicked: v => page.filter = v
                }
                Text {
                    Layout.fillWidth: true
                    text: Object.entries((Store.status.pipeline || {}).counts || {}).filter(e => e[1] > 0).map(e => e[1] + " " + e[0]).join(" · ") || "no jobs yet"
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight
                }
                UiButton { label: "Reload"; icon: "󰑓"; small: true; onClicked: Store.loadDubs() }
            }
            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 6
                model: Store.dubs.filter(j => page.filter === "all" || j.state === page.filter)
                         .sort((a, b) => (a.state === "review" ? 0 : a.state === "done" ? 2 : 1) - (b.state === "review" ? 0 : b.state === "done" ? 2 : 1) || b.updated - a.updated)
                ScrollBar.vertical: ScrollBar {}
                Text {
                    anchors.centerIn: parent
                    visible: list.count === 0
                    text: "No jobs here."
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
                }
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool current: Store.dub && Store.dub.id === modelData.id
                    width: list.width
                    implicitHeight: col.implicitHeight + 16
                    radius: Ui.cardRadius
                    color: current ? Ui.surface : (rm.containsMouse ? Ui.faint : Ui.raised)
                    ColumnLayout {
                        id: col
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                        spacing: 3
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Text { text: row.modelData.kind === "season" ? "󰟞" : "󰎁"; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                            Text { Layout.fillWidth: true; text: row.modelData.title + (row.modelData.year ? " (" + row.modelData.year + ")" : ""); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight }
                            Badge { visible: row.modelData.episodes !== null; text: row.modelData.episodes ? (row.modelData.episodes - row.modelData.episodes_todo) + "/" + row.modelData.episodes + " ep" : ""; tint: Ui.subtext }
                            Badge { text: row.modelData.state; tint: Store.dubTint(row.modelData.state) }
                        }
                        Text {
                            visible: text !== ""
                            Layout.fillWidth: true
                            text: row.modelData.donor ? "← " + row.modelData.donor + (row.modelData.progress ? " · " + Math.floor(row.modelData.progress * 100) + " %" : "") : ""
                            color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle
                        }
                        Text {
                            visible: !!row.modelData.reason
                            Layout.fillWidth: true
                            text: row.modelData.reason || ""
                            color: row.modelData.state === "review" ? Ui.yellow : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap
                        }
                    }
                    MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.openDub(row.modelData.id) }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface; visible: Store.dub !== null }
        Rectangle {
            id: det
            Layout.fillHeight: true
            Layout.fillWidth: true
            Layout.minimumWidth: 380
            visible: Store.dub !== null
            color: Ui.base
            readonly property var j: Store.dub
            function pad(n) { n = parseInt(n); return n < 10 ? "0" + n : "" + n }
            function when(t) { const d = new Date(t * 1000); return d.toLocaleDateString(Qt.locale(), "dd/MM") + " " + d.toLocaleTimeString(Qt.locale(), "HH:mm") }

            Flickable {
                anchors.fill: parent
                anchors.margins: 14
                contentHeight: dc.implicitHeight
                clip: true
                ScrollBar.vertical: ScrollBar {}
                ColumnLayout {
                    id: dc
                    width: parent.width
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: det.j ? det.j.title + (det.j.year ? " (" + det.j.year + ")" : "") : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true; wrapMode: Text.WordWrap }
                        Badge { text: det.j ? det.j.state : ""; tint: Store.dubTint(det.j ? det.j.state : "") }
                    }
                    Text { Layout.fillWidth: true; text: det.j ? "original: " + (det.j.original || "?") + " · audio now: " + (det.j.audio || []).join(", ") : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap }
                    Text { visible: !!det.j && !!det.j.file; Layout.fillWidth: true; text: det.j ? det.j.file || "" : ""; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WrapAnywhere }
                    Text { visible: !!det.j && !!det.j.reason; Layout.fillWidth: true; text: det.j ? det.j.reason || "" : ""; color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap }
                    RowLayout {
                        spacing: 6
                        UiButton { label: "Retry"; icon: "󰑓"; tooltip: "search again from scratch"; onClicked: Store.dubAct(det.j.id, "retry") }
                        UiButton { visible: !!det.j && det.j.state !== "skipped"; label: "Skip"; icon: "󰒭"; tooltip: "leave it alone (no dub for this one)"; onClicked: Store.dubAct(det.j.id, "skip") }
                        UiButton { visible: !!det.j && det.j.state === "skipped"; label: "Unskip"; icon: "󰐕"; onClicked: Store.dubAct(det.j.id, "unskip") }
                        Item { Layout.fillWidth: true }
                        UiButton { small: true; label: "Close"; icon: "󰅖"; onClicked: Store.dub = null }
                    }
                    // the agent, and the two things it does that you can do by hand too: a search with your own
                    // query (the Brazilian title, "3ª Temporada", a group) and a release by its magnet/URL
                    Card {
                        visible: !!det.j && det.j.state !== "done"
                        title: "Find the dub"
                        subtitle: "a Prowlarr search with your words (what fits joins the candidates), a release by URL, or the agent"
                        readonly property var ask: det.j ? (Store.asks[det.j.id] || null) : null
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            UiField { id: fQuery; Layout.fillWidth: true; placeholderText: "search: Uma Família da Pesada 3ª Temporada Dublado"; onAccepted: Store.dubSearch(det.j.id, text) }
                            UiButton { small: true; label: "Search"; icon: "󰍉"; enabledBtn: fQuery.text.trim() !== ""; onClicked: Store.dubSearch(det.j.id, fQuery.text) }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            UiField { id: fUrl; Layout.fillWidth: true; placeholderText: "magnet: or torrent URL of a dubbed release (tried next)" }
                            UiField { id: fTitle; Layout.preferredWidth: 180; placeholderText: "its name (optional)" }
                            UiButton { small: true; label: "Add"; icon: "󰐕"; enabledBtn: fUrl.text.trim() !== ""; onClicked: { Store.dubAdd(det.j.id, fUrl.text, fTitle.text); fUrl.text = ""; fTitle.text = "" } }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            UiField { id: fHint; Layout.fillWidth: true; enabled: !(parent.parent.ask && parent.parent.ask.running); placeholderText: "Hint for the agent (optional): the Brazilian title, the edition the file is, where the dub exists" }
                            UiButton {
                                label: parent.parent.ask && parent.parent.ask.running ? "Agent is working…" : "Fix with Agent"; icon: "󰚩"; primary: true
                                enabledBtn: !(parent.parent.ask && parent.parent.ask.running)
                                tooltip: "Claude finds out the Brazilian title and the editions, searches the indexers with better queries, queues the right donor and reports; the pipeline downloads and muxes afterwards"
                                onClicked: Store.fixJob(det.j.id, fHint.text.trim())
                            }
                        }
                        Text {
                            visible: !!parent.ask
                            Layout.fillWidth: true
                            text: parent.ask ? parent.ask.text : ""
                            color: parent.ask && parent.ask.bad ? Ui.red : parent.ask && parent.ask.running ? Ui.accent : Ui.text
                            font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap
                        }
                    }
                    Card {
                        visible: !!det.j && !!det.j.last_search
                        title: "Last search by hand"
                        subtitle: det.j && det.j.last_search ? "“" + det.j.last_search.query + "”: " + det.j.last_search.found.length + " joined the candidates, " + det.j.last_search.rejected.length + " rejected" : ""
                        Repeater {
                            model: det.j && det.j.last_search ? det.j.last_search.rejected.slice(0, 12) : []
                            RowLayout {
                                id: rj
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 6
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text { Layout.fillWidth: true; text: rj.modelData.title; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideMiddle }
                                    Text { text: rj.modelData.why + " · " + Store.gb((rj.modelData.size || 0) / 1073741824) + (rj.modelData.seeders !== null && rj.modelData.seeders !== undefined ? " · " + rj.modelData.seeders + " seeds" : "") + " · " + (rj.modelData.indexer || ""); color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                                }
                                UiButton { small: true; label: "Add anyway"; enabledBtn: !!rj.modelData.url; tooltip: "it is this title and season, dubbed: try it next"; onClicked: Store.dubAdd(det.j.id, rj.modelData.url, rj.modelData.title) }
                            }
                        }
                    }
                    Card {
                        visible: !!det.j && !!det.j.alignment
                        title: "Alignment"
                        subtitle: det.j && det.j.alignment ? (det.j.alignment.ok ? "offset " + det.j.alignment.offset_ms + " ms · speed " + det.j.alignment.speed + " · " + det.j.alignment.agreeing + "/" + det.j.alignment.windows + " windows agree" : det.j.alignment.reason) : ""
                    }
                    Card {
                        visible: !!det.j && !!det.j.episodes && Object.keys(det.j.episodes).length > 0
                        title: "Episodes"
                        Repeater {
                            model: det.j && det.j.episodes ? Object.keys(det.j.episodes).sort((a, b) => a - b) : []
                            RowLayout {
                                required property var modelData
                                readonly property var e: det.j.episodes[modelData]
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: "E" + det.pad(modelData); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                                Badge { text: e.state; tint: Store.dubTint(e.state) }
                                Text { visible: e.offset_ms !== undefined && e.offset_ms !== null; text: e.offset_ms + " ms"; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                                Text { Layout.fillWidth: true; text: e.reason || ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight }
                            }
                        }
                    }
                    Card {
                        visible: !!det.j && (det.j.candidates || []).length > 0
                        title: "Candidates"
                        subtitle: "releases with a PT-BR dub it found; Use tries that one next"
                        Repeater {
                            model: det.j ? (det.j.candidates || []).slice().sort((a, b) => (b.score || 0) - (a.score || 0)) : []
                            Rectangle {
                                id: cand
                                required property var modelData
                                readonly property bool isDonor: det.j && det.j.donor === modelData.guid
                                Layout.fillWidth: true
                                implicitHeight: cc.implicitHeight + 10
                                radius: Ui.radius
                                color: isDonor ? Qt.rgba(Ui.accent.r, Ui.accent.g, Ui.accent.b, 0.1) : Ui.sunken
                                RowLayout {
                                    anchors.fill: parent; anchors.margins: 5
                                    spacing: 8
                                    ColumnLayout {
                                        id: cc
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text { Layout.fillWidth: true; text: cand.modelData.title; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WrapAnywhere }
                                        RowLayout {
                                            spacing: 4
                                            Badge { visible: !!cand.modelData.status; text: cand.modelData.status || ""; tint: cand.modelData.status === "failed" ? Ui.red : cand.isDonor ? Ui.accent : Ui.subtext }
                                            Badge { text: Store.gb((cand.modelData.size || 0) / 1073741824); tint: Ui.subtext }
                                            Badge { visible: cand.modelData.seeders !== undefined; text: cand.modelData.seeders + " seeds"; tint: cand.modelData.seeders > 3 ? Ui.green : Ui.yellow }
                                            Badge { visible: cand.modelData.score !== undefined; text: "score " + cand.modelData.score; tint: Ui.subtext }
                                            Text { text: cand.modelData.indexer || ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                                        }
                                        Text { visible: !!cand.modelData.reason; Layout.fillWidth: true; text: cand.modelData.reason || ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WordWrap }
                                    }
                                    UiButton { small: true; label: cand.isDonor ? "in use" : "Use"; enabledBtn: !cand.isDonor; onClicked: Store.dubAct(det.j.id, "use", cand.modelData.guid) }
                                }
                            }
                        }
                    }
                    Card {
                        visible: !!det.j && (det.j.history || []).length > 0
                        title: "History"
                        Repeater {
                            model: det.j ? (det.j.history || []).slice(-15).reverse() : []
                            RowLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 8
                                Text { text: det.when(modelData.t); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                                Text { Layout.fillWidth: true; text: modelData.msg; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap }
                            }
                        }
                    }
                }
            }
        }
    }
}
