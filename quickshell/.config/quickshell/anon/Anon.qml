// Anon.qml — Anonymous Mode (anon.sh nesta pasta): a VPN (singleton Vpn) mais o que ainda
// entregaria esta máquina: o kill switch (nftables, helper root barch-killswitch) que segura todo
// o tráfego se o túnel cair, Mullvad Browser como navegador padrão enquanto ligado, hostname fora
// do DHCP e, estático, a política de WebRTC dos navegadores Chromium. Usado pelo tile do Control
// Center, pelo indicador da barra (VpnWidget) e pelo barch (IPC "anon"). O estado do túnel é o
// do Vpn; aqui só se chama o script e se lê o que ele cobre.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../vpn"

Singleton {
    id: root

    readonly property string script: Quickshell.shellDir + "/anon/anon.sh"

    property bool on: false                 // o modo está ligado (anon.sh on)
    property string browser: ""             // navegador padrão agora (.desktop)
    property bool mullvad: false            // Mullvad Browser instalado
    property bool webrtc: false             // política WebRTC dos navegadores Chromium no lugar
    property bool dhcpHostname: false       // algum perfil de rede ainda manda o hostname por DHCP
    property bool killswitchInstalled: false
    property bool killswitch: false         // kill switch armado (nada sai fora do túnel)
    property string killswitchEndpoint: ""
    property var missing: []                // o que o modo não cobre agora (texto)
    property bool busy: false               // on/off rodando
    property string error: ""

    readonly property bool available: Vpn.available
    // off | connecting | on | holding (ligado, túnel caiu, o kill switch segura o tráfego)
    // | exposed (ligado, túnel caiu, sem kill switch: o tráfego sai pelo IP real)
    readonly property string state: !on ? "off"
                                  : Vpn.connected ? "on"
                                  : (busy || Vpn.connecting) ? "connecting"
                                  : killswitch ? "holding" : "exposed"
    readonly property bool connecting: state === "connecting"
    readonly property bool holding: state === "holding"
    readonly property bool exposed: state === "exposed"
    readonly property bool degraded: holding || exposed

    function up(region) {
        if (busy) return
        busy = true; error = ""
        action.command = ["bash", script, "on"].concat(region ? [region] : [])
        action.running = true
    }
    function down() {
        if (busy) return
        busy = true
        action.command = ["bash", script, "off"]
        action.running = true
    }
    function toggle() { if (on) down(); else up("") }
    function refresh() { if (!statusProc.running) statusProc.running = true }

    Process {
        id: action
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") root.error = text.trim().replace(/^(anon|pia): /, "") }
        onExited: { root.busy = false; root.refresh(); Vpn.refresh() }
    }
    Process {
        id: statusProc
        command: ["bash", root.script, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let s
                try { s = JSON.parse(text) } catch (e) { return }
                root.on = s.on === true
                root.browser = s.browser || ""
                root.mullvad = s.mullvad === true
                root.webrtc = s.webrtc === true
                root.dhcpHostname = s.dhcpHostname === true
                root.killswitchInstalled = s.killswitch ? s.killswitch.installed === true : false
                root.killswitch = s.killswitch ? s.killswitch.armed === true : false
                root.killswitchEndpoint = s.killswitch ? (s.killswitch.endpoint || "") : ""
                root.missing = s.missing || []
                if (s.error && !root.busy) root.error = s.error
            }
        }
    }

    // estado a cada 5 s; a cada segundo enquanto liga ou desliga (o Vpn também, para o tile acompanhar)
    Timer {
        interval: root.busy ? 1000 : 5000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { root.refresh(); if (root.busy) Vpn.refresh() }
    }

    // ---- IPC (barch anon ...) ----
    function status() {
        return { ok: true, on: on, state: state, browser: browser, mullvad: mullvad, webrtc: webrtc,
                 dhcpHostname: dhcpHostname,
                 killswitch: { installed: killswitchInstalled, armed: killswitch, endpoint: killswitchEndpoint },
                 missing: missing, error: error, vpn: Vpn.status() }
    }
    IpcHandler {
        target: "anon"
        function status(): string { root.refresh(); return JSON.stringify(root.status()) }
        function on(region: string): string {
            if (!root.available) return JSON.stringify({ ok: false, error: "no PIA credentials in ~/.config/pia/credentials" })
            root.up(region)
            return JSON.stringify(root.status())
        }
        function off(): string { root.down(); return JSON.stringify(root.status()) }
        function toggle(): string {
            if (!root.on && !root.available) return JSON.stringify({ ok: false, error: "no PIA credentials in ~/.config/pia/credentials" })
            root.toggle()
            return JSON.stringify(root.status())
        }
    }
}
