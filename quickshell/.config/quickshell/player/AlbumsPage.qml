import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// every album as a cover; sort by artist, title, year or when it arrived
Item {
    id: page
    property var menu: null
    property string sort: "artist"
    property string filter: ""
    readonly property var sorted: {
        let l = Store.albums
        const f = Store.fold(filter).trim()
        if (f) l = l.filter(a => a.s.includes(f))
        if (sort === "artist") return l
        l = l.slice()
        if (sort === "title") l.sort((a, b) => Store.fold(a.album) < Store.fold(b.album) ? -1 : 1)
        else if (sort === "year") l.sort((a, b) => (b.year - a.year) || (a.sortKey < b.sortKey ? -1 : 1))
        else if (sort === "added") l.sort((a, b) => b.added - a.added)
        else if (sort === "plays") l.sort((a, b) => b.tracks.reduce((x, t) => x + Store.plays(t.key), 0) - a.tracks.reduce((x, t) => x + Store.plays(t.key), 0))
        return l
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16; Layout.rightMargin: 16
            spacing: 8
            Text { text: page.sorted.length + " albums"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            Item { Layout.fillWidth: true }
            UiField { Layout.preferredWidth: 220; placeholderText: "filter albums"; onTextChanged: page.filter = text }
            Text { text: "Sort"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            UiCombo {
                entries: [{ label: "Artist", value: "artist" }, { label: "Title", value: "title" }, { label: "Year", value: "year" }, { label: "Recently added", value: "added" }, { label: "Most played", value: "plays" }]
                value: page.sort
                onPicked: v => page.sort = v
            }
        }
        AlbumGrid {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 8; Layout.rightMargin: 8
            albums: page.sorted
            menu: page.menu
            empty: Store.albums.length ? "No album matches." : (Store.configured ? "Loading the library…" : "No ~/.config/barch/music.json: run barch music install.")
            onPicked: a => Store.goAlbum(a.key)
        }
    }
}
