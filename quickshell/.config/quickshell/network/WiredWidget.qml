// WiredWidget.qml — conexão por cabo na barra do Quickshell
// Na barra: porta RJ45 em contorno (apagada com o cabo desconectado; some se não houver placa de rede).
// Clique: painel só com os dados da conexão (IP, máscara, gateway, DNS, MAC, velocidade, IP público).
// Clique em qualquer valor para copiá-lo.
// Depende do NetworkManager (nmcli), do net-info.sh (nesta pasta) e do wl-clipboard.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    // Ilha da barra onde o widget está (primeiro ancestral com "radius"); os painéis se alinham a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property bool hideWhenNoDevice: true

    // ---------- estado ----------
    property string device: ""
    property string connection: ""
    property bool up: false
    property var details: []        // entradas "ethernet" do net-info.sh
    property string statusText: ""

    // nmcli -t separa campos com ":" e escapa ":" dentro dos valores com "\:"
    function splitTerse(line) {
        const out = []
        let cur = ""
        for (let i = 0; i < line.length; i++) {
            const c = line[i]
            if (c === "\\" && i + 1 < line.length) { cur += line[++i]; continue }
            if (c === ":") { out.push(cur); cur = ""; continue }
            cur += c
        }
        out.push(cur)
        return out
    }

    function copy(label, value) {
        Quickshell.execDetached(["wl-copy", value])
        statusText = label + " copied"
        statusClear.restart()
    }

    function refresh() { devProc.running = true }
    function refreshDetails() { infoProc.running = true }

    // ---------- processos ----------
    Process {
        id: devProc
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"]
        stdout: StdioCollector {
            onStreamFinished: {
                let dev = "", conn = "", up = false
                for (const line of text.trim().split("\n")) {
                    if (!line) continue
                    const [d, type, state, c] = root.splitTerse(line)
                    // prefere a placa conectada, se houver mais de uma
                    if (type === "ethernet" && (!dev || state === "connected")) {
                        dev = d; conn = c; up = (state === "connected")
                    }
                }
                const changed = up !== root.up
                root.device = dev
                root.connection = conn
                root.up = up
                if (changed && popup.visible) root.refreshDetails()
            }
        }
    }

    Process {
        id: infoProc
        command: ["bash", Quickshell.shellDir + "/network/net-info.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.details = JSON.parse(text).filter(c => c.type === "ethernet") }
                catch (e) { root.details = [] }
            }
        }
    }

    Timer { id: statusClear; interval: 2000; onTriggered: root.statusText = "" }

    Timer {
        interval: 10000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ---------- na barra ----------
    visible: !hideWhenNoDevice || device !== ""
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    EthernetIcon {
        id: icon
        anchors.centerIn: parent
        size: Theme.fontSize + 2
        color: !root.up ? Theme.overlay
             : popup.visible || barMouse.containsMouse ? Theme.accent : Theme.fg
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            Popups.toggle(popup)
            if (Popups.isOpen(popup)) { root.refresh(); root.refreshDetails() }
        }
    }

    // ---------- painel ----------
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        // só um painel aberto por vez na barra
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        // ponto de ancoragem: canto inferior direito da ilha, popupGap abaixo dela;
        // o painel cresce para a esquerda e para baixo a partir dali
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 320
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        HyprlandFocusGrab {
            windows: [popup]
            active: popup.visible
            onCleared: Popups.hide(popup)
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                // --- cabeçalho ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    EthernetIcon {
                        size: Theme.fontSize + 4
                        color: root.up ? Theme.accent : Theme.dim
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: "Ethernet"
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize
                            font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: root.up && root.connection !== ""
                            text: root.connection
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        text: root.up ? "Connected" : "Cable disconnected"
                        color: root.up ? Theme.good : Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 2
                    }
                }

                // --- dados da conexão ---
                ColumnLayout {
                    visible: root.up
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 0

                    Text {
                        visible: root.details.length === 0
                        Layout.leftMargin: 8
                        text: infoProc.running ? "Loading…" : "No address yet"
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 2
                    }

                    Repeater {
                        model: root.details

                        ColumnLayout {
                            id: conn
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 0

                            DetailRow { widget: root; label: "Interface"; value: conn.modelData.iface }
                            DetailRow {
                                widget: root
                                label: "IPv4"
                                value: conn.modelData.ipv4 ? conn.modelData.ipv4 + "/" + conn.modelData.prefix : ""
                                copyValue: conn.modelData.ipv4
                            }
                            DetailRow { widget: root; label: "Netmask"; value: conn.modelData.mask }
                            DetailRow { widget: root; label: "Gateway"; value: conn.modelData.gateway }
                            DetailRow { widget: root; label: "DNS"; value: conn.modelData.dns }
                            DetailRow { widget: root; label: "IPv6"; value: conn.modelData.ipv6 }
                            DetailRow { widget: root; label: "MAC"; value: conn.modelData.mac }
                            DetailRow { widget: root; label: "Speed"; value: conn.modelData.speed }
                        }
                    }

                    DetailRow {
                        widget: root
                        label: "Public IP"
                        value: root.details.length > 0 ? root.details[0].external : ""
                    }
                }

                // --- status ---
                Text {
                    visible: root.statusText !== ""
                    Layout.fillWidth: true
                    text: root.statusText
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }
            }
        }
    }
}
