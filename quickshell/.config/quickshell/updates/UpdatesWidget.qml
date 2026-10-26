// UpdatesWidget.qml — atualizações pendentes na barra do Quickshell
// Na barra: ícone com a quantidade de atualizações; fica azul quando há kernel novo
// e gira enquanto a atualização roda.
// Clique: painel com os pacotes (repositórios e AUR), aviso de kernel e botões:
//   "Update All" → terminal com paru -Syu e, se houver kernel novo, o seu script do kernel
//   "Kernel Only"    → terminal só com o script do kernel
// Depende de updates-check.sh e run-update.sh (nesta pasta), pacman-contrib (checkupdates), paru e foot.

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
    property color crit: Theme.crit
    property color bg: Theme.bg
    property color border: Theme.border
    property color hover: Theme.hover
    property string fontFamily: Theme.font
    property string iconFont: Theme.iconFont
    property int fontSize: Theme.fontSize
    // ---------- comportamento ----------
    property string kernelScript: ""                          // caminho absoluto do seu script do kernel
    property string kernelPattern: "^linux-cachyos(-headers)?$" // pacotes que contam como "kernel novo"
    property var terminal: ["foot", "--title", "System Update", "-e"]
    property int checkMinutes: 60

    // ---------- estado ----------
    property var repo: []
    property var aur: []
    property bool kernel: false
    property string errorText: ""
    property date checkedAt: new Date(0)

    readonly property int count: repo.length + aur.length
    readonly property bool updating: runProc.running
    readonly property var kernelPkgs: repo.concat(aur).filter(p => new RegExp(kernelPattern).test(p.name))

    function glyph(cp) { return String.fromCodePoint(cp) }
    function refresh() { if (!checkProc.running && !runProc.running) checkProc.running = true }

    function run(mode) {
        if (runProc.running) return
        Popups.hide(popup)
        runProc.command = root.terminal.concat([
            "bash", Quickshell.shellDir + "/updates/run-update.sh",
            mode, root.kernelScript, root.kernel ? "1" : "0"
        ])
        runProc.running = true
    }

    // ---------- processos ----------
    Process {
        id: checkProc
        command: ["bash", Quickshell.shellDir + "/updates/updates-check.sh", root.kernelPattern]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text)
                    root.repo = r.repo
                    root.aur = r.aur
                    root.kernel = r.kernel
                    root.errorText = r.error
                    root.checkedAt = new Date()
                } catch (e) {
                    root.errorText = "Failed to check for updates"
                }
            }
        }
    }

    // o terminal fica rodando aqui; quando fecha, verifica de novo
    Process {
        id: runProc
        onExited: root.refresh()
    }

    // primeira verificação 1 min após iniciar (dá tempo da rede subir), depois a cada hora
    Timer { interval: 60000; running: true; onTriggered: root.refresh() }
    Timer {
        interval: root.checkMinutes * 60000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    // ---------- na barra ----------
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    Row {
        id: barRow
        spacing: 5

        Text {
            id: barIcon
            anchors.verticalCenter: parent.verticalCenter
            // girando: sync · senão: seta para baixo em círculo (contorno)
            text: root.updating ? root.glyph(0xF04E6) : root.glyph(0xF0CDC)
            color: popup.visible || barMouse.containsMouse || root.updating || root.kernel ? root.accent
                 : root.count > 0 ? root.fg : root.dim
            font.family: root.iconFont
            font.pixelSize: root.fontSize + 2
            Behavior on color { ColorAnimation { duration: 150 } }

            RotationAnimation on rotation {
                running: root.updating
                from: 0; to: -360
                duration: 1600
                loops: Animation.Infinite
                onStopped: barIcon.rotation = 0
            }
        }
        Text {
            visible: root.count > 0 && !root.updating
            anchors.verticalCenter: parent.verticalCenter
            text: root.count
            color: root.kernel ? root.accent : root.fg
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

                // --- cabeçalho ---
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "Updates"
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize
                        font.bold: true
                    }
                    Text {
                        text: checkProc.running ? "checking…"
                            : root.checkedAt.getTime() > 0 ? "checked at " + Qt.formatTime(root.checkedAt, "HH:mm") : ""
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 3
                    }
                    Text {
                        text: root.glyph(0xF0450)   // refresh
                        color: refreshMouse.containsMouse ? root.accent : root.dim
                        font.family: root.iconFont
                        font.pixelSize: root.fontSize
                        MouseArea {
                            id: refreshMouse
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refresh()
                        }
                    }
                }

                // --- aviso de kernel novo ---
                Rectangle {
                    visible: root.kernel
                    Layout.fillWidth: true
                    implicitHeight: kernelCol.implicitHeight + 16
                    radius: 10
                    color: "transparent"
                    border.width: 1
                    border.color: root.accent

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 8
                        anchors.leftMargin: 12
                        spacing: 10

                        Text {
                            text: root.glyph(0xF033D)   // linux
                            color: root.accent
                            font.family: root.iconFont
                            font.pixelSize: root.fontSize + 6
                        }
                        ColumnLayout {
                            id: kernelCol
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                text: "New Kernel"
                                color: root.accent
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 1
                                font.bold: true
                            }
                            Repeater {
                                model: root.kernelPkgs
                                Text {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    text: modelData.name + "  " + modelData.old + " → " + modelData.new
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 3
                                    elide: Text.ElideRight
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.kernelScript !== ""
                                    ? "Will be built by your script after paru."
                                    : "Set kernelScript in shell.qml to build it automatically."
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 3
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                // --- em dia ---
                RowLayout {
                    visible: root.count === 0 && !checkProc.running && root.errorText === ""
                        && root.checkedAt.getTime() > 0
                    spacing: 8
                    Text {
                        text: root.glyph(0xF05E1)   // check_circle_outline
                        color: root.good
                        font.family: root.iconFont
                        font.pixelSize: root.fontSize + 2
                    }
                    Text {
                        text: "System is up to date"
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 1
                    }
                }

                // --- listas de pacotes ---
                Flickable {
                    id: flick
                    visible: root.count > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(lists.implicitHeight, 340)
                    contentHeight: lists.implicitHeight
                    clip: true

                    ColumnLayout {
                        id: lists
                        width: flick.width
                        spacing: 4

                        Repeater {
                            model: [
                                { title: "Repositories", items: root.repo },
                                { title: "AUR", items: root.aur }
                            ]

                            ColumnLayout {
                                id: group
                                required property var modelData
                                visible: modelData.items.length > 0
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.topMargin: 4
                                    text: group.modelData.title + "  (" + group.modelData.items.length + ")"
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 2
                                }

                                Repeater {
                                    model: group.modelData.items

                                    RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            Layout.fillWidth: true
                                            text: parent.modelData.name
                                            color: new RegExp(root.kernelPattern).test(parent.modelData.name) ? root.accent : root.fg
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fontSize - 2
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: parent.modelData.old + " → " + parent.modelData.new
                                                + (parent.modelData.ignored ? "  (ignored)" : "")
                                            color: root.dim
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fontSize - 3
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // --- erro ---
                Text {
                    visible: root.errorText !== ""
                    Layout.fillWidth: true
                    text: root.errorText
                    color: root.crit
                    wrapMode: Text.Wrap
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 2
                }

                // --- ações ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: 9
                        color: allMouse.containsMouse ? root.hover : "transparent"
                        border.width: 1.5
                        border.color: root.accent
                        opacity: root.updating ? 0.4 : 1

                        Text {
                            anchors.centerIn: parent
                            text: root.updating ? "Updating…" : "Update All"
                            color: root.accent
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 1
                            font.bold: true
                        }
                        MouseArea {
                            id: allMouse
                            anchors.fill: parent
                            enabled: !root.updating
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.run("all")
                        }
                    }

                    Rectangle {
                        visible: root.kernelScript !== ""
                        implicitWidth: kText.implicitWidth + 24
                        implicitHeight: 32
                        radius: 9
                        color: kMouse.containsMouse ? root.hover : "transparent"
                        border.width: 1
                        border.color: root.border
                        opacity: root.updating ? 0.4 : 1

                        Text {
                            id: kText
                            anchors.centerIn: parent
                            text: "Kernel Only"
                            color: root.fg
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize - 1
                        }
                        MouseArea {
                            id: kMouse
                            anchors.fill: parent
                            enabled: !root.updating
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.run("kernel")
                        }
                    }
                }
            }
        }
    }
}
