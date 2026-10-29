// Vpn.qml — estado da VPN (Private Internet Access por WireGuard, pia.sh nesta pasta),
// compartilhado pelo Control Center (blocos VPN e VPN Region), pelo indicador da barra
// (VpnWidget) e pelo barch (IPC "vpn"). O script faz tudo como usuário comum, via um perfil
// do NetworkManager que pertence ao usuário; aqui só se chama o script e se lê o estado.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string script: Quickshell.shellDir + "/vpn/pia.sh"

    property string state: "disconnected"   // unconfigured | disconnected | connecting | connected
    property string error: ""
    property string preferred: "auto"       // região escolhida (id) ou "auto"
    property string region: ""              // o túnel atual (ou o que está subindo)
    property string regionName: ""
    property string country: ""
    property string ip: ""
    property real since: 0                  // epoch, s
    property bool auto: false               // a região atual veio do "auto"
    property bool busy: false               // connect/disconnect rodando
    property var regions: []                // [{id, name, country, geo, pf, auto, latency}]
    property bool measuring: false

    signal chooseRegion()                   // "Change region" fora do Control Center: ele abre a lista

    readonly property bool available: state !== "unconfigured"
    readonly property bool connected: state === "connected"
    readonly property bool connecting: state === "connecting" || (busy && !connected)
    readonly property bool active: connected || connecting

    function regionLabel(id) {
        if (!id || id === "auto") return "Auto"
        const r = regions.find(x => x.id === id)
        return r ? r.name : id
    }
    function ms(latency) { return latency === null || latency === undefined ? "" : Math.round(latency * 1000) + " ms" }

    function up(region) {
        if (busy) return
        busy = true; error = ""
        action.command = ["bash", script, "connect"].concat(region ? [region] : [])
        action.running = true
    }
    function down() {
        if (busy) return
        busy = true
        action.command = ["bash", script, "disconnect"]
        action.running = true
    }
    function toggle() { if (active) down(); else up("") }
    function setPreferred(id) {
        preferred = id
        Quickshell.execDetached(["bash", script, "region", id])
        if (active) up(id)                   // troca a região do túnel atual
    }
    function refresh() { if (!statusProc.running) statusProc.running = true }
    function loadRegions() { if (!regionsProc.running) regionsProc.running = true }
    function measure() {                     // relê as latências (o que o "auto" usa) e a lista
        if (measuring) return
        measuring = true
        measureProc.running = true
    }

    Process {
        id: action
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.error = text.trim().replace(/^pia: /, "") }
        onExited: { root.busy = false; root.refresh() }
    }
    Process {
        id: statusProc
        command: ["bash", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let s
                try { s = JSON.parse(text) } catch (e) { return }
                root.state = s.state || "disconnected"
                root.preferred = s.preferred || "auto"
                root.region = s.region || ""
                root.regionName = s.name || ""
                root.country = s.country || ""
                root.ip = s.ip || ""
                root.since = s.since || 0
                root.auto = s.auto === true
                if (s.error && !root.busy) root.error = s.error
                if (root.connected) root.error = ""
            }
        }
    }
    Process {
        id: regionsProc
        command: ["bash", root.script, "regions"]
        stdout: StdioCollector { onStreamFinished: { try { root.regions = JSON.parse(text) } catch (e) {} } }
    }
    Process {
        id: measureProc
        command: ["bash", "-c", 'bash "$0" latency >/dev/null 2>&1; bash "$0" regions', root.script]
        stdout: StdioCollector { onStreamFinished: { try { root.regions = JSON.parse(text) } catch (e) {} } }
        onExited: root.measuring = false
    }

    // estado a cada 5 s; a cada segundo enquanto conecta
    Timer { interval: root.connecting ? 1000 : 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Component.onCompleted: loadRegions()

    // ---- IPC (barch vpn ...) ----
    function status() {
        return { ok: true, state: state, connected: connected, preferred: preferred, region: region, name: regionName,
                 country: country, ip: ip, since: since, auto: auto, error: error }
    }
    IpcHandler {
        target: "vpn"
        function status(): string { root.refresh(); return JSON.stringify(root.status()) }
        function up(region: string): string {
            if (!root.available) return JSON.stringify({ ok: false, error: "no PIA credentials in ~/.config/pia/credentials" })
            root.up(region)
            return JSON.stringify(root.status())
        }
        function down(): string { root.down(); return JSON.stringify(root.status()) }
        function toggle(): string { root.toggle(); return JSON.stringify(root.status()) }
        function region(id: string): string {
            if (id !== "auto" && !root.regions.find(x => x.id === id))
                return JSON.stringify({ ok: false, error: "unknown region: " + id + " (barch vpn regions)" })
            root.setPreferred(id)
            return JSON.stringify(root.status())
        }
        function regions(): string { return JSON.stringify({ ok: true, preferred: root.preferred, regions: root.regions }) }
    }
}
