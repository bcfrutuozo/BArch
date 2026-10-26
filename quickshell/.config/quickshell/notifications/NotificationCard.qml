// NotificationCard.qml — um cartão de notificação (usado nos balões e na central).
// Clique no cartão: abre o app (no navegador, vai para a aba que notificou).
// × (ou botão do meio): no balão, só tira da tela; na central, apaga do histórico.
// Botões: ações que o app ofereceu (enquanto a notificação está aberta). No balão, o mouse em cima pausa o tempo.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import "../theme"
import "."

Rectangle {
    id: card

    required property var entry          // entrada do histórico (Notifs)
    property bool popup: false              // balão (com tempo) ou item da central
    readonly property bool alive: entry !== null && entry !== undefined
    readonly property bool critical: alive && entry.critical
    readonly property string iconSource: alive ? Notifs.iconFor(entry) : ""
    readonly property int timeout: alive && popup ? Notifs.timeoutFor(entry) : 0

    implicitHeight: content.implicitHeight + 24
    radius: popup ? Theme.popupRadius : Theme.cardRadius
    color: popup ? Theme.bg : (hover.hovered ? Theme.hover : "transparent")
    border.width: popup || critical ? 1 : 0
    border.color: critical ? Theme.crit : Theme.border
    clip: true

    function glyph(cp) { return String.fromCodePoint(cp) }
    function bodyHtml(b) { return (b || "").replace(/\n/g, "<br>") }
    function close() {
        if (!alive) return
        if (popup) Notifs.hidePopup(entry)
        else Notifs.remove(entry)
    }

    // hover do cartão inteiro (inclusive em cima dos botões)
    HoverHandler { id: hover }

    MouseArea {
        id: mouse
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: ev => {
            if (!card.alive) return
            if (ev.button === Qt.MiddleButton) card.close()
            else Notifs.activate(card.entry)
        }
    }

    // ---------- tempo do balão ----------
    // contagem regressiva em passos de 100 ms; pausa com o mouse em cima
    property real remaining: timeout
    readonly property real progress: timeout > 0 ? Math.max(0, remaining / timeout) : 1
    onTimeoutChanged: remaining = timeout
    Timer {
        interval: 100
        repeat: true
        running: card.popup && card.timeout > 0 && !hover.hovered
        onTriggered: {
            card.remaining -= interval
            if (card.remaining <= 0) {
                stop()
                if (card.alive) Notifs.hidePopup(card.entry)
            }
        }
    }

    RowLayout {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 12

        // ícone / imagem
        Item {
            Layout.alignment: Qt.AlignTop
            implicitWidth: 40
            implicitHeight: 40

            ClippingRectangle {
                anchors.fill: parent
                radius: 10
                color: "transparent"
                visible: card.iconSource !== "" && img.status !== Image.Error
                IconImage {
                    id: img
                    anchors.fill: parent
                    source: card.iconSource
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: 10
                visible: card.iconSource === "" || img.status === Image.Error
                color: Theme.surface
                Text {
                    anchors.centerIn: parent
                    text: card.glyph(0xF009C)        // bell_outline
                    color: card.critical ? Theme.crit : Theme.accent
                    font.family: Theme.iconFont
                    font.pixelSize: 20
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            // app · horário        ×
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Text {
                    Layout.fillWidth: true
                    text: card.alive ? (card.entry.appName || "Notification")
                          + (Notifs.tick >= 0 ? "  ·  " + Notifs.timeText(card.entry) : "") : ""
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                }
                Text {
                    text: "×"
                    color: closeMouse.containsMouse ? Theme.crit : Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize + 3
                    opacity: hover.hovered || !card.popup ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.close()
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: card.alive ? card.entry.summary : ""
                color: Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize
                font.bold: true
                elide: Text.ElideRight
                textFormat: Text.PlainText
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: card.alive ? card.bodyHtml(card.entry.body) : ""
                color: Theme.fg
                opacity: 0.85
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 1
                textFormat: Text.StyledText
                wrapMode: Text.Wrap
                maximumLineCount: card.popup ? 4 : 6
                elide: Text.ElideRight
            }

            // ações do app (a "default" é o clique no cartão)
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 6
                visible: actionRepeater.count > 0

                Repeater {
                    id: actionRepeater
                    model: card.alive ? Notifs.actionsOf(card.entry) : []

                    Rectangle {
                        id: btn
                        required property var modelData
                        implicitWidth: btnLabel.implicitWidth + 20
                        implicitHeight: 26
                        radius: Theme.buttonRadius
                        color: btnMouse.containsMouse ? Theme.hover : "transparent"
                        border.width: 1
                        border.color: btnMouse.containsMouse ? Theme.accent : Theme.border
                        Text {
                            id: btnLabel
                            anchors.centerIn: parent
                            text: btn.modelData.text
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                        }
                        MouseArea {
                            id: btnMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (card.alive) Notifs.invokeAction(card.entry, btn.modelData)
                        }
                    }
                }
            }
        }
    }

    // barra de tempo (só no balão)
    Rectangle {
        visible: card.popup && card.timeout > 0
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 12; bottomMargin: 6 }
        width: (parent.width - 24) * card.progress
        height: 2
        radius: 1
        color: card.critical ? Theme.crit : Theme.accent
        opacity: 0.6
    }
}
