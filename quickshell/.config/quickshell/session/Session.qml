// Session.qml — restaurar a sessão: reabre os apps do último uso, cada um no workspace dele.
//
// Salvar: a cada janela aberta/movida (e a cada 2 min) grava ~/.local/state/quickshell/session.json
// com { class, workspace } de cada janela. Fechar janela só salva 10 s depois, para que o
// fechamento em massa do logout/desligamento não apague a sessão.
// Restaurar: ao iniciar a barra sem nenhuma janela aberta (login), pergunta numa notificação
// ("Restore" / "Dismiss"). Cada app é aberto pelo .desktop dele e, quando a janela aparece,
// vai para o workspace salvo.
//
// Ficam de fora: jogos, diálogos, PiP, portais e janelas sem app conhecido (sem .desktop).
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Singleton {
    id: root

    property var skipClasses: ["wow.exe", "xdg-desktop-portal-gtk", "steam_app_default", "gamescope"]
    readonly property string path: Quickshell.env("HOME") + "/.local/state/quickshell/session.json"

    property bool ready: false          // só salva depois de decidir se restaura (não sobrescreve antes)
    property var saved: []              // última sessão lida do disco
    property var pending: []            // [{ cls, ws }] esperando a janela abrir

    function entryFor(cls) {
        if (!cls) return null
        const e = DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(cls) : DesktopEntries.byId(cls)
        return e || null
    }

    function keep(c) {
        if (!c.class || !c.workspace || !c.mapped) return false
        if (skipClasses.includes(c.class.toLowerCase())) return false
        if (c.workspace.name === "special:minimized") return true
        if (/^Picture[- ]in[- ][Pp]icture$/.test(c.title || "")) return false
        return entryFor(c.class) !== null
    }

    // ---------- salvar ----------
    Process {
        id: snapProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = []
                try { list = JSON.parse(text) } catch (e) { return }
                const items = list.filter(c => root.keep(c))
                    .sort((a, b) => a.workspace.id - b.workspace.id || a.at[0] - b.at[0] || a.at[1] - b.at[1])
                    .map(c => ({ cls: c.class, ws: c.workspace.name }))
                if (!root.ready) {
                    // primeira leitura: nenhuma janela = login → oferece restaurar
                    root.ready = true
                    if (items.length === 0 && root.saved.length > 0) root.offer()
                    return
                }
                if (items.length === 0) return      // nunca grava sessão vazia
                Quickshell.execDetached(["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s" "$1" > "$2"',
                                         "sh", JSON.stringify({ time: Date.now(), windows: items }), root.path])
            }
        }
    }
    function snapshot() { if (!snapProc.running) snapProc.running = true }

    Timer { id: saveSoon; interval: 3000; onTriggered: root.snapshot() }
    Timer { id: saveAfterClose; interval: 10000; onTriggered: root.snapshot() }
    Timer { interval: 120000; running: root.ready; repeat: true; onTriggered: root.snapshot() }

    FileView {
        path: root.path
        onLoaded: {
            try {
                const d = JSON.parse(text())
                // só oferece sessões da última semana
                root.saved = (Date.now() - (d.time || 0) < 7 * 86400000) ? (d.windows || []) : []
            } catch (e) { root.saved = [] }
            firstLook.restart()
        }
        onLoadFailed: firstLook.restart()
    }
    // espera o Hyprland e os apps de inicialização (exec-once) antes de olhar
    Timer { id: firstLook; interval: 6000; onTriggered: root.snapshot() }

    // ---------- restaurar ----------
    function offer() {
        const names = []
        for (const w of saved) {
            const e = entryFor(w.cls)
            const n = e ? e.name : w.cls
            if (!names.includes(n)) names.push(n)
        }
        askProc.command = ["notify-send", "-a", "Session", "-i", "view-refresh", "-t", "30000",
                           "-A", "restore=Restore", "-A", "dismiss=Dismiss",
                           "Restore Session?", names.slice(0, 6).join(", ") + (names.length > 6 ? "…" : "")]
        askProc.running = true
    }
    Process {
        id: askProc
        stdout: StdioCollector { onStreamFinished: if (text.trim() === "restore") root.restore() }
    }

    function restore() {
        pending = saved.slice()
        const launched = {}
        for (const w of saved) {
            const e = entryFor(w.cls)
            if (!e) continue
            // várias janelas do mesmo app: abre uma vez por janela (cada terminal, por exemplo),
            // menos navegadores, que já reabrem as próprias janelas sozinhos
            if (launched[w.cls] && /brave|chrom|firefox|zen|vivaldi/i.test(w.cls)) continue
            launched[w.cls] = (launched[w.cls] || 0) + 1
            if (e.runInTerminal) Quickshell.execDetached(["foot", "-e"].concat(e.command))
            else e.execute()
        }
        giveUp.restart()
    }
    Timer { id: giveUp; interval: 90000; onTriggered: root.pending = [] }

    // janela nova de um app pendente → vai para o workspace salvo
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            const n = event.name
            if (n === "openwindow") {
                const parts = event.data.split(",")
                const addr = parts[0], cls = parts[2]
                const i = root.pending.findIndex(p => p.cls === cls)
                if (i >= 0) {
                    const ws = root.pending[i].ws
                    const rest = root.pending.slice(); rest.splice(i, 1); root.pending = rest
                    Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + ws + '", follow = false, window = "address:0x'
                                      + addr.replace(/^0x/, "") + '" })')
                }
                saveSoon.restart()
            } else if (n === "movewindow" || n === "movewindowv2") {
                saveSoon.restart()
            } else if (n === "closewindow") {
                saveAfterClose.restart()
            }
        }
    }

    IpcHandler {
        target: "session"
        function restore(): void { root.restore() }
        function save(): void { root.snapshot() }
    }
}
