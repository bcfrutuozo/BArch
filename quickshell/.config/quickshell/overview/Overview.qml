// Overview.qml — visão geral dos workspaces (Super+Tab), no visual da barra.
//
// Mostra os workspaces 1–10 em miniatura, cada um no formato do monitor em que está
// (o vertical aparece em pé), com o papel de parede e as janelas nas posições reais.
//   clique numa janela      foca a janela
//   clique no workspace     vai para ele
//   arrastar uma janela     manda para outro workspace (sem sair da visão geral)
//   clique direito          menu da janela (minimizar, por cima, tela cheia, mover, fechar)
//   Esc ou Super+Tab        fecha
// Abre com:  qs ipc call overview toggle
// As miniaturas usam o protocolo de captura de janelas do Hyprland (ScreencopyView).

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import "../theme"
import "../windowmenu"

Scope {
    id: root

    property bool shown: false
    property int count: 10                      // workspaces mostrados (1..count)
    property int tileH: 170                     // altura de cada miniatura
    // papel de parede de cada monitor (os links que o wallpaper-mode mantém)
    property var wallpapers: ({
        "HDMI-A-2": Quickshell.env("HOME") + "/Pictures/Wallpapers/primary.png",
        "HDMI-A-1": Quickshell.env("HOME") + "/Pictures/Wallpapers/secondary.png"
    })

    property var monitors: ({})                 // nome → { x, y, w, h (lógicos), active }
    property var wsMonitor: ({})                // id do workspace → nome do monitor
    property var clients: []
    property string focusedMonitor: ""
    property int activeWs: 0
    property var dragging: null                 // janela sendo arrastada
    property int dropWs: 0                      // workspace sob o mouse durante o arrasto

    function tileAt(p) {                        // p em coordenadas do grid
        for (let i = 0; i < tiles.count; i++) {
            const t = tiles.itemAt(i)
            if (t && p.x >= t.x && p.x <= t.x + t.width && p.y >= t.y && p.y <= t.y + t.height) return t
        }
        return null
    }

    function strip(a) { return (a || "").toString().replace(/^0x/, "") }

    function handleFor(address) {
        const a = strip(address)
        const list = Hyprland.toplevels.values
        for (let i = 0; i < list.length; i++)
            if (strip(list[i].address) === a) return list[i].wayland
        return null
    }

    function iconFor(cls) {
        const e = DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(cls) : null
        return Quickshell.iconPath(e && e.icon ? e.icon : (cls || "").toLowerCase(), "application-x-executable")
    }

    function pickScreen() {
        const m = Hyprland.focusedMonitor
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++)
            if (m && screens[i].name === m.name) return screens[i]
        return screens[0]
    }

    function open() {
        if (Popups.current) Popups.hide(Popups.current)
        win.screen = pickScreen()
        hideTimer.stop()
        refresh()
        win.visible = true
        shown = true
        Qt.callLater(() => content.forceActiveFocus())
    }
    function close() {
        if (!win.visible) return
        shown = false
        dragging = null
        hideTimer.restart()
    }
    function toggle() { win.visible && shown ? close() : open() }
    function refresh() { dataProc.running = true }

    function dispatch(s) { Hyprland.dispatch(s) }
    function goTo(ws) { close(); dispatch('hl.dsp.focus({ workspace = "' + ws + '" })') }
    function focusWindow(c) { close(); dispatch('hl.dsp.focus({ window = "address:0x' + strip(c.address) + '" })') }
    function moveWindow(c, ws) {
        // move a janela sem trocar de workspace; a visão geral se atualiza em seguida
        dispatch('hl.dsp.focus({ window = "address:0x' + strip(c.address) + '" })')
        dispatch('hl.dsp.window.move({ workspace = "' + ws + '", follow = false })')
        refreshLater.restart()
    }

    IpcHandler {
        target: "overview"
        function toggle(): void { root.toggle() }
        function open(): void { root.open() }
        function close(): void { root.close() }
    }

    Timer { id: hideTimer; interval: 140; onTriggered: win.visible = false }
    Timer { id: refreshLater; interval: 150; onTriggered: root.refresh() }

    Process {
        id: dataProc
        command: ["sh", "-c", 'printf \'{"m":%s,"w":%s,"c":%s}\' "$(hyprctl monitors -j)" "$(hyprctl workspaces -j)" "$(hyprctl clients -j)"']
        stdout: StdioCollector {
            onStreamFinished: {
                let d
                try { d = JSON.parse(text) } catch (e) { return }
                const mons = {}
                for (const m of d.m) {
                    const rot = (m.transform % 2) === 1
                    mons[m.name] = {
                        x: m.x, y: m.y,
                        w: (rot ? m.height : m.width) / m.scale,
                        h: (rot ? m.width : m.height) / m.scale,
                        active: m.activeWorkspace ? m.activeWorkspace.id : 0
                    }
                    if (m.focused) { root.focusedMonitor = m.name; root.activeWs = m.activeWorkspace.id }
                }
                const wsm = {}
                for (const w of d.w) if (w.id > 0) wsm[w.id] = w.monitor
                root.monitors = mons
                root.wsMonitor = wsm
                root.clients = d.c.filter(c => c.mapped !== false && c.workspace && c.workspace.id > 0)
                    .map(c => Object.assign({}, c, { handle: root.handleFor(c.address) }))
            }
        }
    }

    PanelWindow {
        id: win
        visible: false
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-overview"
        WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // menu de janela (clique direito numa miniatura); depois da ação, atualiza a visão geral
        WindowMenu { id: menu; onDone: refreshLater.restart() }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, root.shown ? 0.35 : 0)
            Behavior on color { ColorAnimation { duration: 140 } }
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }

        Rectangle {
            id: content
            width: Math.min(win.width - 64, grid.implicitWidth + 32)
            height: grid.implicitHeight + 32
            anchors.centerIn: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            opacity: root.shown ? 1 : 0
            scale: root.shown ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            focus: true
            Keys.onEscapePressed: root.close()
            MouseArea { anchors.fill: parent }

            Flow {
                id: grid
                anchors.centerIn: parent
                width: Math.min(win.width - 96, implicitW)
                spacing: 14
                // largura natural de uma linha com 5 miniaturas
                readonly property int implicitW: {
                    let w = 0
                    for (let i = 0; i < Math.min(5, tiles.count); i++) { const t = tiles.itemAt(i); if (t) w += t.width + 14 }
                    return Math.max(200, w - 14)
                }

                Repeater {
                    id: tiles
                    model: root.count

                    Item {
                        id: tile
                        required property int index
                        readonly property int ws: index + 1
                        readonly property string monName: root.wsMonitor[ws] || root.focusedMonitor
                        readonly property var mon: root.monitors[monName] || { x: 0, y: 0, w: 16, h: 9, active: 0 }
                        readonly property real k: root.tileH / mon.h
                        readonly property bool isActive: ws === root.activeWs
                        readonly property bool dropTarget: root.dragging !== null && root.dropWs === ws
                        width: Math.round(mon.w * k)
                        height: root.tileH + 22

                        Rectangle {
                            id: screen
                            width: parent.width
                            height: root.tileH
                            radius: Theme.cardRadius
                            color: Theme.crust
                            clip: true
                            border.width: tile.isActive || tile.dropTarget ? 2 : 1
                            border.color: tile.dropTarget ? Theme.green : tile.isActive ? Theme.accent : Theme.border

                            Image {
                                anchors.fill: parent
                                anchors.margins: 1
                                source: root.wallpapers[tile.monName] ? "file://" + root.wallpapers[tile.monName] : ""
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(width * 2, height * 2)
                                asynchronous: true
                                opacity: 0.85
                            }

                            MouseArea {
                                id: hover
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.goTo(tile.ws)
                            }

                            Repeater {
                                model: root.clients.filter(c => c.workspace.id === tile.ws)

                                Rectangle {
                                    id: wnd
                                    required property var modelData
                                    x: (modelData.at[0] - tile.mon.x) * tile.k
                                    y: (modelData.at[1] - tile.mon.y) * tile.k
                                    width: Math.max(8, modelData.size[0] * tile.k)
                                    height: Math.max(8, modelData.size[1] * tile.k)
                                    radius: 4
                                    color: Theme.base
                                    border.width: 1
                                    border.color: wMouse.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.4)
                                    clip: true
                                    opacity: root.dragging && root.dragging.address === modelData.address ? 0.35 : 1

                                    ScreencopyView {
                                        id: shot
                                        anchors.fill: parent
                                        captureSource: root.shown ? wnd.modelData.handle : null
                                        live: false
                                        onCaptureSourceChanged: if (captureSource) captureFrame()
                                    }
                                    IconImage {
                                        anchors.centerIn: parent
                                        visible: !shot.hasContent
                                        implicitSize: Math.min(28, wnd.width * 0.5, wnd.height * 0.5)
                                        source: root.iconFor(wnd.modelData.class)
                                    }

                                    MouseArea {
                                        id: wMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                        property point start
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onPressed: ev => {
                                            start = Qt.point(ev.x, ev.y)
                                            if (ev.button === Qt.RightButton) {
                                                const c = wnd.modelData
                                                menu.show(wnd, ev.x, ev.y, { address: c.address, title: c.title || c.class,
                                                    ws: c.workspace.name, floating: c.floating, pinned: c.pinned, minimized: false })
                                            }
                                        }
                                        onPositionChanged: ev => {
                                            if (!pressed || !(pressedButtons & Qt.LeftButton)) return
                                            if (!root.dragging && Math.hypot(ev.x - start.x, ev.y - start.y) > 6)
                                                root.dragging = wnd.modelData
                                            if (root.dragging) {
                                                const p = mapToItem(win.contentItem, ev.x, ev.y)
                                                ghost.x = p.x - ghost.width / 2
                                                ghost.y = p.y - ghost.height / 2
                                                const t = root.tileAt(mapToItem(grid, ev.x, ev.y))
                                                root.dropWs = t ? t.ws : 0
                                            }
                                        }
                                        onReleased: ev => {
                                            if (ev.button === Qt.RightButton) return
                                            const c = root.dragging
                                            if (!c) { root.focusWindow(wnd.modelData); return }
                                            root.dragging = null
                                            root.dropWs = 0
                                            const t = root.tileAt(mapToItem(grid, ev.x, ev.y))
                                            if (t && t.ws !== c.workspace.id) root.moveWindow(c, t.ws)
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            anchors { top: screen.bottom; topMargin: 4; horizontalCenter: parent.horizontalCenter }
                            text: tile.ws
                            color: tile.isActive ? Theme.accent : Theme.dim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 1
                            font.weight: tile.isActive ? Font.DemiBold : Font.Normal
                        }
                    }
                }
            }
        }

        // janela sendo arrastada: segue o mouse
        Rectangle {
            id: ghost
            visible: root.dragging !== null
            width: ghostRow.implicitWidth + 20
            height: 34
            radius: Theme.buttonRadius
            color: Theme.hover
            border.color: Theme.accent
            border.width: 1
            RowLayout {
                id: ghostRow
                anchors.centerIn: parent
                spacing: 6
                IconImage { implicitSize: 18; source: root.dragging ? root.iconFor(root.dragging.class) : "" }
                Text {
                    text: root.dragging ? root.dragging.title : ""
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                    Layout.maximumWidth: 260
                    elide: Text.ElideRight
                }
            }
        }
    }
}
