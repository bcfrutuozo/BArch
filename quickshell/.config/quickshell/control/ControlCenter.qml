// ControlCenter.qml — central de controle da barra
// Um ícone que abre blocos de liga/desliga: modo claro/escuro (do sistema inteiro),
// Bluetooth, cafeína, luz noturna (hyprsunset), não perturbe, HDR e MangoHud nos jogos
// e captura de tela (grim + slurp).
// O shell.qml passa a janela da barra em "window" (usada pela cafeína).

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Bluetooth
import "../theme"
import "../notifications"

Item {
    id: root

    // ilha onde o widget está; o painel se alinha a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property var window: null           // janela da barra (para a cafeína)
    property int nightTemp: 4500        // temperatura da luz noturna, em kelvin
    property string screenshotDir: Quickshell.env("HOME") + "/Pictures/Screenshots"

    // ---------- estado ----------
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
    }

    // ---------- ações ----------
    function cap(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : "" }
    function pad(h) { return (h < 10 ? "0" : "") + h + ":00" }

    // O hyprsunset pode já estar rodando sem filtro (iniciado pelo sistema ou pelo Hyprland).
    // Ligar: temperatura da luz noturna. Desligar: 6500 K (neutro, sem filtro).
    // Não usamos o "identity" do hyprsunset para desligar, porque depois dele o hyprsunset
    // continua informando a última temperatura e a barra achava que ainda estava ligado.
    property real nightToggledAt: 0
    function toggleNight() {
        const on = !nightLight
        Quickshell.execDetached(["sh", "-c",
            'if pgrep -x hyprsunset >/dev/null; then hyprctl hyprsunset temperature "$1" >/dev/null; '
            + 'elif [ "$1" -lt 6000 ]; then exec hyprsunset -t "$1"; fi',
            "sh", String(on ? nightTemp : 6500)])
        nightLight = on
        nightToggledAt = Date.now()
        recheck.restart()
    }

    function toggleDnd() { Notifs.setDnd(!Notifs.dnd) }

    function screenshot() {
        Popups.hide(popup)
        shotDelay.restart()       // espera o painel sumir antes de selecionar a área
    }

    // cafeína: impede o hypridle de apagar, bloquear ou suspender
    IdleInhibitor {
        window: root.window
        enabled: root.caffeine && root.window !== null
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
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
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

                    Tile {
                        icon: root.glyph(0xF0A6D)   // selection_drag
                        Layout.columnSpan: 2
                        label: "Screenshot"
                        sublabel: "Select a region"
                        onClicked: root.screenshot()
                    }
                }
            }
        }
    }
}
