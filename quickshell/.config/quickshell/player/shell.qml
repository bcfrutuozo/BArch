// shell.qml — BArch Player: the music library on the NAS (/music, the one the pipeline keeps) as a player, in
// the bar's theme. Albums, artists, tracks and genres from the catalog the pipeline serves (server/music/catalog.py),
// played by mpv from the share (or streamed from the API), with a queue, likes, play counts, playlists (hand-made
// and smart), lyrics, statistics, a GPU visualizer, an equalizer; MPRIS through mpv-mpris, so the bar's media
// island and playerctl follow it. The music does not depend on the window: closed (the X, Ctrl+W, Super+W) it
// keeps playing and the bar shows a button (media/PlayerTray.qml) that brings the window back; the window is a
// LazyLoader, so a reopen is a fresh window whatever the compositor did to the last one.
// Own Shell ID; the shared controls come from ../ui.
//
//   qs -p ~/.config/quickshell/player          barch player [browse] [albums|artists|tracks|genres|queue|favorites|recent|lyrics|stats|viz|eq|settings]

pragma ComponentBehavior: Bound
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
    property string pendingArtist: ""    // an artist to select once the window exists
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
        { id: "settings", label: "Settings", icon: "󰒓", index: 7 },
        { id: "viz", label: "Visualizer", icon: "󰺢", index: 8 },
        { id: "eq", label: "Equalizer", icon: "󰝞", index: 9 }
    ]
    readonly property var pageDef: pages.filter(p => p.id === page)[0] || pages[0]
    readonly property string title: page === "search" ? "Search" : page === "playlist" ? ((Store.playlist(playlistId) || { name: "Playlist" }).name) : pageDef.label

    // ---------- the window ----------
    // `shown`: on screen. `loaded`: the window object exists. Our own close (the X, Ctrl+W) only hides it, so
    // the next open is instant; a close by the compositor (Super+W) destroys the backing window for good on
    // this side, so the loader drops the object and the next open builds a fresh one.
    property bool shown: true
    property bool loaded: true
    readonly property bool closeHides: Store.state.closeHides !== false
    readonly property bool keepAlive: closeHides && Player.hasTrack
    readonly property var win: loader.item
    onShownChanged: { Viz.shown = shown; writeWindowState(); if (!shown && !keepAlive) Qt.quit() }
    function show() { if (!loaded) loaded = true; shown = true }
    function hide() { if (keepAlive) shown = false; else Qt.quit() }
    function closedByCompositor() { loaded = false; shown = false }
    // the window closed and nothing playing for a minute: no reason to stay
    Timer { interval: 60000; running: !root.shown && !Player.hasTrack; onTriggered: Qt.quit() }
    // ~/.local/state/barch/player/window.json: the bar's PlayerTray shows a button while the player runs without a window
    FileView { id: windowState; path: Store.stateDir + "/window.json"; printErrors: false }
    function writeWindowState() { windowState.setText(JSON.stringify({ hidden: !shown, track: Player.current ? Player.current.title + " · " + Player.current.artist : "", t: Date.now() }) + "\n") }
    Connections { target: Player; function onCurrentKeyChanged() { if (!root.shown) root.writeWindowState() } }
    Component.onCompleted: { const p = Quickshell.env("BARCH_PLAYER_PAGE"); if (p) open(p); writeWindowState() }
    Component.onDestruction: { try { windowState.setText(JSON.stringify({ hidden: false, quit: true, t: Date.now() }) + "\n") } catch (e) {} }

    function open(p) {
        if (p && pages.some(x => x.id === p)) { page = p; album = "" }
        shown = true
    }
    function goAlbum(key) { if (Store.albumByKey[key]) { album = key } }
    function goArtist(name) { album = ""; page = "artists"; if (win) win.selectArtist(name); else pendingArtist = name }
    function goPlaylist(id) { album = ""; playlistId = id; page = "playlist" }
    function back() {
        if (album) { album = ""; return }
        if (page === "search") { if (win) win.setQuery(""); query = ""; page = "albums" }
    }
    Connections {
        target: Store
        function onNavigate(p, arg) {
            if (p === "album") root.goAlbum(arg)
            else if (p === "artists" && arg) root.goArtist(arg)
            else if (p === "playlist") root.goPlaylist(arg)
            else root.open(p)
        }
        function onAskNewPlaylist(keys) { if (root.win) root.win.newPlaylist(keys) }
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
        function eq(arg: string): string { return JSON.stringify(arg === "" ? { ok: true, eq: Player.eq, presets: Object.keys(Player.eqPresets) } : Player.eqCommand(arg)) }
        function status(): string { return JSON.stringify(Object.assign({ ok: true, albums: Store.albumCount, tracks: Store.trackCount, window: root.shown }, Player.status())) }
        // "Artist/Album": open it, play it, or add it to the queue
        function album(folder: string): string { const a = Store.albumByKey[folder]; if (!a) return JSON.stringify({ ok: false, error: "no such album" }); root.goAlbum(folder); root.show(); return JSON.stringify({ ok: true }) }
        function playAlbum(folder: string): string { const a = Store.albumByKey[folder]; if (!a) return JSON.stringify({ ok: false, error: "no such album" }); Player.playList(a.tracks, 0); return JSON.stringify({ ok: true, tracks: a.tracks.length }) }
        function queueAlbum(folder: string): string { const a = Store.albumByKey[folder]; if (!a) return JSON.stringify({ ok: false, error: "no such album" }); Player.enqueue(a.tracks); return JSON.stringify({ ok: true, tracks: a.tracks.length }) }
        function playlist(name: string): string {
            const p = Store.playlists.filter(x => x.id === name || Store.fold(x.name) === Store.fold(name))[0]
            if (!p) return JSON.stringify({ ok: false, error: "no such playlist" })
            const ts = Store.playlistTracks(p); Player.playList(ts, 0); return JSON.stringify({ ok: true, tracks: ts.length })
        }
        function search(q: string): void { root.show(); root.query = q; if (root.win) root.win.setQuery(q); root.open("search") }
        function hide(): void { root.hide() }
        function window(): void { root.show() }     // ("show" is a word the qs ipc CLI takes for itself)
        function quit(): void { Qt.quit() }
        function close(): void { Qt.quit() }
    }

    LazyLoader {
        id: loader
        active: root.loaded

        FloatingWindow {
            id: win
            title: "BArch Player"
            implicitWidth: 1400
            implicitHeight: 900
            minimumSize: Qt.size(1040, 640)
            color: Ui.base
            visible: root.shown
            // the compositor closed it (Super+W): Quickshell flips `visible` off by itself, and setting it back
            // on brings no window, so when it goes off without us asking (root.shown still true) the window
            // object is dropped (root.loaded) and rebuilt on the next open
            onVisibleChanged: if (!visible && root.shown) Qt.callLater(root.closedByCompositor)
            onBackingWindowVisibleChanged: if (!backingWindowVisible && root.shown && !visible) Qt.callLater(root.closedByCompositor)
            Component.onCompleted: { search.text = root.query; if (root.pendingArtist) { selectArtist(root.pendingArtist); root.pendingArtist = "" } }

            function selectArtist(name) { artistsLoader.visited = true; if (artistsLoader.item) artistsLoader.item.select(name); else root.pendingArtist = name }
            Connections { target: artistsLoader; function onLoaded() { if (root.pendingArtist) { artistsLoader.item.select(root.pendingArtist); root.pendingArtist = "" } } }
            function setQuery(q) { search.text = q }
            function newPlaylist(keys) { playlistDialog.create(keys) }

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
            Shortcut { sequence: "V"; onActivated: root.open("viz") }
            Shortcut { sequence: "E"; onActivated: root.open("eq") }
            Shortcut { sequence: "Escape"; onActivated: { if (search.activeFocus) search.focus = false; else root.back() } }
            Shortcut { sequence: "Ctrl+W"; onActivated: root.hide() }
            Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }

            RowMenu { id: rowMenu }
            PlaylistDialog { id: playlistDialog }

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
                            Nav { pid: "viz"; label: "Visualizer"; icon: "󰺢"; onClicked: root.open("viz") }
                            Nav { pid: "eq"; label: "Equalizer"; icon: "󰝞"; onClicked: root.open("eq") }
                            RowLayout {
                                Layout.leftMargin: 10; Layout.topMargin: 10; Layout.rightMargin: 2
                                Text { Layout.fillWidth: true; text: "PLAYLISTS"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 4; font.bold: true }
                                IconButton { size: 22; glyphSize: Ui.fontSize; icon: "󰐕"; tint: Ui.subtext; tooltip: "new playlist"; onClicked: { const p = mapToItem(null, 0, height); rowMenu.show(p.x, p.y, [{ label: "New playlist", icon: "󰲸", action: () => playlistDialog.create([]) }, { label: "New smart playlist", icon: "󰛨", action: () => playlistDialog.createSmart() }]) } }
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
                                    onMenuAt: (x, y) => rowMenu.show(x, y, [
                                        { label: "Play", icon: "󰐊", action: () => Player.playList(Store.playlistTracks(modelData), 0) },
                                        { label: "Shuffle", icon: "󰒝", action: () => Player.playShuffled(Store.playlistTracks(modelData)) },
                                        { label: "Add to queue", icon: "󰐕", action: () => Player.enqueue(Store.playlistTracks(modelData)) },
                                        { label: modelData.smart ? "Rules…" : "Rename…", icon: "󰏫", action: () => playlistDialog.edit(modelData.id) },
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
                            IconButton { icon: "󰅖"; size: 28; glyphSize: Ui.fontSize + 2; tint: Ui.subtext; tooltip: root.keepAlive ? "Close: the music goes on, the bar gets a button to come back (Ctrl+W) · Ctrl+Q quits" : "Close (Ctrl+W)"; onClicked: root.hide() }
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
                            // every page a Loader, built the first time it is shown and kept after (the window
                            // opens with one page's worth of work, not eleven)
                            component Page: Loader {
                                readonly property bool current: StackLayout.isCurrentItem
                                property bool visited: false
                                onCurrentChanged: if (current) visited = true
                                Component.onCompleted: if (current) visited = true
                                active: visited
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                            }
                            StackLayout {
                                anchors.fill: parent
                                visible: !root.album
                                currentIndex: root.page === "search" ? 10 : root.page === "playlist" ? 4 : root.pageDef.index
                                Page { sourceComponent: AlbumsPage { menu: rowMenu } }
                                Page { id: artistsLoader; sourceComponent: ArtistsPage { menu: rowMenu } }
                                Page { sourceComponent: TracksPage { menu: rowMenu } }
                                Page { sourceComponent: GenresPage { menu: rowMenu } }
                                Page { sourceComponent: ListPage { menu: rowMenu; dialog: playlistDialog; kind: root.page === "playlist" ? "playlist" : (root.pageDef.kind || "queue"); playlistId: root.playlistId } }
                                Page { sourceComponent: LyricsPage {} }
                                Page { sourceComponent: StatsPage { menu: rowMenu } }
                                Page { sourceComponent: SettingsPage {} }
                                Page { sourceComponent: VizPage { active: root.page === "viz" && !root.album && win.visible } }
                                Page { sourceComponent: EqPage {} }
                                Page { sourceComponent: SearchPage { menu: rowMenu; query: root.query } }
                            }
                            AlbumView { anchors.fill: parent; visible: root.album !== ""; album: Store.albumByKey[root.album] || null; menu: rowMenu }
                        }
                    }
                }
                NowPlaying {
                    Layout.fillWidth: true
                    menu: rowMenu
                    queueOn: root.page === "queue" && !root.album
                    lyricsOn: root.page === "lyrics" && !root.album
                    onShowQueue: root.page === "queue" && !root.album ? root.open("albums") : root.open("queue")
                    onShowLyrics: root.page === "lyrics" && !root.album ? root.open("albums") : root.open("lyrics")
                }
            }
        }
    }
}
