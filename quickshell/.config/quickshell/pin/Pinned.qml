// Pinned.qml — "sempre por cima": deixa uma janela flutuando, por cima e em todos os workspaces.
//
// Super+Shift+P (qs ipc call pin toggle) na janela em foco:
//   - não fixada: se estiver no tiling, solta (flutuante) e centraliza; depois fixa (pin)
//   - já fixada: tira o pin e, se fomos nós que soltamos, volta para o tiling
// A lista de fixadas vem do Hyprland (pinned: true), então o indicador da barra
// continua certo mesmo se a barra reiniciar.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Singleton {
    id: root

    property var windows: []            // [{ address, title, cls }]
    property var floatedByUs: ({})      // endereço → true (para voltar ao tiling ao desafixar)

    function strip(a) { return (a || "").toString().replace(/^0x/, "") }
    function sel(a) { return '"address:0x' + strip(a) + '"' }
    function dispatch(s) { Hyprland.dispatch(s) }

    function toggleActive() { activeProc.running = true }

    function unpin(a, floating) {
        dispatch('hl.dsp.window.pin({ action = "toggle", window = ' + sel(a) + ' })')
        if (floatedByUs[a] && floating !== false) dispatch('hl.dsp.window.float({ action = "toggle", window = ' + sel(a) + ' })')
        const o = Object.assign({}, floatedByUs); delete o[a]; floatedByUs = o
        refreshSoon.restart()
    }

    function pin(a, floating) {
        if (!floating) {
            dispatch('hl.dsp.window.float({ action = "toggle", window = ' + sel(a) + ' })')
            dispatch('hl.dsp.window.center({ window = ' + sel(a) + ' })')
            const o = Object.assign({}, floatedByUs); o[a] = true; floatedByUs = o
        }
        dispatch('hl.dsp.window.pin({ action = "toggle", window = ' + sel(a) + ' })')
        dispatch('hl.dsp.window.alter_zorder({ mode = "top", window = ' + sel(a) + ' })')
        refreshSoon.restart()
    }

    function unpinAll() { for (const w of windows) unpin(w.address, true) }

    function refresh() { if (!clientsProc.running) clientsProc.running = true }

    Process {
        id: activeProc
        command: ["hyprctl", "activewindow", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let w
                try { w = JSON.parse(text) } catch (e) { return }
                if (!w || !w.address) return
                const a = root.strip(w.address)
                if (w.pinned) root.unpin(a, w.floating)
                else root.pin(a, w.floating)
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
                root.windows = list.filter(c => c.pinned).map(c => ({
                    address: root.strip(c.address), title: c.title || c.class || "", cls: c.class || ""
                }))
            }
        }
    }

    Timer { id: refreshSoon; interval: 150; onTriggered: root.refresh() }
    Component.onCompleted: refresh()

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const n = event.name
            if (n === "pin" || n === "closewindow" || n === "openwindow" || n === "changefloatingmode")
                refreshSoon.restart()
        }
    }

    IpcHandler {
        target: "pin"
        function toggle(): void { root.toggleActive() }
        function unpinAll(): void { root.unpinAll() }
    }
}
