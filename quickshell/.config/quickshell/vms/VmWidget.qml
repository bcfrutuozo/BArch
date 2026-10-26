// VmWidget.qml — máquinas virtuais (libvirt/KVM) na barra do Quickshell
// Na barra: ícone de cubo; com VMs ligadas, mostra quantas estão rodando.
// Clique: painel com cada VM (sistema, estado, vCPUs, memória, IP) e ações:
// ligar, console, pausar/retomar, reiniciar, desligar e forçar desligamento.
// Depende do vm-info.sh (nesta mesma pasta), virsh, jq e virt-manager (para o console).

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

    // ---------- aparência (o shell.qml passa as cores do tema) ----------
    property color fg: Theme.fg
    property color dim: Theme.dim
    property color accent: Theme.accent
    property color good: Theme.good
    property color warn: Theme.warn
    property color crit: Theme.crit
    property color bg: Theme.bg
    property color border: Theme.border
    property color hover: Theme.hover
    property string fontFamily: Theme.font
    property string iconFont: Theme.iconFont
    property int fontSize: Theme.fontSize
    // ---------- comportamento ----------
    property string uri: "qemu:///system"
    property bool hideWhenEmpty: false   // true: some da barra se não houver nenhuma VM

    // ---------- estado ----------
    property var vms: []
    property string errorText: ""
    property string busy: ""        // nome da VM com ação em andamento
    property string armed: ""       // "nome" aguardando confirmação do forçar desligamento
    property string status: ""

    readonly property int running: vms.filter(v => v.state === "running").length

    function glyph(cp) { return String.fromCodePoint(cp) }

    function stateLabel(s) {
        return ({
            "running": "running", "paused": "paused", "shut off": "off",
            "in shutdown": "shutting down…", "crashed": "crashed", "pmsuspended": "suspended"
        })[s] || s
    }
    function stateColor(s) {
        if (s === "running") return good
        if (s === "paused" || s === "in shutdown" || s === "pmsuspended") return warn
        if (s === "crashed") return crit
        return dim
    }
    function osGlyph(os) {
        if (os.indexOf("microsoft.com/win") >= 0) return glyph(0xF05B3)   // windows
        if (os !== "") return glyph(0xF033D)                              // linux (e demais)
        return glyph(0xF01A7)                                             // cubo
    }
    function gib(kib) {
        const g = kib / 1048576
        return (g >= 10 ? Math.round(g) : g.toFixed(1)).toString() + " GB"
    }

    function refresh() { infoProc.running = true }

    function act(vm, verb) {
        busy = vm.name
        armed = ""
        status = ""
        actionProc.command = ["virsh", "-c", uri, verb, vm.name]
        actionProc.running = true
    }

    function openConsole(vm) {
        Popups.hide(popup)
        Quickshell.execDetached(["virt-manager", "--connect", uri, "--show-domain-console", vm.name])
    }

    // ---------- processos ----------
    Process {
        id: infoProc
        command: ["bash", Quickshell.shellDir + "/vms/vm-info.sh"]
        environment: ({ LIBVIRT_URI: root.uri })
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text)
                    root.vms = r.vms
                    root.errorText = r.error
                } catch (e) {}
            }
        }
    }

    Process {
        id: actionProc
        stderr: StdioCollector { id: actionErr }
        onExited: code => {
            if (code !== 0) root.status = actionErr.text.trim().split("\n").pop() || "Action failed"
            root.busy = ""
            root.refresh()
            // ligar/desligar levam alguns segundos para o estado mudar
            followUp.restart()
        }
    }

    Timer { id: followUp; interval: 3000; onTriggered: root.refresh() }

    // atualiza a cada 30 s, e a cada 4 s com o painel aberto
    Timer {
        interval: popup.visible ? 4000 : 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ---------- na barra ----------
    visible: !hideWhenEmpty || vms.length > 0
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    Row {
        id: barRow
        spacing: 5

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(0xF01A7)   // nf-md-cube_outline
            color: popup.visible || barMouse.containsMouse ? root.accent
                 : root.running > 0 ? root.fg : root.dim
            font.family: root.iconFont
            font.pixelSize: root.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        Text {
            visible: root.running > 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.running
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            Popups.toggle(popup)
            if (Popups.isOpen(popup)) { root.armed = ""; root.status = ""; root.refresh() }
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
        implicitWidth: 380
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
            color: root.bg
            border.color: root.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                Text {
                    text: "Virtual Machines"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    font.bold: true
                }

                // erro de acesso ao libvirt
                Text {
                    visible: root.errorText !== ""
                    Layout.fillWidth: true
                    text: root.errorText
                    color: root.crit
                    wrapMode: Text.Wrap
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 2
                }

                Text {
                    visible: root.errorText === "" && root.vms.length === 0
                    text: infoProc.running ? "Loading…" : "No VMs found"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 1
                }

                Repeater {
                    model: root.vms

                    Rectangle {
                        id: card
                        required property var modelData
                        readonly property var vm: modelData
                        readonly property bool isBusy: root.busy === vm.name
                        readonly property bool isOn: vm.state === "running"
                        readonly property bool paused: vm.state === "paused" || vm.state === "pmsuspended"

                        Layout.fillWidth: true
                        implicitHeight: body.implicitHeight + 20
                        radius: 10
                        color: "transparent"
                        border.width: 1
                        border.color: card.isOn ? root.border : "transparent"

                        ColumnLayout {
                            id: body
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 6

                            // nome + estado
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: root.osGlyph(card.vm.os)
                                    color: card.isOn ? root.accent : root.dim
                                    font.family: root.iconFont
                                    font.pixelSize: root.fontSize + 3
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: card.vm.name
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Row {
                                    spacing: 5
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 7; height: 7; radius: 3.5
                                        color: "transparent"
                                        border.width: 1.5
                                        border.color: root.stateColor(card.vm.state)
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: card.isBusy ? "…" : root.stateLabel(card.vm.state)
                                        color: root.stateColor(card.vm.state)
                                        font.family: root.fontFamily
                                        font.pixelSize: root.fontSize - 2
                                    }
                                }
                            }

                            // recursos
                            Text {
                                Layout.fillWidth: true
                                text: card.vm.vcpus + " vCPU  ·  " + root.gib(card.vm.maxmem)
                                    + (card.vm.ip ? "  ·  " + card.vm.ip : "")
                                    + (card.vm.autostart ? "  ·  autostart" : "")
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 2
                                elide: Text.ElideRight
                            }

                            // ações (dependem do estado)
                            Flow {
                                Layout.fillWidth: true
                                spacing: 6
                                enabled: !card.isBusy
                                opacity: card.isBusy ? 0.4 : 1

                                Repeater {
                                    model: {
                                        const s = card.vm.state
                                        if (s === "running") return [
                                            { label: "Console", verb: "console" },
                                            { label: "Pause", verb: "suspend" },
                                            { label: "Reboot", verb: "reboot" },
                                            { label: "Shut Down", verb: "shutdown" },
                                            { label: "Force Off", verb: "destroy", danger: true }
                                        ]
                                        if (s === "paused" || s === "pmsuspended") return [
                                            { label: "Resume", verb: "resume" },
                                            { label: "Force Off", verb: "destroy", danger: true }
                                        ]
                                        if (s === "in shutdown") return [
                                            { label: "Force Off", verb: "destroy", danger: true }
                                        ]
                                        return [{ label: "Start", verb: "start", primary: true }]
                                    }

                                    Rectangle {
                                        id: btn
                                        required property var modelData
                                        readonly property bool isArmed: modelData.danger === true
                                            && root.armed === card.vm.name
                                        width: btnText.implicitWidth + 20
                                        height: 26
                                        radius: 8
                                        color: btn.isArmed ? root.crit
                                             : btnMouse.containsMouse ? root.hover : "transparent"
                                        border.width: 1
                                        border.color: btn.modelData.danger ? root.crit
                                                    : btn.modelData.primary ? root.accent : root.border
                                        Behavior on color { ColorAnimation { duration: 120 } }

                                        Text {
                                            id: btnText
                                            anchors.centerIn: parent
                                            text: btn.isArmed ? "Confirm?" : btn.modelData.label
                                            color: btn.isArmed ? root.bg
                                                 : btn.modelData.danger ? root.crit
                                                 : btn.modelData.primary ? root.accent : root.fg
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fontSize - 2
                                            font.bold: btn.isArmed
                                        }

                                        MouseArea {
                                            id: btnMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                const m = btn.modelData
                                                if (m.verb === "console") return root.openConsole(card.vm)
                                                // forçar desligamento pede um segundo clique
                                                if (m.danger && !btn.isArmed) { root.armed = card.vm.name; return }
                                                root.act(card.vm, m.verb)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // mensagem de erro da última ação
                Text {
                    visible: root.status !== ""
                    Layout.fillWidth: true
                    text: root.status
                    color: root.crit
                    wrapMode: Text.Wrap
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 2
                }

                // rodapé
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    radius: 8
                    color: vmmMouse.containsMouse ? root.hover : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "Open virt-manager"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 1
                    }
                    MouseArea {
                        id: vmmMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Popups.hide(popup)
                            Quickshell.execDetached(["virt-manager", "--connect", root.uri])
                        }
                    }
                }
            }
        }
    }
}
