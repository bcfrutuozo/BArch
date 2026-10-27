// Minimized.qml — "minimizar" janelas no Hyprland (que não tem isso de fábrica).
//
// Minimizar = mandar a janela para o workspace especial "minimized", que nunca é mostrado,
// guardando o workspace de onde ela saiu (em ~/.local/state/quickshell/minimized.json).
// Restaurar = devolver a janela para esse mesmo workspace (em qualquer monitor) e focá-la.
// A lista vem do próprio Hyprland (janelas no workspace especial), então sobrevive a
// reinícios da barra.
//
// IPC (binds.lua):
//   qs ipc call minimize window        minimiza a janela em foco   (Super+M)
//   qs ipc call minimize restoreLast   restaura a última minimizada (Super+Shift+M)
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Singleton {
    id: root

    readonly property string special: "special:minimized"
    property var windows: []            // [{ address, title, cls, ws }] — mais recente por último
    property var order: []              // endereços na ordem em que foram minimizados
    property var origins: ({})          // endereço → workspace de onde saiu
    readonly property string statePath: Quickshell.env("HOME") + "/.local/state/quickshell/minimized.json"

    function strip(a) { return (a || "").toString().replace(/^0x/, "") }
    function dispatch(s) { Hyprland.dispatch(s) }
    function sel(a) { return '"address:0x' + strip(a) + '"' }

    function saveOrigins() {
        Quickshell.execDetached(["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s" "$1" > "$2"',
                                 "sh", JSON.stringify(origins), statePath])
    }

    function minimizeActive() { activeProc.running = true }

    function restore(address) {
        const a = strip(address)
        const ws = origins[a]
        if (ws !== undefined) moveBack(a, ws)
        else { currentProc.target = a; currentProc.running = true }   // sem origem: workspace atual
    }

    function moveBack(a, ws) {
        dispatch('hl.dsp.window.move({ workspace = "' + ws + '", window = ' + sel(a) + ' })')
        dispatch('hl.dsp.focus({ window = ' + sel(a) + ' })')
        const o = Object.assign({}, origins); delete o[a]; origins = o
        saveOrigins()
        refreshSoon.restart()
    }

    function restoreLast() {
        if (windows.length > 0) restore(windows[windows.length - 1].address)
    }

    function refresh() { if (!clientsProc.running) clientsProc.running = true }

    FileView {
        path: root.statePath
        onLoaded: { try { root.origins = JSON.parse(text()) || {} } catch (e) { root.origins = {} } }
    }

    // janela em foco: guarda o workspace dela e manda para o especial
    Process {
        id: activeProc
        command: ["hyprctl", "activewindow", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let w
                try { w = JSON.parse(text) } catch (e) { return }
                if (!w || !w.address || !w.workspace) return
                if (w.workspace.name === root.special) return
                const a = root.strip(w.address)
                const o = Object.assign({}, root.origins)
                o[a] = w.workspace.name              // nome cobre normais ("3") e especiais ("special:magic")
                root.origins = o
                root.saveOrigins()
                root.dispatch('hl.dsp.window.move({ workspace = "' + root.special + '", follow = false, window = ' + root.sel(a) + ' })')
                refreshSoon.restart()
            }
        }
    }

    Process {
        id: currentProc
        property string target: ""
        command: ["hyprctl", "activeworkspace", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let ws = "1"
                try { ws = String(JSON.parse(text).id) } catch (e) {}
                root.moveBack(currentProc.target, ws)
            }
        }
    }

    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = []
                try { list = JSON.parse(text) } catch (e) { return }
                const mine = list.filter(c => c.workspace && c.workspace.name === root.special)
                const addrs = mine.map(c => root.strip(c.address))
                // mantém a ordem de minimização; novas vão para o fim
                const ord = root.order.filter(a => addrs.includes(a)).concat(addrs.filter(a => !root.order.includes(a)))
                root.order = ord
                root.windows = ord.map(a => {
                    const c = mine.find(x => root.strip(x.address) === a)
                    return { address: a, title: c.title || c.class || "", cls: c.class || "", ws: root.origins[a] || "" }
                })
                // esquece origens de janelas que já fecharam
                const all = list.map(c => root.strip(c.address))
                const kept = {}
                let changed = false
                for (const k in root.origins) { if (all.includes(k)) kept[k] = root.origins[k]; else changed = true }
                if (changed && list.length > 0) { root.origins = kept; root.saveOrigins() }
            }
        }
    }

    Timer { id: refreshSoon; interval: 150; onTriggered: root.refresh() }
    Component.onCompleted: refresh()

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const n = event.name
            if (n === "openwindow" || n === "closewindow" || n === "movewindow" || n === "movewindowv2")
                refreshSoon.restart()
        }
    }

    IpcHandler {
        target: "minimize"
        function window(): void { root.minimizeActive() }
        function restoreLast(): void { root.restoreLast() }
    }
}
