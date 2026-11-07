import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// a context menu: items are { label, icon, action: fn, sub: [items], danger, header }; a `sub` opens in place
// with a back row. Opened with show(x, y, items) at window coordinates (parent is the window overlay).
Popup {
    id: menu
    parent: Overlay.overlay
    property var items: []
    property var stack: []
    padding: 6
    modal: true
    dim: false
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle { color: Ui.raised; border.width: 1; border.color: Ui.surface; radius: Ui.radius }
    width: 240
    implicitHeight: col.implicitHeight + padding * 2

    function show(px, py, list) {
        items = list; stack = []
        x = Math.min(px, parent.width - width - 8)
        y = Math.min(py, parent.height - implicitHeight - 8)
        open()
    }
    function descend(list, title) { stack = stack.concat([items]); items = [{ label: title, icon: "󰅁", action: () => menu.ascend() }].concat(list) }
    function ascend() { if (stack.length) { items = stack[stack.length - 1]; stack = stack.slice(0, -1) } }

    contentItem: ColumnLayout {
        id: col
        spacing: 1
        Repeater {
            model: menu.items
            delegate: Rectangle {
                id: row
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: modelData.header ? 22 : 28
                radius: Ui.radius - 2
                color: !modelData.header && rm.containsMouse ? Ui.surface : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    spacing: 8
                    Text { visible: !row.modelData.header; text: row.modelData.icon || ""; color: row.modelData.danger ? Ui.red : Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize; Layout.preferredWidth: 16 }
                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.label
                        color: row.modelData.header ? Ui.overlay : row.modelData.danger ? Ui.red : Ui.text
                        font.family: Ui.font; font.pixelSize: row.modelData.header ? Ui.fontSize - 3 : Ui.fontSize - 1; font.bold: !!row.modelData.header
                        elide: Text.ElideRight
                    }
                    Text { visible: !!row.modelData.sub; text: "󰅂"; color: Ui.subtext; font.family: Ui.iconFont; font.pixelSize: Ui.fontSize }
                }
                MouseArea {
                    id: rm
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !row.modelData.header
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (row.modelData.sub) { menu.descend(row.modelData.sub, row.modelData.label); return }
                        menu.close()
                        if (row.modelData.action) row.modelData.action()
                    }
                }
            }
        }
    }

    // the entries every track and album gets: play, play next, queue, playlists
    function trackItems(keys, extra) {
        const list = Array.isArray(keys) ? keys : [keys]
        const one = list.length === 1 ? Store.byKey[list[0]] : null
        const pls = Store.playlists.filter(p => !p.smart).map(p => ({ label: p.name, icon: "󰲸", action: () => Store.addToPlaylist(p.id, list) }))
        const items = [
            { label: "Play", icon: "󰐊", action: () => Player.playList(list, 0) },
            { label: "Play next", icon: "󰒭", action: () => Player.playNext(list) },
            { label: "Add to queue", icon: "󰐕", action: () => Player.enqueue(list) },
            { label: "Add to playlist", icon: "󰲸", sub: pls.concat([{ label: "New playlist…", icon: "󰐕", action: () => Store.newPlaylistWith(list) }]) }
        ]
        if (one) {
            items.push({ label: Store.liked(one.key) ? "Unlike" : "Like", icon: Store.liked(one.key) ? "󰋕" : "󰋕", action: () => Store.toggleLike(one.key) })
            items.push({ label: "Go to album", icon: "󰀥", action: () => Store.goAlbum(one.albumKey) })
            items.push({ label: "Go to artist", icon: "󰠃", action: () => Store.goArtist(one.albumArtist) })
        }
        return items.concat(extra || [])
    }
    function albumItems(album, extra) {
        const keys = album.tracks.map(t => t.key)
        const pls = Store.playlists.filter(p => !p.smart).map(p => ({ label: p.name, icon: "󰲸", action: () => Store.addToPlaylist(p.id, keys) }))
        return [
            { label: "Play", icon: "󰐊", action: () => Player.playList(keys, 0) },
            { label: "Shuffle", icon: "󰒝", action: () => Player.playShuffled(keys) },
            { label: "Play next", icon: "󰒭", action: () => Player.playNext(keys) },
            { label: "Add to queue", icon: "󰐕", action: () => Player.enqueue(keys) },
            { label: "Add to playlist", icon: "󰲸", sub: pls.concat([{ label: "New playlist…", icon: "󰐕", action: () => Store.newPlaylistWith(keys) }]) },
            { label: "Go to artist", icon: "󰠃", action: () => Store.goArtist(album.artist) },
            { label: "Open folder", icon: "󰉋", action: () => Store.openFolder(album) }
        ].concat(extra || [])
    }
}
