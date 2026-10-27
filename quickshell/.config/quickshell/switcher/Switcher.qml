// Switcher.qml — Alt+Tab com prévia ao vivo das janelas, no visual da barra.
//
// Atalhos (binds.lua):
//   Alt+Tab        qs ipc call switcher next     abre / vai para a próxima janela
//   Alt+Shift+Tab  qs ipc call switcher prev     volta uma
//   soltar o Alt   qs ipc call switcher commit   a escolhida TROCA de lugar e tamanho com a atual
// Com ele aberto: ←/→ ou Tab navegam, Enter troca, Space só foca (sem trocar), Esc cancela,
// clique troca (Shift+clique só foca). Flutuantes, minimizadas e scratchpad: só foca.
// As janelas vêm em ordem de uso (a atual por último na volta, a anterior já selecionada),
// de todos os workspaces, inclusive o scratchpad.
// A prévia usa o protocolo de captura de janelas do Hyprland (ScreencopyView).

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import "../theme"
import "../minimize"

Scope {
    id: root

    property bool shown: false
    property var windows: []          // [{ address, title, cls, ws, handle }]
    property int index: 0
    property int pendingSteps: 0      // Tabs apertados antes da lista chegar

    readonly property int cardW: 260
    readonly property int previewW: 240
    readonly property int previewH: 150

    function strip(a) { return (a || "").toString().replace(/^0x/, "") }

    function handleFor(address) {
        const a = strip(address)
        const list = Hyprland.toplevels.values
        for (let i = 0; i < list.length; i++)
            if (strip(list[i].address) === a) return list[i].wayland
        return null
    }

    function pickScreen() {
        const m = Hyprland.focusedMonitor
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++)
            if (m && screens[i].name === m.name) return screens[i]
        return screens[0]
    }

    function step(d) {
        if (!shown) {
            if (Popups.current) Popups.hide(Popups.current)
            win.screen = pickScreen()
            windows = []
            pendingSteps = d
            hideTimer.stop()
            clientsProc.running = true
            win.visible = true
            shown = true
            Qt.callLater(() => box.forceActiveFocus())
            return
        }
        if (windows.length === 0) { pendingSteps += d; return }
        index = (index + d + windows.length) % windows.length
    }

    // Soltar o Alt: a janela escolhida TROCA de lugar e tamanho com a atual (como "trazer para cá").
    // Space: só foca, sem trocar. Janelas flutuantes, minimizadas ou sem janela atual: só foca.
    property bool swapOnCommit: true

    function commit(focusOnly) {
        if (!shown) return
        const w = windows[index]
        const cur = windows.length > 0 && windows[0].current ? windows[0] : null
        close()
        if (!w) return
        // minimizada: devolve ao workspace de origem
        if (w.ws === "Minimized") { Minimized.restore(w.address); return }
        const target = '"address:0x' + strip(w.address) + '"'
        if (swapOnCommit && !focusOnly && cur && cur.address !== w.address
                && !cur.floating && !w.floating && !cur.special && !w.special) {
            // a atual vai para o lugar da escolhida e vice-versa; o foco fica na escolhida
            Hyprland.dispatch('hl.dsp.window.swap({ target = ' + target + ' })')
        }
        Hyprland.dispatch('hl.dsp.focus({ window = ' + target + ' })')
    }

    function close() {
        if (!win.visible) return
        shown = false
        hideTimer.restart()
    }

    IpcHandler {
        target: "switcher"
        function next(): void { root.step(1) }
        function prev(): void { root.step(-1) }
        function commit(): void { root.commit(false) }
        function focus(): void { root.commit(true) }
        function cancel(): void { root.close() }
    }

    Timer { id: hideTimer; interval: 120; onTriggered: { win.visible = false; root.windows = [] } }

    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = []
                try { list = JSON.parse(text) } catch (e) {}
                list = list.filter(c => c.mapped !== false && c.hidden !== true && c.workspace && c.workspace.id !== 0)
                list.sort((a, b) => (a.focusHistoryID ?? 99) - (b.focusHistoryID ?? 99))
                root.windows = list.map(c => ({
                    address: c.address,
                    title: c.title || c.class || "",
                    cls: c.class || "",
                    floating: c.floating === true,
                    special: c.workspace.name.startsWith("special:"),
                    current: c.focusHistoryID === 0,
                    ws: c.workspace.name === "special:minimized" ? "Minimized"
                        : c.workspace.name.startsWith("special:") ? "Scratchpad" : String(c.workspace.name),
                    handle: root.handleFor(c.address)
                }))
                const n = root.windows.length
                if (n === 0) { root.close(); return }
                // primeiro Tab: a janela anterior (a atual é a 0)
                const steps = root.pendingSteps
                root.pendingSteps = 0
                root.index = ((steps > 0 ? Math.min(1, n - 1) + steps - 1 : steps) % n + n) % n
            }
        }
    }

    function iconFor(cls) {
        const e = DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(cls) : null
        return Quickshell.iconPath(e && e.icon ? e.icon : cls.toLowerCase(), "application-x-executable")
    }

    PanelWindow {
        id: win
        visible: false
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-switcher"
        WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, root.shown ? 0.25 : 0)
            Behavior on color { ColorAnimation { duration: 120 } }
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }

        Rectangle {
            id: box
            readonly property int maxCards: Math.max(1, Math.floor((win.width - 80) / (root.cardW + 10)))
            width: Math.max(root.cardW, Math.min(root.windows.length, maxCards) * (root.cardW + 10) - 10) + 24
            height: root.previewH + 104
            anchors.centerIn: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            opacity: root.shown ? 1 : 0
            scale: root.shown ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 120 } }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

            focus: true
            Keys.onPressed: ev => {
                if (ev.key === Qt.Key_Escape) { root.close(); ev.accepted = true }
                else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) { root.commit(false); ev.accepted = true }
                else if (ev.key === Qt.Key_Space) { root.commit(true); ev.accepted = true }
                else if (ev.key === Qt.Key_Right || ev.key === Qt.Key_Tab) { root.step(1); ev.accepted = true }
                else if (ev.key === Qt.Key_Left || ev.key === Qt.Key_Backtab) { root.step(-1); ev.accepted = true }
            }
            // soltar o Alt também confirma (além do atalho de soltura do Hyprland)
            Keys.onReleased: ev => { if (ev.key === Qt.Key_Alt) { root.commit(false); ev.accepted = true } }

            Text {
                id: hint
                anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 8 }
                text: root.swapOnCommit ? "Release Alt  Swap Places   ·   Space  Focus Only   ·   Esc  Cancel"
                                        : "Release Alt  Focus   ·   Esc  Cancel"
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 3
            }

            ListView {
                id: list
                anchors { left: parent.left; right: parent.right; top: parent.top; bottom: hint.top
                          leftMargin: 12; rightMargin: 12; topMargin: 12; bottomMargin: 6 }
                orientation: ListView.Horizontal
                spacing: 10
                model: root.windows
                currentIndex: root.index
                highlightMoveDuration: 120
                preferredHighlightBegin: width / 2 - root.cardW / 2
                preferredHighlightEnd: width / 2 + root.cardW / 2
                highlightRangeMode: ListView.ApplyRange
                interactive: false
                clip: true

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.index
                    width: root.cardW
                    height: list.height
                    radius: Theme.cardRadius
                    color: current ? Theme.hover : "transparent"
                    border.width: current ? 2 : 0
                    border.color: Theme.accent

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.index = card.index
                        onClicked: mouse => { root.index = card.index; root.commit(mouse.modifiers & Qt.ShiftModifier) }
                    }

                    Item {
                        id: frame
                        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 10 }
                        width: root.previewW
                        height: root.previewH

                        ScreencopyView {
                            id: shot
                            anchors.centerIn: parent
                            captureSource: root.shown ? card.modelData.handle : null
                            live: true
                            constraintSize: Qt.size(frame.width, frame.height)
                            width: hasContent ? implicitWidth : 0
                            height: hasContent ? implicitHeight : 0
                            layer.enabled: true
                        }
                        // sem prévia (ainda carregando ou sem captura): ícone grande
                        IconImage {
                            anchors.centerIn: parent
                            visible: !shot.hasContent
                            implicitSize: 56
                            source: root.iconFor(card.modelData.cls)
                        }
                    }

                    RowLayout {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
                        spacing: 6
                        IconImage {
                            implicitSize: 18
                            source: root.iconFor(card.modelData.cls)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: card.modelData.title
                            color: card.current ? Theme.fg : Theme.dim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideRight
                        }
                        Text {
                            text: card.modelData.ws
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 3
                        }
                    }
                }
            }
        }
    }
}
