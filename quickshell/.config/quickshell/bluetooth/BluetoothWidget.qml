// BluetoothWidget.qml — Bluetooth na barra do Quickshell (suporte nativo, sem programas extras)
// Na barra: símbolo do Bluetooth (apagado quando desligado, azul com algo conectado;
// some se não houver adaptador).
// Clique: painel com liga/desliga, busca, "My Devices" (pareados: clique conecta/desconecta,
// × esquece) e "Other Devices" (encontrados na busca: clique pareia e conecta). Um dispositivo
// conectado mostra bateria e o codec de áudio negociado (AAC, SBC-XQ, SBC), lido do nó do PipeWire.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import "../theme"

Item {
    id: root

    // ilha onde o widget está; o painel se alinha a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool btOn: adapter !== null && adapter.enabled
    readonly property var devices: Bluetooth.devices.values
    readonly property var paired: devices.filter(d => d.paired)
        .sort((a, b) => (b.connected - a.connected) || a.name.localeCompare(b.name))
    readonly property var others: devices.filter(d => !d.paired && d.name && d.name !== d.address)
    readonly property var connected: devices.filter(d => d.connected)

    property string statusText: ""

    // nós de saída Bluetooth do PipeWire (bluez_output.<MAC com _>.N); acompanhados para ler as propriedades
    readonly property var btNodes: Pipewire.nodes.values.filter(n => n.name && n.name.startsWith("bluez_output."))
    PwObjectTracker { objects: root.btNodes }

    function glyph(cp) { return String.fromCodePoint(cp) }
    function battery(d) { return d.batteryAvailable ? Math.round(d.battery * 100) + "%" : "" }
    function codec(d) {
        if (!d.connected || !d.address) return ""
        const key = d.address.replace(/:/g, "_").toUpperCase()
        const n = root.btNodes.find(n => n.name.toUpperCase().includes(key))
        const c = n && n.properties ? n.properties["api.bluez5.codec"] : ""
        return c ? String(c).toUpperCase().replace("_", "-") : ""
    }
    function details(d) {   // "Connected  ·  85%  ·  AAC"
        return ["Connected", battery(d), codec(d)].filter(x => x).join("  ·  ")
    }

    function toggle(d) {
        if (d.connected) d.disconnect()
        else d.connect()
    }

    function pairAndConnect(d) {
        statusText = "Pairing with " + d.name + "…"
        d.trusted = true      // reconecta sozinho no futuro
        d.pair()
    }

    // ---------- na barra ----------
    visible: adapter !== null
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    Text {
        id: icon
        anchors.centerIn: parent
        // nf-md-bluetooth_off / bluetooth_connect / bluetooth
        text: !root.btOn ? root.glyph(0xF00B2)
            : root.connected.length > 0 ? root.glyph(0xF00B1) : root.glyph(0xF00AF)
        color: !root.btOn ? Theme.overlay
             : popup.visible || barMouse.containsMouse || root.connected.length > 0 ? Theme.accent : Theme.fg
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
        onClicked: Popups.toggle(popup)
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
        implicitWidth: 340
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        // a busca por dispositivos gasta bateria dos aparelhos próximos: só com o painel aberto
        onVisibleChanged: {
            root.statusText = ""
            if (root.adapter) root.adapter.discovering = visible && root.btOn
        }

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

                // --- cabeçalho: título, busca e liga/desliga ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        text: "Bluetooth"
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }
                    Text {
                        visible: root.btOn
                        text: root.adapter && root.adapter.discovering ? "scanning…" : ""
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 3
                    }

                    // interruptor em contorno
                    Rectangle {
                        implicitWidth: 34
                        implicitHeight: 18
                        radius: 9
                        color: "transparent"
                        border.width: 1.5
                        border.color: root.btOn ? Theme.accent : Theme.overlay

                        Rectangle {
                            width: 10; height: 10; radius: 5
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.btOn ? parent.width - width - 4 : 4
                            color: root.btOn ? Theme.accent : Theme.overlay
                            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!root.adapter) return
                                root.adapter.enabled = !root.adapter.enabled
                                root.adapter.discovering = root.adapter.enabled
                            }
                        }
                    }
                }

                Text {
                    visible: !root.btOn
                    text: "Bluetooth is off"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                }

                // --- meus dispositivos ---
                Text {
                    visible: root.btOn && root.paired.length > 0
                    Layout.topMargin: 4
                    text: "My Devices"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }

                Repeater {
                    model: root.btOn ? root.paired : []

                    Rectangle {
                        id: dev
                        required property var modelData
                        readonly property bool busy: modelData.pairing === true
                        Layout.fillWidth: true
                        implicitHeight: 40
                        radius: Theme.buttonRadius
                        color: devMouse.containsMouse ? Theme.hover : "transparent"
                        border.width: dev.modelData.connected ? 1 : 0
                        border.color: Theme.accent

                        MouseArea {
                            id: devMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggle(dev.modelData)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10

                            // ícone do tipo de dispositivo (fones, mouse, teclado…), se o tema de ícones tiver
                            Item {
                                Layout.preferredWidth: 20
                                Layout.preferredHeight: 20
                                readonly property string src: dev.modelData.icon ? Quickshell.iconPath(dev.modelData.icon, true) : ""
                                IconImage { anchors.fill: parent; visible: parent.src !== ""; source: parent.src }
                                Text {
                                    anchors.centerIn: parent
                                    visible: parent.src === ""
                                    text: root.glyph(0xF00AF)
                                    color: dev.modelData.connected ? Theme.accent : Theme.dim
                                    font.family: Theme.iconFont
                                    font.pixelSize: Theme.fontSize + 2
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text {
                                    Layout.fillWidth: true
                                    text: dev.modelData.name
                                    color: Theme.fg
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 1
                                    font.bold: dev.modelData.connected
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: dev.modelData.connected ? root.details(dev.modelData) : "Not connected"
                                    color: dev.modelData.connected ? Theme.good : Theme.dim
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 3
                                }
                            }

                            // esquecer (aparece ao passar o mouse)
                            Text {
                                visible: devMouse.containsMouse || forgetMouse.containsMouse
                                text: "×"
                                color: forgetMouse.containsMouse ? Theme.crit : Theme.dim
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize + 4
                                MouseArea {
                                    id: forgetMouse
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: dev.modelData.forget()
                                }
                            }
                        }
                    }
                }

                // --- outros dispositivos ---
                Text {
                    visible: root.btOn
                    Layout.topMargin: 4
                    text: root.others.length > 0 ? "Other Devices" : "Looking for devices nearby…"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }

                Repeater {
                    model: root.btOn ? root.others : []

                    Rectangle {
                        id: other
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: Theme.buttonRadius
                        color: otherMouse.containsMouse ? Theme.hover : "transparent"

                        // depois de parear, conecta sozinho
                        Connections {
                            target: other.modelData
                            function onPairedChanged() {
                                if (other.modelData.paired) {
                                    root.statusText = ""
                                    other.modelData.connect()
                                }
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10
                            Text {
                                text: root.glyph(0xF00AF)
                                color: Theme.dim
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize
                            }
                            Text {
                                Layout.fillWidth: true
                                text: other.modelData.name
                                color: Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 1
                                elide: Text.ElideRight
                            }
                            Text {
                                text: other.modelData.pairing === true ? "pairing…" : "Pair"
                                color: Theme.accent
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                            }
                        }

                        MouseArea {
                            id: otherMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.pairAndConnect(other.modelData)
                        }
                    }
                }

                // --- status ---
                Text {
                    visible: root.statusText !== ""
                    Layout.fillWidth: true
                    text: root.statusText
                    wrapMode: Text.Wrap
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 2
                }
            }
        }
    }
}
