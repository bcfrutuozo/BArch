pragma Singleton

// Notifs.qml — servidor de notificações da barra (substitui o swaync).
// Recebe as notificações de todos os apps (inclusive Brave/Chromium, que usam as notificações
// nativas do sistema), mostra os balões (NotificationPopups) e guarda o histórico (NotificationCenter).
//
//   popups   entradas visíveis como balão agora
//   list     histórico: TODAS as notificações, até você limpar (× na central ou Clear All).
//            Fica salvo em ~/.local/state/quickshell/notifications.json (sobrevive a reinícios).
//   dnd      não perturbe: nenhum balão nem som; tudo vai direto para o histórico
//   som      cada notificação toca um som (fora do não perturbe). Respeita o app quando ele
//            pede silêncio (suppress-sound) ou manda o próprio som (sound-file / sound-name).
//            Precisa do pacote sound-theme-freedesktop; troque os arquivos em soundNormal/soundCritical.
//
// Cada entrada do histórico é uma cópia própria da notificação. Enquanto o app mantém a
// notificação aberta, a entrada também guarda a original (notif) para a imagem e os botões;
// quando o app a fecha, a cópia continua no histórico.
//
// IPC:  qs ipc call notifs dnd | clear | test | dndSet <bool> | dndStatus | post <title> <body> <urgency> <app>
//       (as que respondem JSON são usadas pelo barch, em ~/.local/bin)

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Notifications

Singleton {
    id: root

    property bool dnd: false
    property var popups: []                  // entradas em balão
    property var list: []                    // histórico, mais antigas primeiro
    readonly property int count: list.length
    property int maxHistory: 200

    property bool soundEnabled: true
    property real soundVolume: 1.0          // volume do som (1.0 = normal; até ~2.0 amplifica)
    property string soundDir: "/usr/share/sounds/freedesktop/stereo/"
    property string soundNormal: soundDir + "message-new-instant.oga"
    property string soundCritical: soundDir + "complete.oga"
    property real lastSound: 0

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/quickshell"
    readonly property string dndPath: stateDir + "/dnd"
    readonly property string historyPath: stateDir + "/notifications.json"

    // ---------- entrada do histórico ----------
    Component {
        id: entryComp
        QtObject {
            property QtObject notif: null     // a notificação original, enquanto o app a mantém
            property int nid: 0
            property string appName: ""
            property string appIcon: ""
            property string desktopEntry: ""
            property string summary: ""
            property string body: ""
            property string image: ""         // imagem enviada pelo app (só vale enquanto ela existe)
            property bool critical: false
            property bool low: false
            property real expireTimeout: 0
            property real time: Date.now()
        }
    }

    function makeEntry(props) { return entryComp.createObject(root, props) }

    function serialize() {
        return JSON.stringify(list.map(e => ({
            appName: e.appName, appIcon: e.appIcon, desktopEntry: e.desktopEntry,
            summary: e.summary, body: e.body, critical: e.critical, time: e.time
        })))
    }
    Timer { id: saveTimer; interval: 800; onTriggered: root.writeFile(root.historyPath, root.serialize()) }
    function save() { saveTimer.restart() }

    function writeFile(path, content) {
        Quickshell.execDetached(["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1"',
                                 "sh", path, content])
    }

    FileView {
        path: root.historyPath
        onLoaded: {
            try {
                const saved = JSON.parse(text())
                root.list = saved.map(s => root.makeEntry(s)).concat(root.list)
            } catch (e) {}
        }
    }

    // ---------- servidor ----------
    NotificationServer {
        id: server
        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyHyperlinksSupported: false
        bodyImagesSupported: false
        actionsSupported: true
        actionIconsSupported: false
        imageSupported: true

        onNotification: n => {
            n.tracked = true

            const e = root.makeEntry({
                notif: n, nid: n.id, appName: n.appName, appIcon: n.appIcon, desktopEntry: n.desktopEntry,
                summary: n.summary, body: n.body, image: n.image,
                critical: n.urgency === NotificationUrgency.Critical,
                low: n.urgency === NotificationUrgency.Low,
                expireTimeout: n.expireTimeout, time: Date.now()
            })

            // o app pode atualizar a notificação (ex.: progresso, nova mensagem na mesma conversa)
            n.summaryChanged.connect(() => { e.summary = n.summary; root.save() })
            n.bodyChanged.connect(() => { e.body = n.body; root.save() })
            n.imageChanged.connect(() => e.image = n.image)
            // quando o app (ou um clique) fecha a notificação, a cópia fica no histórico
            n.closed.connect(() => { e.notif = null; e.image = ""; root.hidePopup(e) })

            root.post(e, n.transient, n.hints || {})
        }
    }

    // Mostra uma entrada: histórico, balão e som. Usada pelo servidor (DBus) e pelo IPC (barch notify).
    // "transient" (ex.: aviso de volume) só aparece em balão, não vai para o histórico.
    function post(e, transient, hints) {
        if (!transient) {
            let l = list.concat([e])
            if (l.length > maxHistory) l = l.slice(l.length - maxHistory)
            list = l
            save()
        }
        if (!dnd) {
            popups = popups.concat([e])
            playSound(e.critical, hints)
        }
        console.log("[notifs]", e.appName, "|", e.summary, "| dnd:", dnd, "| popups:", popups.length)
    }

    // ---------- som ----------
    function playSound(critical, hints) {
        if (!soundEnabled) return
        const h = hints || {}
        if (h["suppress-sound"]) return
        const now = Date.now()
        if (now - lastSound < 400) return          // várias de uma vez: um som só
        lastSound = now

        let file = h["sound-file"] || ""
        if (file.startsWith("file://")) file = file.slice(7)
        if (!file && h["sound-name"])
            file = soundDir + h["sound-name"] + ".oga"
        if (!file) file = critical ? soundCritical : soundNormal
        Quickshell.execDetached(["sh", "-c", '[ -f "$1" ] && exec pw-play --volume "$2" "$1"',
                                 "sh", file, String(soundVolume)])
    }

    // ---------- ações ----------
    // tira o balão da tela; continua no histórico
    function hidePopup(e) {
        if (popups.indexOf(e) >= 0) console.log("[notifs] hide popup:", e.summary)
        if (popups.indexOf(e) >= 0) popups = popups.filter(p => p !== e)
    }

    // remove do histórico (× na central)
    function remove(e) {
        hidePopup(e)
        list = list.filter(x => x !== e)
        if (e.notif) e.notif.dismiss()
        save()
    }

    function clearAll() {
        for (const e of list) if (e.notif) e.notif.dismiss()
        popups = []
        list = []
        save()
    }

    // tempo do balão na tela (ms); 0 = fica até você fechar
    function timeoutFor(e) {
        if (e.critical) return 0
        if (e.expireTimeout > 0) return Math.max(e.expireTimeout, 2000)
        return e.low ? 3500 : 6000
    }

    function timeText(e) {
        const m = Math.floor((Date.now() - e.time) / 60000)
        if (m < 1) return "now"
        if (m < 60) return m + "m"
        const h = Math.floor(m / 60)
        return h < 24 ? h + "h" : Math.floor(h / 24) + "d"
    }

    // ícone: a imagem que veio na notificação, o ícone do app, ou o do .desktop
    function iconFor(e) {
        if (e.image) return e.image
        const ic = e.appIcon
        if (ic) return ic.startsWith("/") ? "file://" + ic
                     : ic.startsWith("file://") || ic.startsWith("image://") ? ic
                     : Quickshell.iconPath(ic, true)
        if (e.desktopEntry) {
            const d = DesktopEntries.byId(e.desktopEntry)
            if (d && d.icon) return Quickshell.iconPath(d.icon, true)
        }
        return ""
    }

    function actionsOf(e) {
        const out = []
        if (!e.notif) return out
        for (let i = 0; i < e.notif.actions.length; i++) {
            const a = e.notif.actions[i]
            if (a.identifier !== "default" && a.text !== "") out.push(a)
        }
        return out
    }

    // clique: avisa o app (o navegador troca para a aba certa) e traz a janela dele para a frente.
    // A entrada continua no histórico.
    function activate(e) {
        if (e.notif) {
            const acts = e.notif.actions
            for (let i = 0; i < acts.length; i++)
                if (acts[i].identifier === "default") { acts[i].invoke(); break }
        }
        hidePopup(e)
        focusApp(e)
    }

    function invokeAction(e, action) {
        action.invoke()
        hidePopup(e)
        focusApp(e)
    }

    property string focusKey: ""
    function focusApp(e) {
        const key = (e.desktopEntry || e.appName || "").toLowerCase()
        if (!key) return
        focusKey = key
        focusProc.running = true
    }
    Process {
        id: focusProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const key = root.focusKey
                    const short = key.split(/[\s.-]/)[0]          // "brave-browser" -> "brave"
                    const clients = JSON.parse(text)
                    const c = clients.find(c => (c.class || "").toLowerCase() === key)
                           || clients.find(c => (c.class || "").toLowerCase().includes(key))
                           || clients.find(c => short.length > 2 && (c.class || "").toLowerCase().includes(short))
                    if (c) Hyprland.dispatch('hl.dsp.focus({ window = "address:' + c.address + '" })')
                } catch (err) {}
            }
        }
    }

    // ---------- não perturbe (lembrado entre reinícios) ----------
    FileView {
        path: root.dndPath
        onLoaded: root.dnd = text().trim() === "1"
    }
    function setDnd(on) {
        dnd = on
        if (on) popups = []
        writeFile(dndPath, on ? "1" : "0")
    }

    // relógio para atualizar os "5m", "2h"…
    property int tick: 0
    Timer { interval: 30000; running: root.count > 0; repeat: true; onTriggered: root.tick++ }

    IpcHandler {
        target: "notifs"
        function dnd(): string { root.setDnd(!root.dnd); return "dnd: " + (root.dnd ? "on" : "off") }
        function clear(): void { root.clearAll() }
        // quantas notificações chegaram desde <segundos desde 1970> (a tela de bloqueio usa)
        function awayCount(since: string): string {
            const t = Number(since) * 1000
            return String(root.list.filter(e => e.time >= t).length)
        }
        function dndSet(on: bool): string { root.setDnd(on); return JSON.stringify({ ok: true, dnd: root.dnd }) }
        function dndStatus(): string { return JSON.stringify({ ok: true, dnd: root.dnd }) }
        // notificação da própria barra, sem passar pelo DBus (barch notify). urgency: low | normal | critical
        function post(summary: string, body: string, urgency: string, app: string): string {
            if (summary === "") return JSON.stringify({ ok: false, error: "empty title" })
            if (urgency !== "low" && urgency !== "normal" && urgency !== "critical")
                return JSON.stringify({ ok: false, error: "urgency must be low, normal or critical" })
            root.post(root.makeEntry({
                appName: app || "barch", summary: summary, body: body,
                critical: urgency === "critical", low: urgency === "low", time: Date.now()
            }), false, {})
            return JSON.stringify({ ok: true, dnd: root.dnd })
        }
        function test(): void {
            Quickshell.execDetached(["notify-send", "-a", "Quickshell", "-i", "dialog-information",
                                     "Test notification", "This is how notifications look now."])
        }
    }
}
