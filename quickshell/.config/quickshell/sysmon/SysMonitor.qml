// SysMonitor.qml — monitor de recursos para a barra do Quickshell
// Na barra (barStyle): três barrinhas de CPU, GPU e RAM ("bars", padrão), só um ícone ("icon")
// ou as porcentagens ("numbers"). Tudo fica amarelo/vermelho com carga ou temperatura alta.
// Clique esquerdo: painel com detalhes (temperaturas, VRAM, swap, consumo da GPU).
// Clique direito: abre o btop no terminal.
// Fontes: /proc/stat, /proc/meminfo, sensor k10temp (Ryzen) e nvidia-smi (NVIDIA).

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
    property color warn: Theme.warn
    property color crit: Theme.crit
    property color bg: Theme.bg
    property color border: Theme.border
    property color track: Theme.track
    property string fontFamily: Theme.font
    property int fontSize: Theme.fontSize
    // ---------- comportamento ----------
    property int interval: 2000                    // ms entre leituras
    property var terminal: ["foot", "-e", "btop"]  // clique direito

    // Limites (aviso, crítico)
    property var cpuLoadLimits: [70, 90]   // %
    property var cpuTempLimits: [75, 85]   // °C (o 5800X3D reduz o clock perto de 90)
    property var gpuTempLimits: [75, 83]   // °C
    property var ramLimits: [80, 92]       // %

    // ---------- estado ----------
    property real cpuUsage: 0      // 0..1
    property real cpuTemp: -1      // °C
    property real memTotal: 0      // KiB
    property real memUsed: 0
    property real swapTotal: 0
    property real swapUsed: 0
    property real gpuUsage: -1     // %
    property real gpuTemp: -1      // °C
    property real vramUsed: 0      // MiB
    property real vramTotal: 0
    property real gpuPower: -1     // W
    property real gpuPowerLimit: -1
    property string tempPath: ""
    property var lastCpu: null

    readonly property real memUsage: memTotal > 0 ? memUsed / memTotal : 0
    readonly property bool hasGpu: gpuUsage >= 0

    // ---------- níveis: 0 normal, 1 aviso, 2 crítico ----------
    function level(v, lim) { return v >= lim[1] ? 2 : v >= lim[0] ? 1 : 0 }
    function levelColor(l, base) { return l === 2 ? crit : l === 1 ? warn : base }

    readonly property int cpuLoadLevel: level(cpuUsage * 100, cpuLoadLimits)
    readonly property int cpuTempLevel: cpuTemp < 0 ? 0 : level(cpuTemp, cpuTempLimits)
    readonly property int gpuTempLevel: gpuTemp < 0 ? 0 : level(gpuTemp, gpuTempLimits)
    readonly property int ramLevel: level(memUsage * 100, ramLimits)
    // GPU a 99% em jogo é normal, então na GPU só a temperatura gera alerta
    readonly property int cpuLevel: Math.max(cpuLoadLevel, cpuTempLevel)
    readonly property int gpuLevel: gpuTempLevel

    // ---------- formatação ----------
    function glyph(cp) { return String.fromCodePoint(cp) }
    function pct(v) { return String(Math.round(v)).padStart(2, " ") + "%" }
    function gib(kib) { return (kib / 1048576).toFixed(1) }
    function temp(v) { return v < 0 ? "—" : Math.round(v) + "°C" }

    // ---------- leitura ----------
    function parseStat(t) {
        // primeira linha: cpu user nice system idle iowait irq softirq steal
        const p = t.split("\n")[0].trim().split(/\s+/).slice(1, 9).map(Number)
        const idle = p[3] + p[4]
        const total = p.reduce((a, b) => a + b, 0)
        if (lastCpu) {
            const dt = total - lastCpu.total
            if (dt > 0) cpuUsage = Math.max(0, Math.min(1, 1 - (idle - lastCpu.idle) / dt))
        }
        lastCpu = { total: total, idle: idle }
    }

    function kib(t, key) {
        const m = t.match(new RegExp("^" + key + ":\\s+(\\d+)", "m"))
        return m ? Number(m[1]) : 0
    }

    function parseMem(t) {
        memTotal = kib(t, "MemTotal")
        memUsed = memTotal - kib(t, "MemAvailable")
        swapTotal = kib(t, "SwapTotal")
        swapUsed = swapTotal - kib(t, "SwapFree")
    }

    FileView {
        id: statFile
        path: "/proc/stat"
        onLoaded: root.parseStat(text())
    }

    FileView {
        id: memFile
        path: "/proc/meminfo"
        onLoaded: root.parseMem(text())
    }

    FileView {
        id: tempFile
        path: root.tempPath
        onLoaded: {
            const v = parseInt(text())
            root.cpuTemp = isNaN(v) ? -1 : v / 1000
        }
    }

    // Acha o sensor do Ryzen (o número do hwmon muda entre boots)
    Process {
        running: true
        command: ["sh", "-c",
            "for d in /sys/class/hwmon/hwmon*; do [ \"$(cat $d/name)\" = k10temp ] && echo $d/temp1_input && break; done"]
        stdout: StdioCollector { onStreamFinished: root.tempPath = text.trim() }
    }

    Timer {
        interval: root.interval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            statFile.reload()
            memFile.reload()
            if (root.tempPath !== "") tempFile.reload()
        }
    }

    // GPU: um único nvidia-smi que fica rodando e imprime uma linha por intervalo
    Process {
        id: gpuProc
        running: true
        command: ["nvidia-smi",
            "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,power.limit",
            "--format=csv,noheader,nounits", "-lms", String(root.interval)]
        stdout: SplitParser {
            onRead: line => {
                const f = line.split(",").map(s => parseFloat(s.trim()))
                if (f.length < 6 || isNaN(f[0])) return
                root.gpuUsage = f[0]
                root.gpuTemp = isNaN(f[1]) ? -1 : f[1]
                root.vramUsed = f[2] || 0
                root.vramTotal = f[3] || 0
                root.gpuPower = isNaN(f[4]) ? -1 : f[4]
                root.gpuPowerLimit = isNaN(f[5]) ? -1 : f[5]
            }
        }
        // se cair (driver atualizado, por exemplo), tenta de novo em 10 s
        onExited: gpuRestart.start()
    }

    Timer {
        id: gpuRestart
        interval: 10000
        onTriggered: gpuProc.running = true
    }

    // ---------- na barra ----------
    // barStyle: "bars" (três barrinhas, padrão), "icon" (só um ícone) ou "numbers" (porcentagens)
    property string barStyle: "bars"

    implicitWidth: barRow.implicitWidth
    implicitHeight: Math.max(barRow.implicitHeight, fontSize + 4)

    // pior nível entre CPU, GPU e RAM (usado no estilo "icon" e na cor do ícone)
    readonly property int worstLevel: Math.max(cpuLevel, gpuLevel, ramLevel)

    function barColor(l) { return l === 2 ? crit : l === 1 ? warn : accent }

    Row {
        id: barRow
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        // Ícone de chip, colorido pelo pior nível
        Text {
            visible: root.barStyle !== "numbers"
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph(0xF4BC)    // nf-oct-cpu (contorno, melhor para OLED)
            color: root.levelColor(root.worstLevel,
                   popup.visible || barMouse.containsMouse ? root.accent : root.fg)
            font.family: root.fontFamily
            font.pixelSize: root.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
        }

        // Três barrinhas verticais: CPU, GPU, RAM
        Row {
            visible: root.barStyle === "bars"
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Repeater {
                model: [
                    { v: root.cpuUsage, l: root.cpuLevel, show: true },
                    { v: root.memUsage, l: root.ramLevel, show: true },
                    { v: root.gpuUsage / 100, l: root.gpuLevel, show: root.hasGpu }
                ]

                Rectangle {
                    required property var modelData
                    visible: modelData.show
                    width: 4
                    height: root.fontSize + 1
                    radius: 2
                    color: root.track

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(2, parent.height * Math.max(0, Math.min(1, parent.modelData.v)))
                        radius: 2
                        color: root.barColor(parent.modelData.l)
                        Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
            }
        }

        // Estilo "numbers": porcentagens com ícones (o layout original)
        Row {
            visible: root.barStyle === "numbers"
            spacing: 10

            Row {
                spacing: 4
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.glyph(0xF0EE0)
                    color: root.levelColor(root.cpuLevel, root.dim)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize + 1
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.pct(root.cpuUsage * 100)
                    color: root.levelColor(root.cpuLevel, root.fg)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                }
            }
            Row {
                visible: root.hasGpu
                spacing: 4
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.glyph(0xF08AE)
                    color: root.levelColor(root.gpuLevel, root.dim)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize + 1
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.pct(root.gpuUsage)
                    color: root.levelColor(root.gpuLevel, root.fg)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                }
            }
            Row {
                spacing: 4
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.glyph(0xF035B)
                    color: root.levelColor(root.ramLevel, root.dim)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize + 1
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.pct(root.memUsage * 100)
                    color: root.levelColor(root.ramLevel, root.fg)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                }
            }
        }
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                Quickshell.execDetached(root.terminal)
            else
                Popups.toggle(popup)
        }
    }

    // ---------- painel de detalhes ----------
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
        implicitWidth: 280
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

                // --- CPU ---
                SectionTitle { widget: root; icon: root.glyph(0xF0EE0); title: "CPU" }
                StatRow {
                    widget: root
                    label: "Usage"
                    value: Math.round(root.cpuUsage * 100) + "%"
                    fraction: root.cpuUsage
                    tone: root.cpuLoadLevel
                }
                StatRow {
                    widget: root
                    label: "Temperature"
                    value: root.temp(root.cpuTemp)
                    fraction: root.cpuTemp < 0 ? -1 : root.cpuTemp / 95
                    tone: root.cpuTempLevel
                }

                // --- Memória ---
                SectionTitle { widget: root; icon: root.glyph(0xF035B); title: "Memory" }
                StatRow {
                    widget: root
                    label: "RAM"
                    value: root.gib(root.memUsed) + " / " + root.gib(root.memTotal) + " GB"
                    fraction: root.memUsage
                    tone: root.ramLevel
                }
                StatRow {
                    visible: root.swapTotal > 0
                    widget: root
                    label: "Swap"
                    value: root.gib(root.swapUsed) + " / " + root.gib(root.swapTotal) + " GB"
                    fraction: root.swapTotal > 0 ? root.swapUsed / root.swapTotal : 0
                }

                // --- GPU ---
                SectionTitle { visible: root.hasGpu; widget: root; icon: root.glyph(0xF08AE); title: "GPU" }
                StatRow {
                    visible: root.hasGpu
                    widget: root
                    label: "Usage"
                    value: Math.round(root.gpuUsage) + "%"
                    fraction: root.gpuUsage / 100
                }
                StatRow {
                    visible: root.hasGpu
                    widget: root
                    label: "Temperature"
                    value: root.temp(root.gpuTemp)
                    fraction: root.gpuTemp < 0 ? -1 : root.gpuTemp / 90
                    tone: root.gpuTempLevel
                }
                StatRow {
                    visible: root.hasGpu
                    widget: root
                    label: "VRAM"
                    value: (root.vramUsed / 1024).toFixed(1) + " / " + (root.vramTotal / 1024).toFixed(1) + " GB"
                    fraction: root.vramTotal > 0 ? root.vramUsed / root.vramTotal : 0
                }
                StatRow {
                    visible: root.hasGpu && root.gpuPower >= 0
                    widget: root
                    label: "Power"
                    value: Math.round(root.gpuPower) + (root.gpuPowerLimit > 0 ? " / " + Math.round(root.gpuPowerLimit) : "") + " W"
                    fraction: root.gpuPowerLimit > 0 ? root.gpuPower / root.gpuPowerLimit : -1
                }

                // --- rodapé ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    implicitHeight: 30
                    radius: 8
                    color: footMouse.containsMouse ? root.border : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "Open btop"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 1
                    }

                    MouseArea {
                        id: footMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Popups.hide(popup)
                            Quickshell.execDetached(root.terminal)
                        }
                    }
                }
            }
        }
    }
}
