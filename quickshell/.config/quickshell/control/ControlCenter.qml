// ControlCenter.qml — central de controle da barra
// Um ícone que abre blocos de liga/desliga: modo claro/escuro (do sistema inteiro),
// Bluetooth, cafeína, luz noturna (hyprsunset), não perturbe, HDR e MangoHud nos jogos,
// captura e gravação de tela (grim/slurp, gpu-screen-recorder via record/record.sh) e a tela: HDR e brilho do SDR do monitor principal e o
// monitor vertical ligado/desligado (precisa do monitors.lua com BArch.set_monitor).
// O shell.qml passa a janela da barra em "window" (usada pela cafeína) e "ipcEnabled"
// (só a barra da tela principal responde ao IPC "control", usado pelo barch em ~/.local/bin).

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Bluetooth
import "../theme"
import "../notifications"
import "../audio"
import "../record"
import "../vpn"
import "../anon"

Item {
    id: root

    // ilha onde o widget está; o painel se alinha a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property var window: null           // janela da barra (para a cafeína)
    property bool ipcEnabled: true      // falso nas cópias da barra em outras telas
    property int nightTemp: 4500        // temperatura da luz noturna, em kelvin
    property string screenshotDir: Quickshell.env("HOME") + "/Pictures/Screenshots"

    // ---------- estado ----------
    // VPN (PIA, usada pelo Anonymous Mode): escolha da região aberta no painel; o filtro precisa do teclado (shell.qml)
    property bool chooseRegion: false
    property string regionFilter: ""
    readonly property bool wantsKeyboard: chooseRegion && popup.visible
    readonly property var regionList: {
        const q = regionFilter.trim().toLowerCase()
        const all = [{ id: "auto", name: "Auto", country: "", latency: null, sub: "fastest region, measured now" }].concat(Vpn.regions)
        if (q === "") return all
        return all.filter(r => (r.name + " " + r.id + " " + r.country).toLowerCase().includes(q))
    }
    function pickRegion(id) { Vpn.setPreferred(id); chooseRegion = false; regionFilter = "" }
    function regionTile() {
        chooseRegion = !chooseRegion
        regionFilter = ""
        if (chooseRegion) { Vpn.loadRegions(); Vpn.measure(); regionField.forceActiveFocus() }
    }
    // "Change region" no painel do escudo da barra: abre este painel já na lista
    Connections {
        target: Vpn
        enabled: root.ipcEnabled
        function onChooseRegion() {
            if (!Popups.isOpen(popup)) { Popups.show(popup); root.refresh() }
            root.chooseRegion = false
            root.regionTile()
        }
    }

    property bool caffeine: false
    property bool nightLight: false
    property bool hasHyprsunset: true
    readonly property bool dnd: Notifs.dnd

    readonly property bool anyActive: caffeine || nightLight || dnd

    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property bool btOn: btAdapter !== null && btAdapter.enabled
    readonly property var btConnected: Bluetooth.devices.values.filter(d => d.connected)

    function glyph(cp) { return String.fromCodePoint(cp) }

    function refresh() {
        nightProc.running = true
        displayProc.running = true
    }

    // ---------- tela ----------
    property string mainOutput: "HDMI-A-2"
    property string sideOutput: "HDMI-A-1"
    property int sdrMin: 120                 // faixa do controle de brilho do SDR (nits)
    property int sdrMax: 420
    property bool hdrOn: true
    property int sdrWhite: 250
    property bool sideOn: true
    property var displayOverrides: ({})      // o que a barra mudou no monitor principal
    readonly property string displayPath: Quickshell.env("HOME") + "/.local/state/quickshell/display.json"

    function luaValue(v) { return typeof v === "string" ? '"' + v + '"' : String(v) }
    function pushDisplay() {
        const keys = Object.keys(displayOverrides)
        if (keys.length === 0) return
        const t = "{ " + keys.map(k => k + " = " + luaValue(displayOverrides[k])).join(", ") + " }"
        Quickshell.execDetached(["hyprctl", "eval",
            'if BArch and BArch.set_monitor then BArch.set_monitor("' + mainOutput + '", ' + t + ') end'])
    }
    function setMain(changes) {
        const o = Object.assign({}, displayOverrides, changes)
        displayOverrides = o
        Theme.writeFile(displayPath, JSON.stringify(o))
        pushDisplay()
        displayRecheck.restart()
    }
    function resetDisplay() {
        displayOverrides = ({})
        Theme.writeFile(displayPath, "{}")
        Quickshell.execDetached(["hyprctl", "eval",
            'if BArch and BArch.apply_monitor then BArch.monitor_overrides = {}; BArch.apply_monitor("' + mainOutput + '") end'])
        displayRecheck.restart()
    }
    function setHdr(on) { hdrOn = on; setMain({ cm: on ? "hdr" : "srgb" }) }
    function toggleHdr() { setHdr(!hdrOn) }
    function setSdr(nits) { sdrWhite = nits; setMain({ sdr_max_luminance: nits }) }
    function setSide(on) {
        sideOn = on
        Hyprland.dispatch('hl.dsp.dpms({ action = "' + (on ? "on" : "off") + '", monitor = "' + sideOutput + '" })')
        displayRecheck.restart()
    }
    function toggleSide() { setSide(!sideOn) }

    FileView {
        path: root.displayPath
        onLoaded: {
            try { root.displayOverrides = JSON.parse(text()) || {} } catch (e) { root.displayOverrides = {} }
            displayStart.restart()
        }
    }
    // depois de iniciar e a cada reload do Hyprland, reaplica o que foi mudado pela barra
    Timer { id: displayStart; interval: 1500; onTriggered: root.pushDisplay() }
    Connections {
        target: Hyprland
        function onRawEvent(event) { if (event.name === "configreloaded") displayStart.restart() }
    }
    Timer { id: sdrApply; interval: 180; onTriggered: root.setSdr(root.sdrWhite) }
    Timer { id: displayRecheck; interval: 1200; onTriggered: displayProc.running = true }

    Process {
        id: displayProc
        command: ["hyprctl", "monitors", "all", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = []
                try { list = JSON.parse(text) } catch (e) { return }
                for (const m of list) {
                    if (m.name === root.mainOutput) {
                        root.hdrOn = (m.colorManagementPreset || "") === "hdr"
                        if (!sdrApply.running && m.sdrMaxLuminance) root.sdrWhite = Math.round(m.sdrMaxLuminance)
                    } else if (m.name === root.sideOutput) {
                        root.sideOn = m.dpmsStatus !== false
                    }
                }
            }
        }
    }

    // ---------- ações ----------
    function cap(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : "" }
    function pad(h) { return (h < 10 ? "0" : "") + h + ":00" }

    // O hyprsunset pode já estar rodando sem filtro (iniciado pelo sistema ou pelo Hyprland).
    // Ligar: temperatura da luz noturna. Desligar: 6500 K (neutro, sem filtro).
    // Não usamos o "identity" do hyprsunset para desligar, porque depois dele o hyprsunset
    // continua informando a última temperatura e a barra achava que ainda estava ligado.
    property real nightToggledAt: 0
    function setNight(on) {
        Quickshell.execDetached(["sh", "-c",
            'if pgrep -x hyprsunset >/dev/null; then hyprctl hyprsunset temperature "$1" >/dev/null; '
            + 'elif [ "$1" -lt 6000 ]; then exec hyprsunset -t "$1"; fi',
            "sh", String(on ? nightTemp : 6500)])
        nightLight = on
        nightToggledAt = Date.now()
        recheck.restart()
    }
    function toggleNight() { setNight(!nightLight) }

    function toggleDnd() { Notifs.setDnd(!Notifs.dnd) }

    // gravação de tela: escolha entre tela inteira e área
    property bool chooseRecord: false
    function recordTile() {
        if (Recorder.recording) { Recorder.stop(); return }
        chooseRecord = !chooseRecord
    }
    function record(mode) {
        chooseRecord = false
        Popups.hide(popup)
        recDelay.mode = mode
        recDelay.restart()        // espera o painel sumir (ele não pode aparecer no vídeo)
    }
    Timer { id: recDelay; property string mode: "full"; interval: 350; onTriggered: Recorder.start(mode) }

    function screenshot() {
        Popups.hide(popup)
        shotDelay.restart()       // espera o painel sumir antes de selecionar a área
    }

    // cafeína: impede o hypridle de apagar, bloquear ou suspender
    IdleInhibitor {
        window: root.window
        enabled: root.caffeine && root.window !== null
    }

    // ---------- IPC (barch) ----------
    // Todas respondem JSON: {"ok": true, ...estado} ou {"ok": false, "error": "..."}.
    // O estado do monitor é relido a cada 15 s e logo depois de cada mudança.
    function state() {
        return {
            ok: true, hdr: hdrOn, sdrWhite: sdrWhite, sdrMin: sdrMin, sdrMax: sdrMax, side: sideOn,
            caffeine: caffeine, nightLight: nightLight, nightTemp: nightTemp, hasHyprsunset: hasHyprsunset,
            mainOutput: mainOutput, sideOutput: sideOutput
        }
    }
    function fail(msg) { return JSON.stringify({ ok: false, error: msg }) }
    IpcHandler {
        target: "control"
        enabled: root.ipcEnabled
        function status(): string { root.refresh(); return JSON.stringify(root.state()) }
        function hdr(on: bool): string { root.setHdr(on); return JSON.stringify(root.state()) }
        function sdr(nits: int): string {
            if (!root.hdrOn) return root.fail("HDR is off; the SDR brightness only applies in HDR")
            if (nits < root.sdrMin || nits > root.sdrMax)
                return root.fail("SDR brightness must be between " + root.sdrMin + " and " + root.sdrMax + " nits")
            root.setSdr(nits)
            return JSON.stringify(root.state())
        }
        function side(on: bool): string { root.setSide(on); return JSON.stringify(root.state()) }
        function caffeine(on: bool): string {
            if (root.window === null) return root.fail("no bar window to hold the idle inhibitor")
            root.caffeine = on
            return JSON.stringify(root.state())
        }
        function nightLight(on: bool): string {
            if (!root.hasHyprsunset) return root.fail("hyprsunset is not installed")
            if (on !== root.nightLight) root.setNight(on)
            return JSON.stringify(root.state())
        }
    }

    // ---------- leitura do estado ----------
    Process {
        id: nightProc
        // "ligado" = filtro realmente aplicado (temperatura abaixo de 6000 K),
        // não só o processo do hyprsunset rodando
        command: ["sh", "-c",
            "command -v hyprsunset >/dev/null || { echo missing; exit; }; "
            + "pgrep -x hyprsunset >/dev/null || { echo off; exit; }; "
            + "t=$(hyprctl hyprsunset temperature 2>/dev/null | grep -oE '[0-9]+' | head -n1); "
            + "[ -n \"$t\" ] && [ \"$t\" -lt 6000 ] && echo on || echo off"]
        stdout: StdioCollector {
            onStreamFinished: {
                const s = text.trim()
                root.hasHyprsunset = s !== "missing"
                // logo depois de um clique, confia no clique (o hyprsunset leva um instante para aplicar)
                if (Date.now() - root.nightToggledAt > 2500) root.nightLight = s === "on"
            }
        }
    }

    Timer { id: recheck; interval: 3000; onTriggered: root.refresh() }
    Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    Timer {
        id: shotDelay
        interval: 300
        onTriggered: Quickshell.execDetached(["sh", "-c",
            'mkdir -p "$1" && f="$1/$(date +%Y-%m-%d_%H-%M-%S).png" && grim -g "$(slurp)" "$f" '
            + '&& wl-copy < "$f" && notify-send -i "$f" "Screenshot" "Saved and copied to the clipboard"',
            "sh", root.screenshotDir])
    }

    // ---------- na barra ----------
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    Text {
        id: icon
        anchors.centerIn: parent
        text: root.glyph(0xF1542)   // nf-md-tune_variant
        color: popup.visible || barMouse.containsMouse || root.anyActive ? Theme.accent : Theme.fg
        font.family: Theme.iconFont
        font.pixelSize: Theme.fontSize + 2
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            Popups.toggle(popup)
            if (Popups.isOpen(popup)) root.refresh()
        }
    }

    // ---------- painel ----------
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        // só um painel aberto por vez na barra
        Connections {
            target: popup
            function onVisibleChanged() {
                popup.visible ? Popups.opened(popup) : Popups.closed(popup)
                if (!popup.visible) { root.chooseRecord = false; root.chooseRegion = false; root.regionFilter = "" }
            }
        }
        visible: false
        // canto inferior direito da ilha, popupGap abaixo dela
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 360
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
                spacing: 10

                Text {
                    text: "Control Center"
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                // --- aparência: Light / Dark / Auto ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Repeater {
                        model: [
                            { key: "light", icon: 0xF0599, label: "Light", sub: root.cap(Theme.lightFlavor) },   // weather_sunny
                            { key: "dark",  icon: 0xF0F65, label: "Dark",  sub: root.cap(Theme.darkFlavor) },    // moon_waning_crescent
                            { key: "auto",  icon: 0xF1A78, label: "Auto",                                         // sun_clock_outline
                              sub: root.pad(Theme.dayStart) + " – " + root.pad(Theme.nightStart) }
                        ]

                        Rectangle {
                            id: seg
                            required property var modelData
                            readonly property bool selected: Theme.appearance === modelData.key
                                || (Theme.appearance === "" && modelData.key === Theme.currentMode)

                            Layout.fillWidth: true
                            Layout.preferredWidth: 1          // as três com a mesma largura
                            implicitHeight: 64
                            radius: Theme.cardRadius
                            color: segMouse.containsMouse ? Theme.hover : "transparent"
                            border.width: selected ? 1.5 : 1
                            border.color: selected ? Theme.accent : Theme.border
                            Behavior on border.color { ColorAnimation { duration: 150 } }

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 2
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.glyph(seg.modelData.icon)
                                    color: seg.selected ? Theme.accent : Theme.fg
                                    font.family: Theme.iconFont
                                    font.pixelSize: Theme.fontSize + 5
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: seg.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 1
                                    font.bold: true
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: seg.modelData.sub
                                    color: seg.selected ? Theme.accent : Theme.dim
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 3
                                }
                            }

                            MouseArea {
                                id: segMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Theme.chooseAppearance(seg.modelData.key)
                            }
                        }
                    }
                }

                // --- tela ---
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    Text {
                        Layout.fillWidth: true
                        text: "Display"
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 2
                    }
                    Text {
                        visible: Object.keys(root.displayOverrides).length > 0
                        text: "Reset"
                        color: resetMouse.containsMouse ? Theme.accent : Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 2
                        MouseArea {
                            id: resetMouse
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.resetDisplay()
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    rowSpacing: 8
                    columnSpacing: 8

                    Tile {
                        icon: root.glyph(0xF0D7D)   // hdr
                        label: "HDR"
                        sublabel: root.hdrOn ? "Main display" : "Off"
                        active: root.hdrOn
                        onClicked: root.toggleHdr()
                    }
                    Tile {
                        icon: root.sideOn ? root.glyph(0xF0379) : root.glyph(0xF0D90)   // monitor / monitor_off
                        label: "Side Display"
                        sublabel: root.sideOn ? "On" : "Screen off"
                        active: root.sideOn
                        onClicked: root.toggleSide()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    spacing: 10
                    opacity: root.hdrOn ? 1 : 0.4
                    enabled: root.hdrOn

                    Text {
                        text: root.glyph(0xF00DF)   // brightness_6
                        color: Theme.fg
                        font.family: Theme.iconFont
                        font.pixelSize: Theme.fontSize + 3
                    }
                    VolumeSlider {
                        Layout.fillWidth: true
                        widget: Theme
                        value: (root.sdrWhite - root.sdrMin) / (root.sdrMax - root.sdrMin)
                        onMoved: v => {
                            root.sdrWhite = Math.round((root.sdrMin + v * (root.sdrMax - root.sdrMin)) / 5) * 5
                            sdrApply.restart()
                        }
                    }
                    Text {
                        Layout.preferredWidth: 64
                        horizontalAlignment: Text.AlignRight
                        text: root.sdrWhite + " nits"
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 2
                    }
                }

                Text {
                    text: "Quick Settings"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                    Layout.topMargin: 2
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    rowSpacing: 8
                    columnSpacing: 8

                    Tile {
                        icon: root.btOn ? root.glyph(0xF00AF) : root.glyph(0xF00B2)   // bluetooth / off
                        label: "Bluetooth"
                        sublabel: !root.btAdapter ? "No adapter"
                                : !root.btOn ? "Off"
                                : root.btConnected.length > 0 ? root.btConnected.map(d => d.name).join(", ")
                                : "On"
                        active: root.btOn
                        available: root.btAdapter !== null
                        onClicked: root.btAdapter.enabled = !root.btAdapter.enabled
                    }

                    Tile {
                        icon: root.glyph(0xF06CA)   // coffee_outline
                        label: "Caffeine"
                        sublabel: root.caffeine ? "Screen stays on" : "Off"
                        active: root.caffeine
                        available: root.window !== null
                        onClicked: root.caffeine = !root.caffeine
                    }

                    Tile {
                        icon: root.glyph(0xF1A4D)   // lightbulb_night_outline
                        label: "Night Light"
                        sublabel: !root.hasHyprsunset ? "hyprsunset not installed"
                                : root.nightLight ? root.nightTemp + " K" : "Off"
                        active: root.nightLight
                        available: root.hasHyprsunset
                        onClicked: root.toggleNight()
                    }

                    Tile {
                        icon: root.dnd ? root.glyph(0xF0A91) : root.glyph(0xF009C)   // bell_off / bell
                        label: "Do Not Disturb"
                        sublabel: root.dnd ? "Notifications muted" : "Off"
                        active: root.dnd
                        onClicked: root.toggleDnd()
                    }

                    Tile {
                        icon: Theme.gameHdr ? root.glyph(0xF0D7D) : root.glyph(0xF0D7E)   // hdr / hdr_off
                        label: "Game HDR"
                        sublabel: Theme.gameHdr ? "On next launch" : "Off"
                        active: Theme.gameHdr
                        onClicked: Theme.setGameHdr(!Theme.gameHdr)
                    }

                    Tile {
                        icon: root.glyph(0xF04C5)   // speedometer
                        label: "Game HUD"
                        sublabel: Theme.gameHud ? "MangoHud shown" : "Hidden"
                        active: Theme.gameHud
                        onClicked: Theme.setGameHud(!Theme.gameHud)
                    }

                    // Anonymous Mode (singleton Anon): a VPN mais kill switch, Mullvad Browser como padrão
                    // e hostname fora do DHCP; desligado, mostra o que ainda falta para o modo cobrir tudo
                    Tile {
                        icon: Anon.on ? root.glyph(0xF05F9) : root.glyph(0xF0075)   // incognito / incognito_off
                        label: "Anonymous Mode"
                        sublabel: !Anon.available ? "No PIA credentials"
                                : Anon.connecting ? "Connecting to " + (Vpn.regionName || root.cap(Vpn.preferred)) + "…"
                                : Anon.holding ? "VPN dropped  ·  kill switch holding"
                                : Anon.exposed ? "VPN dropped  ·  traffic exposed"
                                : Anon.on ? Vpn.regionName + (Vpn.ip ? "  ·  " + Vpn.ip : "")
                                            + (!Anon.killswitch ? "  ·  no kill switch" : Anon.mullvad ? "  ·  Mullvad" : "")
                                : Anon.error !== "" ? Anon.error
                                : Vpn.connected ? "Off  ·  VPN only (" + Vpn.regionName + ")"
                                : Anon.missing.length > 0 ? "Off  ·  " + Anon.missing[0] : "Off"
                        active: Anon.on
                        available: Anon.available
                        onClicked: Anon.toggle()
                    }

                    Tile {
                        icon: root.glyph(0xF01E7)   // earth
                        label: "VPN Region"
                        sublabel: Vpn.regionLabel(Vpn.preferred) + (Vpn.preferred === "auto" && Vpn.connected ? "  ·  " + Vpn.regionName : "")
                        active: root.chooseRegion
                        available: Vpn.available
                        onClicked: root.regionTile()
                    }

                    Tile {
                        icon: root.glyph(0xF0A6D)   // selection_drag
                        label: "Screenshot"
                        sublabel: "Select a region"
                        onClicked: root.screenshot()
                    }

                    Tile {
                        icon: Recorder.recording ? root.glyph(0xF0667) : root.glyph(0xF0EC3)   // stop_circle / record_circle
                        label: Recorder.recording ? "Stop Recording" : "Record"
                        sublabel: Recorder.recording ? Recorder.elapsed : "Screen or region"
                        active: Recorder.recording || root.chooseRecord
                        onClicked: root.recordTile()
                    }
                }

                // escolha da região da VPN (aparece ao clicar em VPN Region): filtro + lista por latência
                ColumnLayout {
                    visible: root.chooseRegion
                    Layout.fillWidth: true
                    spacing: 6

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: Theme.buttonRadius
                        color: Theme.surface
                        border.width: 1
                        border.color: regionField.activeFocus ? Theme.accent : "transparent"
                        RowLayout {
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            spacing: 8
                            Text { text: root.glyph(0xF0349); color: Theme.dim; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize }   // magnify
                            TextInput {
                                id: regionField
                                Layout.fillWidth: true
                                color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                                clip: true
                                onTextChanged: root.regionFilter = text
                                Keys.onEscapePressed: { root.chooseRegion = false; text = "" }
                                Keys.onReturnPressed: if (root.regionList.length > 0) root.pickRegion(root.regionList[0].id)
                                Text {
                                    anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                                    visible: regionField.text === ""
                                    text: "Filter regions (" + Vpn.regions.length + ")"
                                    color: Theme.overlay; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                                }
                            }
                            Text {
                                visible: Vpn.measuring
                                text: "measuring…"
                                color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                            }
                        }
                    }

                    ListView {
                        id: regionView
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(contentHeight, 240)
                        clip: true
                        model: root.regionList
                        boundsBehavior: Flickable.StopAtBounds
                        delegate: Rectangle {
                            id: regionRow
                            required property var modelData
                            readonly property bool selected: Vpn.preferred === modelData.id
                            width: regionView.width
                            implicitHeight: 32
                            radius: Theme.buttonRadius
                            color: regionMouse.containsMouse ? Theme.hover : "transparent"
                            RowLayout {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                spacing: 8
                                Text {
                                    text: regionRow.modelData.name
                                    color: regionRow.selected ? Theme.accent : Theme.fg
                                    font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: regionRow.selected
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                                Text {
                                    visible: text !== ""
                                    text: regionRow.modelData.sub !== undefined ? regionRow.modelData.sub
                                        : regionRow.modelData.country + (regionRow.modelData.pf ? "  ·  pf" : "") + (regionRow.modelData.geo ? "  ·  geo" : "")
                                    color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                                }
                                Text {
                                    Layout.preferredWidth: 48
                                    horizontalAlignment: Text.AlignRight
                                    text: Vpn.ms(regionRow.modelData.latency)
                                    color: regionRow.modelData.latency !== null && regionRow.modelData.latency < 0.05 ? Theme.good : Theme.dim
                                    font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                                }
                            }
                            MouseArea {
                                id: regionMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.pickRegion(regionRow.modelData.id)
                            }
                        }
                    }
                }

                // escolha do que gravar (aparece ao clicar em Record)
                RowLayout {
                    visible: root.chooseRecord && !Recorder.recording
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { mode: "full",   icon: 0xF0379, label: "Full Screen" },   // monitor
                            { mode: "region", icon: 0xF0A6D, label: "Region" }        // selection_drag
                        ]
                        Rectangle {
                            id: opt
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 36
                            radius: Theme.buttonRadius
                            color: optMouse.containsMouse ? Theme.hover : "transparent"
                            border.width: 1
                            border.color: Theme.accent
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.glyph(opt.modelData.icon)
                                    color: Theme.accent
                                    font.family: Theme.iconFont
                                    font.pixelSize: Theme.fontSize + 2
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: opt.modelData.label
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 1
                                }
                            }
                            MouseArea {
                                id: optMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.record(opt.modelData.mode)
                            }
                        }
                    }
                }
            }
        }
    }
}
