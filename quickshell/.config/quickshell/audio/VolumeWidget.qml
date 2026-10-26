// VolumeWidget.qml — controle de áudio para a barra do Quickshell (PipeWire)
// Na barra: ícone + porcentagem da saída padrão.
//   Rolar: ±5% (Shift: ±1%) · Clique do meio: silenciar · Clique direito: mixer completo
// Clique esquerdo: painel com volume da saída, troca de dispositivo,
// volume por aplicativo e microfone.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
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
    property color crit: Theme.crit
    property color bg: Theme.bg
    property color border: Theme.border
    property color hover: Theme.hover
    property color track: Theme.track
    property string fontFamily: Theme.font
    property int fontSize: Theme.fontSize
    // ---------- comportamento ----------
    property real maxVolume: 1.0           // 1.5 permite passar de 100%
    property var mixer: ["pavucontrol"]

    // ---------- dados do PipeWire ----------
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property bool ready: sink !== null && sink.audio !== null
    readonly property real level: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : false

    readonly property var nodes: Pipewire.nodes.values
    // dispositivos de saída (caixas, headset, AirPods, HDMI…)
    readonly property var sinks: nodes.filter(n => n.audio && n.isSink && !n.isStream)
    // apps tocando som agora
    readonly property var streams: nodes.filter(n => n.audio && n.isStream
        && n.properties && n.properties["media.class"] === "Stream/Output/Audio")

    // Necessário para o Quickshell acompanhar volume e mudo desses nós
    PwObjectTracker {
        objects: [root.sink, root.source].concat(root.sinks, root.streams).filter(o => o)
    }

    // ---------- ações ----------
    function setVolume(node, v) {
        if (!node || !node.audio) return
        node.audio.volume = Math.round(Math.max(0, Math.min(maxVolume, v)) * 100) / 100
        if (v > 0 && node.audio.muted) node.audio.muted = false   // mexer no volume tira do mudo
    }
    function toggleMute(node) {
        if (node && node.audio) node.audio.muted = !node.audio.muted
    }
    function nodeName(n) { return n ? (n.description || n.nickname || n.name || "") : "" }
    function appName(n) { return (n.properties && n.properties["application.name"]) || n.name || "Application" }
    function appIcon(n) {
        const p = n.properties || {}
        const icon = p["application.icon-name"] || p["application.process.binary"] || ""
        return icon ? Quickshell.iconPath(icon, true) : ""
    }

    // ---------- ícones (Material Design, via Nerd Font) ----------
    function glyph(cp) { return String.fromCodePoint(cp) }
    function volGlyph(v, m) {
        if (m || v === 0) return glyph(0xF0581)   // volume_off
        if (v < 0.34) return glyph(0xF057F)       // volume_low
        if (v < 0.67) return glyph(0xF0580)       // volume_medium
        return glyph(0xF057E)                     // volume_high
    }
    // Na barra: alto-falante em traço fino (octicons); o nível já aparece na porcentagem
    function barGlyph(v, m) { return (m || v === 0) ? glyph(0xF466) : glyph(0xF485) }  // oct-mute / oct-unmute
    function micGlyph(m) { return m ? glyph(0xF036D) : glyph(0xF036C) }
    function pct(v) { return Math.round(v * 100) + "%" }

    visible: ready
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    // ---------- na barra ----------
    Row {
        id: barRow
        spacing: 5

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.barGlyph(root.level, root.muted)
            color: root.muted ? root.dim
                 : popup.visible || barMouse.containsMouse ? root.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: root.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.muted ? "muted" : root.pct(root.level)
            color: root.muted ? root.dim : root.fg
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
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) Quickshell.execDetached(root.mixer)
            else if (mouse.button === Qt.MiddleButton) root.toggleMute(root.sink)
            else Popups.toggle(popup)
        }
        onWheel: wheel => {
            const d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
            const step = (wheel.modifiers & Qt.ShiftModifier) ? 0.01 : 0.05
            root.setVolume(root.sink, root.level + (d > 0 ? step : -step))
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
        implicitWidth: 340
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
                spacing: 10

                // ===== Saída =====
                Text {
                    Layout.fillWidth: true
                    text: root.nodeName(root.sink)
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    font.bold: true
                    elide: Text.ElideRight
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        text: root.volGlyph(root.level, root.muted)
                        color: root.muted ? root.dim : root.accent
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize + 4
                        Layout.preferredWidth: 22
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleMute(root.sink)
                        }
                    }
                    VolumeSlider {
                        Layout.fillWidth: true
                        widget: root
                        value: root.level / root.maxVolume
                        muted: root.muted
                        onMoved: v => root.setVolume(root.sink, v * root.maxVolume)
                    }
                    Text {
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                        text: root.pct(root.level)
                        color: root.muted ? root.dim : root.fg
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                    }
                }

                // ===== Dispositivos de saída (só aparece com mais de um) =====
                ColumnLayout {
                    visible: root.sinks.length > 1
                    Layout.fillWidth: true
                    spacing: 2

                    Text {
                        text: "Output"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 2
                        Layout.topMargin: 4
                        Layout.bottomMargin: 2
                    }

                    Repeater {
                        model: root.sinks

                        Rectangle {
                            id: dev
                            required property var modelData
                            readonly property bool current: modelData === root.sink
                            Layout.fillWidth: true
                            implicitHeight: 30
                            radius: 8
                            color: devMouse.containsMouse ? root.hover : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 8
                                Text {
                                    Layout.fillWidth: true
                                    text: root.nodeName(dev.modelData)
                                    color: dev.current ? root.fg : root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 1
                                    font.bold: dev.current
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: dev.current
                                    text: root.glyph(0xF012C)   // check
                                    color: root.accent
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                }
                            }

                            MouseArea {
                                id: devMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Pipewire.preferredDefaultAudioSink = dev.modelData
                            }
                        }
                    }
                }

                // ===== Aplicativos =====
                ColumnLayout {
                    visible: root.streams.length > 0
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        text: "Applications"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 2
                        Layout.topMargin: 4
                    }

                    Repeater {
                        model: root.streams

                        RowLayout {
                            id: app
                            required property var modelData
                            readonly property bool appMuted: modelData.audio ? modelData.audio.muted : false
                            readonly property real appLevel: modelData.audio ? modelData.audio.volume : 0
                            readonly property string iconSrc: root.appIcon(modelData)
                            Layout.fillWidth: true
                            spacing: 10

                            // ícone do app; clique silencia só esse app
                            Item {
                                Layout.preferredWidth: 22
                                Layout.preferredHeight: 22
                                opacity: app.appMuted ? 0.4 : 1

                                IconImage {
                                    anchors.fill: parent
                                    visible: app.iconSrc !== ""
                                    source: app.iconSrc
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: app.iconSrc === ""
                                    text: root.volGlyph(app.appLevel, app.appMuted)
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize + 2
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleMute(app.modelData)
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    Layout.fillWidth: true
                                    text: root.appName(app.modelData)
                                    color: app.appMuted ? root.dim : root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 1
                                    elide: Text.ElideRight
                                }
                                VolumeSlider {
                                    Layout.fillWidth: true
                                    widget: root
                                    value: app.appLevel / root.maxVolume
                                    muted: app.appMuted
                                    onMoved: v => root.setVolume(app.modelData, v * root.maxVolume)
                                }
                            }

                            Text {
                                Layout.preferredWidth: 40
                                horizontalAlignment: Text.AlignRight
                                text: root.pct(app.appLevel)
                                color: app.appMuted ? root.dim : root.fg
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 1
                            }
                        }
                    }
                }

                // ===== Microfone =====
                ColumnLayout {
                    visible: hasMic
                    Layout.fillWidth: true
                    spacing: 4

                    id: mic
                    readonly property bool hasMic: root.source !== null && root.source.audio !== null
                    readonly property bool micMuted: hasMic ? root.source.audio.muted : false
                    readonly property real micLevel: hasMic ? root.source.audio.volume : 0

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        text: "Microphone · " + root.nodeName(root.source)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 2
                        elide: Text.ElideRight
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Text {
                            text: root.micGlyph(mic.micMuted)
                            color: mic.micMuted ? root.crit : root.accent
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize + 4
                            Layout.preferredWidth: 22
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -4
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleMute(root.source)
                            }
                        }
                        VolumeSlider {
                            Layout.fillWidth: true
                            widget: root
                            value: mic.micLevel
                            muted: mic.micMuted
                            onMoved: v => root.setVolume(root.source, v)
                        }
                        Text {
                            Layout.preferredWidth: 40
                            horizontalAlignment: Text.AlignRight
                            text: root.pct(mic.micLevel)
                            color: mic.micMuted ? root.dim : root.fg
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                        }
                    }
                }

                // ===== rodapé =====
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    implicitHeight: 30
                    radius: 8
                    color: mixMouse.containsMouse ? root.hover : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "Advanced Mixer"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 1
                    }
                    MouseArea {
                        id: mixMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Popups.hide(popup)
                            Quickshell.execDetached(root.mixer)
                        }
                    }
                }
            }
        }
    }
}
