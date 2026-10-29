// VpnWidget.qml — indicador da VPN na barra: só aparece com o túnel ligado (ou subindo), ou com
// o Anonymous Mode ligado, com o escudo e o país; o clique abre um painel com região, IP, há
// quanto tempo, o navegador e o botão para desligar. O estado e as ações estão nos singletons
// Vpn (pia.sh) e Anon (anon.sh); a região se escolhe no Control Center. Com o modo ligado e o
// túnel caído, o escudo fica vermelho: o tráfego está saindo pelo IP real.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "../theme"
import "../anon"

Item {
    id: root

    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }
    function glyph(cp) { return String.fromCodePoint(cp) }
    function ago(since) {
        if (!since) return ""
        const s = Math.max(0, Math.floor(Date.now() / 1000 - since))
        if (s < 60) return "just now"
        if (s < 3600) return Math.floor(s / 60) + " min"
        return Math.floor(s / 3600) + " h " + Math.floor(s / 60) % 60 + " min"
    }
    property real tick: 0
    Timer { interval: 30000; running: popup.visible; repeat: true; onTriggered: root.tick = Date.now() }


    visible: Vpn.active || Anon.on
    onVisibleChanged: if (!visible) Popups.hide(popup)
    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Vpn.connected ? root.glyph(0xF099D) : Anon.degraded ? root.glyph(0xF099E) : root.glyph(0xF0499)     // shield_lock / shield_off / shield_outline
            color: Vpn.connected ? Theme.good : Anon.degraded ? Theme.red : Theme.warn
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            SequentialAnimation on opacity {
                running: Vpn.connecting; loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 600 } NumberAnimation { to: 1; duration: 600 }
                onRunningChanged: if (!running) parent.opacity = 1
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Anon.degraded ? "VPN down" : Vpn.country
            color: Theme.subtext
            font.family: Theme.font
            font.pixelSize: Theme.fontSize - 1
        }
    }
    MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.tick = Date.now(); Popups.toggle(popup) }
    }

    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
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

        HyprlandFocusGrab { windows: [popup]; active: popup.visible; onCleared: Popups.hide(popup) }

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

                RowLayout {
                    spacing: 10
                    Text {
                        text: Vpn.connected ? root.glyph(0xF099D) : Anon.degraded ? root.glyph(0xF099E) : root.glyph(0xF0499)
                        color: Vpn.connected ? Theme.good : Anon.degraded ? Theme.red : Theme.warn
                        font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 6
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: Anon.degraded ? "VPN dropped: traffic exposed"
                                : Vpn.connected ? (Anon.on ? "Anonymous mode" : "VPN connected") : "Connecting…"
                            color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: true
                        }
                        Text {
                            text: Vpn.regionName + (Vpn.auto ? "  ·  auto" : "")
                            color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2
                        }
                    }
                }
                Repeater {
                    model: [
                        { k: "IP", v: Vpn.ip || "…" },
                        { k: "Since", v: root.tick, w: root.ago(Vpn.since) },
                        { k: "Server", v: Vpn.region },
                        { k: "Browser", v: Anon.on ? (Anon.mullvad ? "Mullvad Browser" : "Mullvad Browser not installed") : "", hide: !Anon.on }
                    ]
                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        visible: Vpn.connected && !(modelData && modelData.hide)
                        Text { text: parent.modelData.k; color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2; Layout.preferredWidth: 56 }
                        Text {
                            text: parent.modelData.w !== undefined ? parent.modelData.w : parent.modelData.v
                            color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 8
                    // abre o Control Center já na lista de regiões (Vpn.chooseRegion)
                    PanelButton { label: "Change region"; onClicked: { Popups.hide(popup); Vpn.chooseRegion() } }
                    PanelButton {
                        label: (Vpn.busy || Anon.busy) ? "…" : Anon.on ? "Turn off" : "Disconnect"
                        tint: Theme.red
                        onClicked: { Popups.hide(popup); if (Anon.on) Anon.down(); else Vpn.down() }
                    }
                }
            }
        }
    }
}
