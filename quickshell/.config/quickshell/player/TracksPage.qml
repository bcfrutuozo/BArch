pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// every track as a table: sort by any column, group by album, artist, genre or year, filter
Item {
    id: page
    property var menu: null
    property string sort: "artist"
    property bool desc: false
    property string group: "none"
    property string filter: ""

    function cmp(col) {
        const f = Store.fold
        switch (col) {
        case "title": return (a, b) => f(a.title) < f(b.title) ? -1 : f(a.title) > f(b.title) ? 1 : 0
        case "album": return (a, b) => (f(a.album) + a.n) < (f(b.album) + b.n) ? -1 : 1
        case "genre": return (a, b) => f(a.genre) < f(b.genre) ? -1 : f(a.genre) > f(b.genre) ? 1 : 0
        case "year": return (a, b) => a.year - b.year
        case "plays": return (a, b) => Store.plays(a.key) - Store.plays(b.key)
        case "length": return (a, b) => a.length - b.length
        case "n": return (a, b) => a.n < b.n ? -1 : a.n > b.n ? 1 : 0
        default: return null      // artist: the catalog's own order
        }
    }
    readonly property var rows: {
        let l = Store.tracks
        const q = Store.fold(filter).trim()
        if (q) { const w = q.split(/\s+/); l = l.filter(t => w.every(x => t.s.includes(x))) }
        const c = cmp(sort)
        if (c || desc) { l = l.slice(); if (c) l.sort(c); if (desc) l.reverse() }
        if (group === "none") return l
        const keyOf = group === "album" ? t => t.albumKey : group === "artist" ? t => t.albumArtist : group === "genre" ? t => t.genre || "(no genre)" : t => String(t.year || "(no year)")
        const labelOf = group === "album" ? t => t.album + " — " + t.albumArtist + (t.year ? " (" + t.year + ")" : "") : keyOf
        // grouped: the groups in the order their first track has, each with its tracks in the sort order
        const order = [], groups = {}
        for (const t of l) { const k = keyOf(t); if (!groups[k]) { groups[k] = []; order.push(k) } groups[k].push(t) }
        const out = []
        for (const k of order) { out.push({ header: true, label: labelOf(groups[k][0]) + "  ·  " + groups[k].length }); for (const t of groups[k]) out.push(t) }
        return out
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16
            spacing: 8
            Text { text: Store.tracks.length + " tracks · " + Store.hours(Store.totalLength); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            Item { Layout.fillWidth: true }
            UiButton { icon: "󰒝"; label: "Shuffle all"; small: true; onClicked: Player.playShuffled(page.rows.filter(t => !t.header)) }
            UiField { Layout.preferredWidth: 240; placeholderText: "filter tracks"; onTextChanged: page.filter = text }
            Text { text: "Group"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiCombo {
                entries: [{ label: "None", value: "none" }, { label: "Album", value: "album" }, { label: "Artist", value: "artist" }, { label: "Genre", value: "genre" }, { label: "Year", value: "year" }]
                value: page.group
                onPicked: v => page.group = v
            }
        }
        TrackList {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 6; Layout.rightMargin: 6
            tracks: page.rows
            showGenre: true
            showYear: true
            sortable: true
            sortCol: page.sort
            sortDesc: page.desc
            menu: page.menu
            empty: Store.tracks.length ? "No track matches." : "Loading the library…"
            onSortBy: col => { if (col === page.sort) page.desc = !page.desc; else { page.sort = col; page.desc = col === "plays" || col === "year" } }
        }
    }
}
