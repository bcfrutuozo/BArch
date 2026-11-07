// shell.qml — BArch Player: the music library on the NAS (/music, the one the pipeline keeps) as a player, in
// the bar's theme. Albums, artists, tracks and genres from the catalog the pipeline serves (server/music/catalog.py),
// played by mpv from the share (or streamed from the API), with a queue, likes, play counts, playlists (hand-made
// and smart), lyrics, statistics; MPRIS through mpv-mpris, so the bar's media island and playerctl follow it.
// Own Shell ID; the shared controls come from ../ui.
//
//   qs -p ~/.config/quickshell/player          barch player [browse] [albums|artists|tracks|genres|queue|favorites|recent|lyrics|stats|settings]

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property string page: "albums"
    property string album: ""            // an album open over the page
    property string playlistId: ""
    property string query: ""
    readonly property var pages: [
        { id: "albums", label: "Albums", icon: "󰀥", index: 0 },
        { id: "artists", label: "Artists", icon: "󰠃", index: 1 },
        { id: "tracks", label: "Tracks", icon: "󰝚", index: 2 },
        { id: "genres", label: "Genres", icon: "󰓹", index: 3 },
        { id: "queue", label: "Queue", icon: "󰐑", index: 4, kind: "queue" },
        { id: "favorites", label: "Favorites", icon: "󰋑", index: 4, kind: "favorites" },
        { id: "recent", label: "Recent", icon: "󰥔", index: 4, kind: "recent" },
        { id: "lyrics", label: "Lyrics", icon: "󰨖", index: 5 },
        { id: "stats", label: "Statistics", icon: "󰄪", index: 6 },
        { id: "settings", label: "Settings", icon: "󰒓", index: 7 }
    ]
    readonly property var pageDef: pages.filter(p => p.id === page)[0] || pages[0]
    readonly property string title: page === "search" ? "Search" : page === "playlist" ? ((Store.playlist(playlistId) || { name: "Playlist" }).name) : pageDef.label

    function open(p) {
        if (p && pages.some(x => x.id === p)) { page = p; album = "" }
        win.visible = true
    }
    function goAlbum(key) { if (Store.albumByKey[key]) { album = key } }
    function goArtist(name) { album = ""; page = "artists"; artistsPage.select(name) }
    function goPlaylist(id) { album = ""; playlistId = id; page = "playlist" }
    function back() {
        if (album) { album = ""; return }
        if (page === "search") { search.text = ""; page = "albums" }
    }
    Component.onCompleted: { const p = Quickshell.env("BARCH_PLAYER_PAGE"); if (p) open(p) }
    Connections {
        target: Store
        function onNavigate(p, arg) {
            if (p === "album") root.goAlbum(arg)
            else if (p === "artists" && arg) root.goArtist(arg)
            else if (p === "playlist") root.goPlaylist(arg)
            else root.open(p)
        }
        function onAskNewPlaylist(keys) { dialog.create(keys) }
    }
    onQueryChanged: { if (query.trim() !== "") { album = ""; if (page !== "search") page = "search" } else if (page === "search") page = "albums" }

    IpcHandler {
        target: "app"
        function open(page: string): void { root.open(page) }
        function toggle(): void { Player.toggle() }
        function play(): void { Player.play() }
        function pause(): void { Player.pause() }
        function next(): void { Player.next() }
        function prev(): void { Player.prev() }
        function stop(): void { Player.stop() }
        function seek(s: string): void { const n = parseFloat(s); if (!isNaN(n)) { if (/^[+-]/.test(s)) Player.seekBy(n); else Player.seek(n) } }
        function volume(v: string): void { const n = parseFloat(v); if (!isNaN(n)) Player.setVolume(/^[+-]/.test(v) ? Player.volume + n : n) }
        function like(): void { Player.likeCurrent() }
        function shuffle(on: string): void { Player.setShuffle(on === "" ? !Player.shuffle : on === "on" || on === "1" || on === "true") }
        function repeat(mode: string): void { if (mode === "") Player.cycleRepeat(); else if (["off", "all", "one"].includes(mode)) Player.setRepeat(mode) }
        function status(): string { return JSON.stringify(Object.assign({ ok: true, albums: Store.albumCount, tracks: Store.trackCount }, Player.status())) }
        // "Artist/Album": open it, play it, or add it to the queue
        function album(folder: string): string { const a = Store.albumByKey[folder]; if (!a) return JSON.stringify({ ok: false, error: "no such album" }); root.goAlbum(folder); win.visible = true; return JSON.stringify({ ok: true }) }
        function playAlbum(folder: string): string { const a = Store.albumByKey[folder]; if (!a) return JSON.stringify({ ok: false, error: "no such album" }); Player.playList(a.tracks, 0); return JSON.stringify({ ok: true, tracks: a.tracks.length }) }
        function queueAlbum(folder: string): string { const a = Store.albumByKey[folder]; if (!a) return JSON.stringify({ ok: false, error: "no such album" }); Player.enqueue(a.tracks); return JSON.stringify({ ok: true, tracks: a.tracks.length }) }
        function playlist(name: string): string {
            const p = Store.playlists.filter(x => x.id === name || Store.fold(x.name) === Store.fold(name))[0]
            if (!p) return JSON.stringify({ ok: false, error: "no such playlist" })
            const ts = Store.playlistTracks(p); Player.playList(ts, 0); return JSON.stringify({ ok: true, tracks: ts.length })
        }
        function search(q: string): void { search.text = q; root.open("search"); win.visible = true }
        function close(): void { Qt.quit() }
    }

    FloatingWindow {
        id: win
        title: "BArch Player"
        implicitWidth: 1400
        implicitHeight: 900
        minimumSize: Qt.size(1040, 640)
        color: Ui.base
        onVisibleChanged: if (!visible) Qt.quit()

        // keyboard (a text field keeps the keys it uses)
        Shortcut { sequence: "Space"; onActivated: Player.toggle() }
        Shortcut { sequence: "N"; onActivated: Player.next() }
        Shortcut { sequence: "P"; onActivated: Player.prev() }
        Shortcut { sequence: "Right"; onActivated: Player.seekBy(5) }
        Shortcut { sequence: "Left"; onActivated: Player.seekBy(-5) }
        Shortcut { sequence: "S"; onActivated: Player.toggleShuffle() }
        Shortcut { sequence: "R"; onActivated: Player.cycleRepeat() }
        Shortcut { sequences: ["+", "="]; onActivated: Player.setVolume(Player.volume + 5) }
        Shortcut { sequence: "-"; onActivated: Player.setVolume(Player.volume - 5) }
        Shortcut { sequence: "M"; onActivated: Player.toggleMute() }
        Shortcut { sequence: "L"; onActivated: Player.likeCurrent() }
        Shortcut { sequences: ["/", "Ctrl+F"]; onActivated: { search.forceActiveFocus(); search.selectAll() } }
        Shortcut { sequence: "Q"; onActivated: root.open("queue") }
        Shortcut { sequence: "Y"; onActivated: root.open("lyrics") }
        Shortcut { sequence: "Escape"; onActivated: { if (search.activeFocus) search.focus = false; else root.back() } }
        Shortcut { sequence: "Ctrl+W"; onActivated: Qt.quit() }

        RowMenu { id: menu }
        PlaylistDialog { id: dialog }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // ---------- sidebar ----------
                Rectangle {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 210
                    color: Ui.raised
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 2
                        RowLayout {
                            Layout.leftMargin: 6; Layout.topMargin: 4; Layout.bottomMargin: 10
                            Text { text: "󰝚"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                            ColumnLayout {
                                spacing: 0
                                Text { text: "Player"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 2; font.bold: true }
                                Text {
                                    text: !Store.configured ? "not configured" : Store.albums.length === 0 ? (Store.reachable ? "loading…" : "NAS not reachable") : Store.albumCount + " albums" + (Store.reachable ? "" : " · offline")
                                    color: Store.configured && (Store.reachable || Store.albums.length) ? Ui.subtext : Ui.red
                                    font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3
                                }
                            }
                        }
                        component Nav: Rectangle {
                            id: nav
                            property string pid: ""
                            property string label: ""
                            property string icon: ""
                            property int marks: 0
                            property bool current: root.page === pid && !root.album
                            signal clicked()
                            signal menuAt(real x, real y)
                            Layout.fillWidth: true
                            implicitHeight: 30
                            radius: Ui.radius
                            color: current ? Ui.surface : (nm.containsMouse ? Ui.faint : "transparent")
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 8
                                Text { text: nav.icon; color: nav.current ? Ui.accent : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize + 1 }
                                Text { Layout.fillWidth: true; text: nav.label; color: nav.current ? Ui.accent : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight }
                                Text { visible: nav.marks > 0; text: nav.marks; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                            }
                            MouseArea {
                                id: nm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: mouse => { if (mouse.button === Qt.RightButton) { const p = mapToItem(null, mouse.x, mouse.y); nav.menuAt(p.x, p.y) } else nav.clicked() }
                            }
                        }
                        Text { Layout.leftMargin: 10; Layout.topMargin: 2; text: "LIBRARY"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                        Repeater {
                            model: root.pages.filter(p => ["albums", "artists", "tracks", "genres"].includes(p.id))
                            Nav { required property var modelData; pid: modelData.id; label: modelData.label; icon: modelData.icon; onClicked: root.open(modelData.id) }
                        }
                        Text { Layout.leftMargin: 10; Layout.topMargin: 10; text: "LISTENING"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                        Nav { pid: "queue"; label: "Queue"; icon: "󰐑"; marks: Player.queue.length; onClicked: root.open("queue") }
                        Nav { pid: "favorites"; label: "Favorites"; icon: "󰋑"; marks: Store.likedTracks.length; onClicked: root.open("favorites") }
                        Nav { pid: "recent"; label: "Recent"; icon: "󰥔"; onClicked: root.open("recent") }
                        Nav { pid: "lyrics"; label: "Lyrics"; icon: "󰨖"; onClicked: root.open("lyrics") }
                        Nav { pid: "stats"; label: "Statistics"; icon: "󰄪"; onClicked: root.open("stats") }
                        RowLayout {
                            Layout.leftMargin: 10; Layout.topMargin: 10; Layout.rightMargin: 2
                            Text { Layout.fillWidth: true; text: "PLAYLISTS"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                            IconButton { size: 22; glyphSize: Ui.fontSize; icon: "󰐕"; tint: Ui.subtext; tooltip: "new playlist"; onClicked: { const p = mapToItem(null, 0, height); menu.show(p.x, p.y, [{ label: "New playlist", icon: "󰲸", action: () => dialog.create([]) }, { label: "New smart playlist", icon: "󰛨", action: () => dialog.createSmart() }]) } }
                        }
                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: Store.playlists
                            spacing: 2
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: Nav {
                                required property var modelData
                                required property int index
                                width: ListView.view.width
                                pid: "playlist"
                                current: root.page === "playlist" && root.playlistId === modelData.id && !root.album
                                label: modelData.name
                                icon: modelData.smart ? "󰛨" : "󰲸"
                                marks: modelData.smart ? 0 : modelData.tracks.length
                                onClicked: root.goPlaylist(modelData.id)
                                onMenuAt: (x, y) => menu.show(x, y, [
                                    { label: "Play", icon: "󰐊", action: () => Player.playList(Store.playlistTracks(modelData), 0) },
                                    { label: "Shuffle", icon: "󰒝", action: () => Player.playShuffled(Store.playlistTracks(modelData)) },
                                    { label: "Add to queue", icon: "󰐕", action: () => Player.enqueue(Store.playlistTracks(modelData)) },
                                    { label: modelData.smart ? "Rules…" : "Rename…", icon: "󰏫", action: () => dialog.edit(modelData.id) },
                                    { label: "Move up", icon: "󰁝", action: () => { if (index > 0) Store.movePlaylist(index, index - 1) } },
                                    { label: "Move down", icon: "󰁅", action: () => { if (index < Store.playlists.length - 1) Store.movePlaylist(index, index + 1) } },
                                    { label: "Delete", icon: "󰆴", danger: true, action: () => { Store.deletePlaylist(modelData.id); if (root.playlistId === modelData.id) root.open("albums") } }
                                ])
                            }
                        }
                        Nav { pid: "settings"; label: "Settings"; icon: "󰒓"; onClicked: root.open("settings") }
                    }
                }
                Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Ui.surface }

                // ---------- content ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.margins: 16; Layout.bottomMargin: 8
                        spacing: 10
                        UiButton { visible: root.album !== "" || root.page === "search"; icon: "󰅁"; small: true; tooltip: "back (Esc)"; onClicked: root.back() }
                        Text { text: root.album ? (Store.albumByKey[root.album] || {}).artist || "" : root.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 6; font.bold: true; elide: Text.ElideRight; Layout.maximumWidth: 500 }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: Store.statusText !== ""
                            text: Store.statusText; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle; Layout.maximumWidth: 400
                            Timer { interval: 4000; running: Store.statusText !== "" && !Store.statusBad; onTriggered: Store.statusText = "" }
                        }
                        UiField {
                            id: search
                            Layout.preferredWidth: 300
                            placeholderText: "search artists, albums, tracks  (/)"
                            onTextChanged: root.query = text
                            Keys.onEscapePressed: { text = ""; focus = false }
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        StackLayout {
                            anchors.fill: parent
                            visible: !root.album
                            currentIndex: root.page === "search" ? 8 : root.page === "playlist" ? 4 : root.pageDef.index
                            AlbumsPage { menu: menu }
                            ArtistsPage { id: artistsPage; menu: menu }
                            TracksPage { menu: menu }
                            GenresPage { menu: menu }
                            ListPage { menu: menu; dialog: dialog; kind: root.page === "playlist" ? "playlist" : (root.pageDef.kind || "queue"); playlistId: root.playlistId }
                            LyricsPage {}
                            StatsPage { menu: menu }
                            SettingsPage {}
                            SearchPage { menu: menu; query: root.query }
                        }
                        AlbumView { anchors.fill: parent; visible: root.album !== ""; album: Store.albumByKey[root.album] || null; menu: menu }
                    }
                }
            }
            NowPlaying {
                Layout.fillWidth: true
                menu: menu
                queueOn: root.page === "queue" && !root.album
                lyricsOn: root.page === "lyrics" && !root.album
                onShowQueue: root.page === "queue" && !root.album ? root.open("albums") : root.open("queue")
                onShowLyrics: root.page === "lyrics" && !root.album ? root.open("albums") : root.open("lyrics")
            }
        }
    }
}
