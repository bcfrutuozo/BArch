// ClipboardWidget.qml — histórico da área de transferência para a barra do Quickshell
// Clique no ícone (ou Super+V, via IPC) abre a lista do que foi copiado, com busca.
// Clique ou Enter copia o item de volta; × apaga um item; "Clear All" apaga o histórico.
// Depende do cliphist (guardando o histórico) e do wl-clipboard.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
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
    property color crit: Theme.crit
    property color bg: Theme.bg
    property color border: Theme.border
    property color hover: Theme.hover
    property string fontFamily: Theme.font
    property int fontSize: Theme.fontSize
    property int maxItems: 100

    // ---------- estado ----------
    property var entries: []        // [{ line, text, isImage }]
    property string filter: ""
    property bool confirmWipe: false

    // A barra libera o teclado enquanto o painel está aberto (para a busca)
    readonly property bool wantsKeyboard: popup.visible

    readonly property var filtered: filter === "" ? entries
        : entries.filter(e => e.text.toLowerCase().includes(filter.toLowerCase()))

    function glyph(cp) { return String.fromCodePoint(cp) }
    function toggle() { Popups.toggle(popup) }
    function refresh() { listProc.running = true }

    // O item vai para o cliphist como a linha completa ("id<TAB>prévia"), via argumento,
    // então nenhum conteúdo copiado é interpretado pelo shell.
    function copy(e) {
        Quickshell.execDetached(["sh", "-c", 'printf "%s" "$1" | cliphist decode | wl-copy', "sh", e.line])
        Popups.hide(popup)
    }

    function remove(e) {
        actionProc.command = ["sh", "-c", 'printf "%s\\n" "$1" | cliphist delete', "sh", e.line]
        actionProc.running = true
    }

    function wipe() {
        actionProc.command = ["cliphist", "wipe"]
        actionProc.running = true
        confirmWipe = false
    }

    // ---------- processos ----------
    Process {
        id: listProc
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                for (const line of text.split("\n")) {
                    const tab = line.indexOf("\t")
                    if (tab < 0) continue
                    const preview = line.slice(tab + 1)
                    // imagens aparecem como "[[ binary data 1.2 MiB png 1920x1080 ]]"
                    const img = preview.match(/^\[\[ binary data (.+?) \]\]$/)
                    out.push({
                        line: line,
                        text: img ? "Image · " + img[1] : preview.replace(/\s+/g, " ").trim(),
                        isImage: img !== null
                    })
                    if (out.length >= root.maxItems) break
                }
                root.entries = out
            }
        }
    }

    Process {
        id: actionProc
        onExited: root.refresh()
    }

    // Atalho de teclado: qs ipc call clipboard toggle
    IpcHandler {
        target: "clipboard"
        function toggle(): void { root.toggle() }
    }

    // ---------- na barra ----------
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    Text {
        id: icon
        anchors.centerIn: parent
        text: root.glyph(0xF014C)   // nf-md-clipboard_outline
        color: popup.visible ? root.accent
             : iconMouse.containsMouse ? root.fg : root.dim
        font.family: root.fontFamily
        font.pixelSize: root.fontSize + 2
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    MouseArea {
        id: iconMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggle()
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
        implicitWidth: 400
        implicitHeight: panel.implicitHeight + 24
        color: "transparent"

        onVisibleChanged: {
            if (visible) {
                root.filter = ""
                root.confirmWipe = false
                search.text = ""
                list.currentIndex = 0
                root.refresh()
                search.forceActiveFocus()
            }
        }

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
                anchors.margins: 12
                spacing: 8

                // --- busca ---
                TextField {
                    id: search
                    Layout.fillWidth: true
                    placeholderText: "Search history…"
                    placeholderTextColor: root.dim
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    leftPadding: 12
                    rightPadding: 12
                    topPadding: 8
                    bottomPadding: 8
                    background: Rectangle {
                        radius: 10
                        color: root.hover
                        border.color: search.activeFocus ? root.accent : "transparent"
                    }

                    onTextChanged: { root.filter = text; list.currentIndex = 0 }
                    Keys.onDownPressed: list.incrementCurrentIndex()
                    Keys.onUpPressed: list.decrementCurrentIndex()
                    Keys.onEscapePressed: Popups.hide(popup)
                    onAccepted: {
                        const e = root.filtered[list.currentIndex]
                        if (e) root.copy(e)
                    }
                }

                // --- lista ---
                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 420)
                    clip: true
                    spacing: 2
                    model: root.filtered
                    highlightMoveDuration: 0

                    delegate: Rectangle {
                        id: entry
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: 34
                        radius: 8
                        color: entry.ListView.isCurrentItem ? root.hover : "transparent"

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: list.currentIndex = entry.index
                            onClicked: root.copy(entry.modelData)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 8
                            spacing: 8

                            Text {
                                visible: entry.modelData.isImage
                                text: root.glyph(0xF02E9)   // nf-md-image
                                color: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize + 1
                            }
                            Text {
                                Layout.fillWidth: true
                                text: entry.modelData.text
                                color: entry.modelData.isImage ? root.dim : root.fg
                                elide: Text.ElideRight
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize
                            }
                            Text {
                                visible: entry.ListView.isCurrentItem
                                text: "×"
                                color: delMouse.containsMouse ? root.crit : root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize + 4
                                MouseArea {
                                    id: delMouse
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.remove(entry.modelData)
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: root.filtered.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    Layout.bottomMargin: 8
                    horizontalAlignment: Text.AlignHCenter
                    text: root.entries.length === 0 ? "Nothing copied yet" : "No results"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 1
                }

                // --- rodapé ---
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: root.entries.length + (root.entries.length === 1 ? " item" : " items")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 2
                    }
                    Rectangle {
                        visible: root.entries.length > 0
                        implicitWidth: wipeText.implicitWidth + 20
                        implicitHeight: 26
                        radius: 8
                        color: root.confirmWipe ? root.crit
                             : wipeMouse.containsMouse ? root.hover : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }

                        Text {
                            id: wipeText
                            anchors.centerIn: parent
                            text: root.confirmWipe ? "Confirm?" : "Clear All"
                            color: root.confirmWipe ? root.bg : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 2
                            font.bold: root.confirmWipe
                        }
                        MouseArea {
                            id: wipeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.confirmWipe ? root.wipe() : root.confirmWipe = true
                        }
                    }
                }
            }
        }
    }
}
