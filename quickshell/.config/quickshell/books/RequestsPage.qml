pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The requests on the left (pending first: the ones the automatic download found no strict match
// for), the chosen one on the right: why it stopped, a release search with a query you can fix
// (title and surname by default, any source), Download on the right release, Fix with Agent.
Item {
    id: page
    property string fixedFilter: ""      // "rejected": the Rejected tab (no filter combo)
    Component.onCompleted: {
        if (fixedFilter) Store.requestFilter = fixedFilter
        else if (Store.requestFilter === "rejected") Store.requestFilter = "pending"
        Store.selected = null
        Store.loadRequests()
    }

    readonly property var sources: [
        { label: "Every source", value: "" }, { label: "Anna's Archive", value: "direct_download" },
        { label: "Soulseek", value: "slskd" }, { label: "IRC", value: "irc" },
        { label: "Prowlarr", value: "prowlarr" }, { label: "AudiobookBay", value: "audiobookbay" }
    ]
    readonly property var filters: [
        { label: "Pending", value: "pending" }, { label: "Fulfilled", value: "fulfilled" },
        { label: "Rejected", value: "rejected" }, { label: "Cancelled", value: "cancelled" }, { label: "All", value: "all" }
    ]
    readonly property var r: Store.selected
    property string source: ""
    onRChanged: if (r) { q.text = r.title.replace(/[:(].*$/, "").trim() + " " + Store.surname(r.authors); source = "" }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            Layout.preferredWidth: 340; Layout.maximumWidth: 340
            Layout.fillHeight: true
            spacing: 6
            RowLayout {
                Layout.fillWidth: true; Layout.margins: 12; Layout.bottomMargin: 0
                Text { visible: page.fixedFilter !== ""; Layout.fillWidth: true; text: Store.requests.length + " rejected: Download on any release takes it back"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap }
                UiCombo { visible: page.fixedFilter === ""; Layout.fillWidth: true; entries: page.filters; value: Store.requestFilter; onPicked: v => { Store.requestFilter = v; Store.selected = null; Store.loadRequests() } }
                UiButton { small: true; icon: "󰑓"; tooltip: "reload"; onClicked: Store.loadRequests() }
            }
            ListView {
                id: list
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.leftMargin: 8; Layout.rightMargin: 8
                clip: true; spacing: 4
                model: Store.requests
                ScrollBar.vertical: ScrollBar {}
                Text {
                    anchors.centerIn: parent; width: parent.width - 20
                    visible: Store.requests.length === 0
                    text: Store.requestFilter === "pending" ? "Nothing waiting: every request found its release." : Store.requestFilter === "rejected" ? "Nothing rejected." : "No requests here."
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                }
                delegate: Rectangle {
                    id: item
                    required property var modelData
                    readonly property bool current: Store.selected && Store.selected.id === modelData.id
                    width: list.width; implicitHeight: 70
                    radius: Ui.radius
                    color: current ? Ui.surface : (im.containsMouse ? Ui.faint : "transparent")
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 6
                        spacing: 8
                        Cover { source: item.modelData.cover_file || ""; title: item.modelData.title; Layout.preferredWidth: 38; Layout.preferredHeight: 56 }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            Text { Layout.fillWidth: true; text: item.modelData.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; text: Store.authors(item.modelData.authors); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                            RowLayout {
                                spacing: 4
                                Badge { text: item.modelData.type; tint: item.modelData.type === "audiobook" ? Ui.yellow : Ui.accent }
                                Badge { text: item.modelData.status + (item.modelData.delivery && item.modelData.delivery !== "none" ? " · " + item.modelData.delivery : ""); tint: item.modelData.status === "pending" ? Ui.yellow : item.modelData.status === "fulfilled" ? Ui.green : Ui.overlay }
                                Text { visible: Store.fixing === String(item.modelData.id); text: "󰚩"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize }
                            }
                        }
                    }
                    MouseArea { id: im; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.select(item.modelData) }
                }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }

        // ---- the chosen request
        Flickable {
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            contentHeight: detail.implicitHeight + 32
            ScrollBar.vertical: ScrollBar {}
            ColumnLayout {
                id: detail
                visible: !!page.r
                x: 16; y: 12
                width: parent.width - 32
                spacing: 12
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14
                    Cover { source: page.r ? page.r.cover_file || "" : ""; title: page.r ? page.r.title : ""; Layout.preferredWidth: 90; Layout.preferredHeight: 135 }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 3
                        Text { Layout.fillWidth: true; text: page.r ? page.r.title : ""; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 4; font.bold: true; wrapMode: Text.WordWrap }
                        Text { Layout.fillWidth: true; text: page.r ? Store.authors(page.r.authors) + (page.r.year ? " · " + page.r.year : "") : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
                        Text {
                            Layout.fillWidth: true
                            text: page.r ? "#" + page.r.id + " · " + page.r.type + " · " + page.r.status + (page.r.user ? " · asked by " + page.r.user : "") : ""
                            color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                        }
                        Text {
                            visible: !!page.r && (page.r.reason || page.r.admin_note) !== ""
                            Layout.fillWidth: true
                            text: page.r ? (page.r.reason || page.r.admin_note) : ""
                            color: Ui.yellow; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap
                        }
                        Text {
                            visible: !!page.r && !!page.r.release
                            Layout.fillWidth: true
                            text: page.r && page.r.release ? "release: " + page.r.release.source + " · " + (page.r.release.title || "") : ""
                            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight
                        }
                        Text {
                            readonly property string err: page.r ? (Store.acceptError[String(page.r.id)] || "") : ""
                            visible: err !== "" || (!!page.r && !!Store.accepting[String(page.r.id)])
                            Layout.fillWidth: true
                            text: err !== "" ? err : "Accept is searching every source for releases (a minute or two); the window stays usable."
                            color: err !== "" ? Ui.red : Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            spacing: 6
                            UiButton { small: true; label: "Hardcover"; icon: "󰏌"; visible: !!page.r && page.r.url !== ""; onClicked: Store.openUrl(page.r.url) }
                            UiButton {
                                small: true; primary: true; icon: "󰄬"
                                label: "Accept"
                                visible: !!page.r && page.r.status !== "fulfilled"
                                tooltip: "pick the release to download: the search opens with the best fits first"
                                onClicked: picker.openFor(page.r)
                            }
                            UiButton { small: true; label: "Reject"; icon: "󰜺"; danger: true; visible: !!page.r && page.r.status === "pending"; tooltip: "no: it will not be searched again"; onClicked: Store.act("reject", page.r.id) }
                            UiButton { small: true; label: "Back to pending"; icon: "󰑓"; visible: !!page.r && (page.r.status === "rejected" || page.r.status === "cancelled"); tooltip: "Hardcover Sync's automatic download tries it again"; onClicked: Store.act("reopen", page.r.id) }
                        }
                    }
                }

                // ---- release search
                Card {
                    Layout.fillWidth: true
                    title: "Releases"
                    subtitle: "Fix the title or the author's spelling here when the request's metadata is off"
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        UiField { id: q; Layout.fillWidth: true; placeholderText: "query"; onAccepted: Store.findReleases(page.r.id, text, page.source, "") }
                        UiCombo { entries: page.sources; value: page.source; onPicked: v => page.source = v }
                        UiButton { label: Store.releasesLoading ? "Searching…" : "Search"; icon: "󰍉"; primary: true; enabledBtn: !Store.releasesLoading && !!page.r; onClicked: Store.findReleases(page.r.id, q.text, page.source, "") }
                    }
                    Text {
                        visible: Object.keys(Store.releasesErrors).length > 0
                        Layout.fillWidth: true
                        text: Object.keys(Store.releasesErrors).map(k => k + ": " + Store.releasesErrors[k]).join("\n")
                        color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap
                    }
                    Text {
                        visible: Store.releasesLoading
                        text: "Searching every source can take a minute (FlareSolverr indexers, Soulseek peers)…"
                        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                    }
                    Repeater {
                        model: Store.releases
                        Rectangle {
                            id: rel
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 40
                            radius: Ui.radius
                            color: rm.containsMouse ? Ui.faint : "transparent"
                            MouseArea { id: rm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                                spacing: 8
                                Badge { text: rel.modelData.source + (rel.modelData.indexer && rel.modelData.indexer !== rel.modelData.source ? " · " + rel.modelData.indexer : ""); tint: Ui.accent }
                                Text {
                                    Layout.fillWidth: true
                                    text: rel.modelData.title
                                    color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle
                                    MouseArea { anchors.fill: parent; enabled: rel.modelData.info_url !== ""; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: Store.openUrl(rel.modelData.info_url) }
                                }
                                Text {
                                    text: [rel.modelData.format, rel.modelData.language, rel.modelData.size, rel.modelData.seeders !== null && rel.modelData.seeders !== undefined ? rel.modelData.seeders + " seeders" : ""].filter(x => x).join(" · ")
                                    color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                                }
                                UiButton { small: true; label: "Download"; icon: "󰇚"; primary: true; onClicked: Store.fulfil(page.r.id, rel.modelData.n) }
                            }
                        }
                    }
                }

                // ---- Claude
                Card {
                    Layout.fillWidth: true
                    title: "Fix with Agent"
                    subtitle: "Claude finds out what the book really is, searches with better queries and downloads the right release, or says why there is none"
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        UiField { id: hint; Layout.fillWidth: true; placeholderText: "hint (optional): \"the 4th edition\", \"in Portuguese\"…" }
                        UiButton {
                            label: Store.fixing === String(page.r ? page.r.id : "") ? "Working…" : "Fix with Agent"
                            icon: "󰚩"; primary: true
                            enabledBtn: !!page.r && Store.fixing === ""
                            onClicked: Store.fix(page.r.id, hint.text)
                        }
                    }
                    Text {
                        readonly property var res: page.r ? Store.fixResult[String(page.r.id)] : null
                        visible: !!res
                        Layout.fillWidth: true
                        text: res ? (res.downloaded ? "✓ " : "") + res.summary : ""
                        color: res && res.downloaded ? Ui.green : Ui.text
                        font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.WordWrap
                    }
                }
            }
            Text {
                visible: !page.r
                anchors.centerIn: parent
                text: "Pick a request on the left."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize
            }
        }
    }

    // ---- Accept: the releases, best fits first, pick one to download
    Popup {
        id: picker
        parent: Overlay.overlay
        modal: true
        focus: true
        x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
        width: Math.min(parent.width - 80, 1000); height: Math.min(parent.height - 80, 680)
        padding: 16
        property var req: null
        property string source: ""
        function openFor(r) {
            req = r
            pq.text = r.title.replace(/[:(].*$/, "").trim() + " " + Store.surname(r.authors)
            source = r.type === "audiobook" ? "audiobookbay" : ""
            open()
            if (!(Store.selected && Store.selected.id === r.id && Store.releases.length)) search()
        }
        function search() { Store.findReleases(req.id, pq.text, source, "") }
        background: Rectangle { radius: Ui.cardRadius; color: Ui.base; border.width: 1; border.color: Ui.surface }
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }
        contentItem: ColumnLayout {
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: picker.req ? "Accept #" + picker.req.id + ": " + picker.req.title + " (" + picker.req.type + ")" : ""
                    color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true; elide: Text.ElideRight
                }
                UiButton { small: true; icon: "󰅖"; tooltip: "close"; onClicked: picker.close() }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                UiField { id: pq; Layout.fillWidth: true; placeholderText: "query"; onAccepted: picker.search() }
                UiCombo { entries: page.sources; value: picker.source; onPicked: v => picker.source = v }
                UiButton { label: Store.releasesLoading ? "Searching…" : "Search"; icon: "󰍉"; primary: true; enabledBtn: !Store.releasesLoading; onClicked: picker.search() }
            }
            Text {
                Layout.fillWidth: true
                text: Store.releasesLoading ? "Searching (a minute or two on every source)…"
                    : Store.releases.length === 0 ? "No releases: change the query or the source."
                    : Store.releases.filter(x => x.fits).length + " of " + Store.releases.length + " fit the request (its title and type); the best is first"
                color: Store.releasesLoading ? Ui.accent : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
            }
            Text {
                visible: Object.keys(Store.releasesErrors).length > 0
                Layout.fillWidth: true
                text: Object.keys(Store.releasesErrors).map(k => k + ": " + Store.releasesErrors[k]).join("\n")
                color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WordWrap
            }
            ListView {
                id: plist
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true; spacing: 4
                model: Store.releasesLoading ? [] : Store.releases
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    id: prow
                    required property var modelData
                    width: plist.width; implicitHeight: 46
                    radius: Ui.radius
                    color: modelData.best ? Qt.rgba(Ui.green.r, Ui.green.g, Ui.green.b, 0.12) : (pm.containsMouse ? Ui.faint : "transparent")
                    opacity: modelData.fits ? 1 : 0.55
                    MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                        spacing: 8
                        Badge { visible: prow.modelData.best; text: "best"; tint: Ui.green }
                        Badge { visible: !prow.modelData.fits; text: "doesn't fit"; tint: Ui.overlay; tip: "the title or the type does not match the request" }
                        Badge { text: prow.modelData.source + (prow.modelData.indexer && prow.modelData.indexer !== prow.modelData.source ? " · " + prow.modelData.indexer : ""); tint: Ui.accent }
                        Text {
                            Layout.fillWidth: true
                            text: prow.modelData.title
                            color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle
                            MouseArea { anchors.fill: parent; enabled: prow.modelData.info_url !== ""; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: Store.openUrl(prow.modelData.info_url) }
                        }
                        Text {
                            text: [prow.modelData.content_type, prow.modelData.format, prow.modelData.language, prow.modelData.size, prow.modelData.seeders !== null && prow.modelData.seeders !== undefined ? prow.modelData.seeders + " seeders" : ""].filter(x => x).join(" · ")
                            color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                        }
                        UiButton { small: true; label: "Download"; icon: "󰇚"; primary: prow.modelData.fits; onClicked: { Store.fulfil(picker.req.id, prow.modelData.n); picker.close() } }
                    }
                }
            }
        }
    }
}
