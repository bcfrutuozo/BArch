// Widget de AirPods para Quickshell.
// Fica na mesma pasta que Service.qml e Model.js (copiados do omarchy-pods).
// Clique esquerdo: abre/fecha o painel. Clique direito: alterna o modo de escuta.

import QtQuick
import QtQuick.Layouts
import Quickshell
import "Model.js" as Model
import "../theme"

Item {
    id: root

    // Ilha da barra onde o widget está (primeiro ancestral com "radius"); os painéis se alinham a ela
    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    // ---- Tema: troque pelos valores da sua UI ----
    property color fg: Theme.fg
    property color dim: Theme.dim
    property color accent: Theme.good
    property color bg: Theme.bg
    property color border: Theme.border
    property string fontFamily: Theme.font
    property int fontSize: Theme.fontSize
    property int radius: Theme.popupRadius

    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight
    // Some da barra quando não há AirPods (mesmo padrão do plugin original).
    visible: pods.hasAirPods || pods.hasBattery

    Service {
        id: pods
        settings: ({ ctlPath: Quickshell.env("HOME") + "/.local/bin/librepods-ctl" })
    }

    // Menor bateria conhecida entre os dois fones (ou a do headset, no AirPods Max).
    readonly property int barLevel: {
        if (pods.isHeadset) return pods.headsetBattery.level
        const l = pods.leftPod.level, r = pods.rightPod.level
        if (l === Model.LEVEL_UNKNOWN) return r
        if (r === Model.LEVEL_UNKNOWN) return l
        return Math.min(l, r)
    }
    readonly property var modes: Model.availableModes(
        pods.supportsNoiseControl, pods.supportsNoiseOff, pods.supportsAdaptive)

    // ---- Item da barra ----
    // Ícone e bateria separados, com o mesmo espaçamento e tamanho do volume
    Row {
        id: pill
        spacing: 5

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String.fromCodePoint(0xF1852)   // nf-md-earbuds_outline
            color: pods.connected ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontSize + 2
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Model.levelText(root.barLevel)
            color: pods.connected ? root.fg : root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) pods.cycleNoiseMode()
            else Popups.toggle(popup)
        }
    }

    // ---- Componentes reutilizados no painel ----
    component Label: Text {
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
    }

    // Linha clicável com marcador de "ativo".
    component Entry: Rectangle {
        id: entry
        property string label: ""
        property string value: ""
        property bool active: false
        signal activated()

        Layout.fillWidth: true
        implicitHeight: 30
        radius: 6
        color: hover.containsMouse ? root.border : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            Label { text: entry.label; color: entry.active ? root.accent : root.fg; Layout.fillWidth: true }
            Label { text: entry.value !== "" ? entry.value : (entry.active ? "●" : ""); color: entry.active ? root.accent : root.dim }
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: entry.activated()
        }
    }

    component Battery: ColumnLayout {
        property string label: ""
        property int level: Model.LEVEL_UNKNOWN
        property string meta: ""
        spacing: 2
        Layout.fillWidth: true
        Label { text: label; color: root.dim; Layout.alignment: Qt.AlignHCenter }
        Label { text: Model.levelText(level); font.pixelSize: root.fontSize + 4; Layout.alignment: Qt.AlignHCenter }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 4
            radius: 2
            color: root.border
            Rectangle {
                width: parent.width * Model.levelFraction(level)
                height: parent.height
                radius: 2
                color: level !== Model.LEVEL_UNKNOWN && level <= 20 ? Theme.crit : root.accent
            }
        }
        Label { text: meta; color: root.dim; font.pixelSize: root.fontSize - 2; Layout.alignment: Qt.AlignHCenter }
    }

    component Divider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: root.border
    }

    // ---- Painel ----
    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        // só um painel aberto por vez na barra
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        // ponto de ancoragem: canto inferior direito da ilha, popupGap abaixo dela;
        // o painel cresce para a esquerda e para baixo a partir dali
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 300
        implicitHeight: body.implicitHeight + 24
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            color: root.bg
            border.color: root.border
            border.width: 1
            radius: root.radius

            ColumnLayout {
                id: body
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                // Cabeçalho
                Label { text: pods.deviceName !== "" ? pods.deviceName : "AirPods"; font.bold: true }
                Label {
                    text: pods.modelName + (Model.lidText(pods.lidState) !== "" ? "  ·  case " + (pods.lidState === Model.LID_OPEN ? "open" : "closed") : "")
                    color: root.dim
                    visible: pods.modelName !== ""
                }

                // Baterias
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    visible: !pods.isHeadset
                    Battery { label: "Left"; level: pods.leftPod.level; meta: pods.leftPod.charging ? "charging" : (pods.leftPod.inEar ? "in ear" : "") }
                    Battery { label: "Right"; level: pods.rightPod.level; meta: pods.rightPod.charging ? "charging" : (pods.rightPod.inEar ? "in ear" : "") }
                    Battery { label: "Case"; level: pods.caseBattery.level; meta: pods.caseBattery.charging ? "charging" : "" }
                }
                Battery {
                    visible: pods.isHeadset
                    label: "Battery"
                    level: pods.headsetBattery.level
                    meta: pods.headsetBattery.charging ? "charging" : ""
                }

                // Modos de escuta (só os que o modelo tem)
                Divider { visible: pods.hasAirPods && root.modes.length > 0 }
                Repeater {
                    model: pods.hasAirPods ? root.modes : []
                    delegate: Entry {
                        required property int modelData
                        label: ({ 0: "Off", 1: "Noise Cancellation", 2: "Transparency", 3: "Adaptive" })[modelData]
                        active: pods.noiseMode === modelData
                        onActivated: pods.setNoiseMode(modelData)
                    }
                }

                // Nível do ruído adaptativo, só com o modo Adaptativo ativo
                RowLayout {
                    Layout.fillWidth: true
                    visible: pods.hasAirPods && pods.noiseMode === Model.NOISE_ADAPTIVE
                    Label { text: "Adaptive Level"; Layout.fillWidth: true; Layout.leftMargin: 8 }
                    Entry { Layout.fillWidth: false; implicitWidth: 30; label: "−"; onActivated: pods.setAdaptiveNoiseLevel(pods.adaptiveNoiseLevel - 10) }
                    Label { text: pods.adaptiveNoiseLevel + "%"; horizontalAlignment: Text.AlignHCenter; Layout.preferredWidth: 44 }
                    Entry { Layout.fillWidth: false; implicitWidth: 30; label: "+"; onActivated: pods.setAdaptiveNoiseLevel(pods.adaptiveNoiseLevel + 10) }
                }

                // Opções
                Divider { visible: pods.hasAirPods }
                Entry {
                    visible: pods.hasAirPods && pods.supportsConversationalAwareness
                    label: "Conversation Awareness"
                    value: pods.conversationalAwareness ? "on" : "off"
                    active: pods.conversationalAwareness
                    onActivated: pods.setConversationalAwareness(!pods.conversationalAwareness)
                }
                Entry {
                    visible: pods.hasAirPods && pods.supportsOneBudANC
                    label: "ANC with one AirPod"
                    value: pods.oneBudANC ? "on" : "off"
                    active: pods.oneBudANC
                    onActivated: pods.setOneBudANC(!pods.oneBudANC)
                }
                Entry {
                    visible: pods.hasAirPods
                    label: "Ear Detection"
                    value: ({ 0: "pause when one is removed", 1: "pause when both are removed", 2: "never pause" })[pods.earDetectionBehavior] || ""
                    onActivated: pods.cycleEarDetection()
                }

                // Estados e erros
                Label {
                    visible: !pods.hasAirPods
                    text: "Disconnected (battery via BLE)"
                    color: root.dim
                }
                Label {
                    visible: pods.actionStatus !== "" || pods.lastError !== ""
                    text: pods.actionStatus !== "" ? pods.actionStatus : pods.lastError
                    color: Theme.crit
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
        }
    }
}
