// DiskWidget.qml — pontos de montagem na barra do Quickshell
// Na barra: ícone de disco, amarelo/vermelho quando algum disco está enchendo.
// Clique: painel com cada sistema de arquivos (nome, disco, tipo, pontos de montagem,
// barra de uso, usado/total/livre). Clicar num item abre a pasta no gerenciador de arquivos.
// Depende do disk-info.sh (nesta mesma pasta), findmnt, df, lsblk e jq.

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
    property color hover: Theme.hover
    property color track: Theme.track
    property string fontFamily: Theme.font
    property int fontSize: Theme.fontSize
    // ---------- comportamento ----------
    property var usageLimits: [80, 90]    // % de uso: aviso, crítico
    property int refreshInterval: 60000   // ms (o painel também atualiza ao abrir)

    // ---------- estado ----------
    property var disks: []
    property var expandedDevs: ({})
    property date updatedAt: new Date()

    // mesma conta do df: ignora o espaço reservado do sistema de arquivos
    function usage(d) { return d.used + d.avail > 0 ? d.used / (d.used + d.avail) : 0 }
    function level(d) {
        if (d.stale) return 1
        if (d.readonly) return 0   // imagens somente leitura estão sempre "cheias"
        const p = usage(d) * 100
        return p >= usageLimits[1] ? 2 : p >= usageLimits[0] ? 1 : 0
    }
    readonly property int worstLevel: disks.reduce((m, d) => Math.max(m, level(d)), 0)

    function levelColor(l, base) { return l === 2 ? crit : l === 1 ? warn : base }
    function glyph(cp) { return String.fromCodePoint(cp) }

    function bytes(b) {
        const units = ["B", "KB", "MB", "GB", "TB", "PB"]
        let i = 0
        while (b >= 1024 && i < units.length - 1) { b /= 1024; i++ }
        const n = i >= 3 && b < 100 ? b.toFixed(1) : String(Math.round(b))
        return n + " " + units[i]
    }

    function title(d) {
        const t = d.targets[0]
        if (t === "/") return "System"
        if (t === "/boot" || t === "/efi" || t === "/boot/efi") return "Boot (EFI)"
        return t.split("/").filter(s => s).pop() || t
    }

    function subtitle(d) {
        const parts = []
        if (d.disk) parts.push(d.disk)
        if (d.tran) parts.push(d.tran.toUpperCase())
        parts.push(d.fstype)
        return parts.join(" · ")
    }

    function kindGlyph(d) {
        if (d.network) return glyph(0xF048D)      // nf-md-server_network
        if (d.tran === "usb") return glyph(0xF0553) // nf-md-usb
        return glyph(0xF02CA)                       // nf-md-harddisk
    }

    // ---------- btrfs ----------
    // Metadados cheios sem espaço não alocado é o que causa "disco cheio" no btrfs
    // mesmo com espaço livre aparente, por isso esse é o único alerta da alocação.
    function metadataLevel(b) {
        const m = b.metadata
        if (!m || m.total <= 0) return 0
        const r = m.used / m.total
        const gib = 1073741824
        if (r > 0.9 && b.unallocated < gib) return 2
        if (r > 0.8 && b.unallocated < 2 * gib) return 1
        return 0
    }

    function btrfsSummary(d) {
        const b = d.btrfs
        const parts = ["btrfs"]
        const n = d.subvolumes.length
        parts.push(n + (n === 1 ? " subvolume" : " subvolumes"))
        if (d.compression) parts.push(d.compression)
        if (b.snapshots >= 0) parts.push(b.snapshots + " snapshots")
        if (b.errors > 0) parts.push(b.errors + " errors")
        return parts.join("  ·  ")
    }

    function btrfsHealth(b) {
        if (!b) return ""
        const parts = []
        if (b.label) parts.push("Label: " + b.label)
        parts.push(b.errors < 0 ? "Errors: not exposed by this kernel"
                 : b.errors === 0 ? "No read/write errors"
                 : b.errors + " errors recorded (run btrfs device stats)")
        if (b.snapshots >= 0) parts.push(b.snapshots + " snapshots in /.snapshots")
        return parts.join("  ·  ")
    }

    function toggleExpanded(dev) {
        const m = Object.assign({}, expandedDevs)
        m[dev] = !m[dev]
        expandedDevs = m
    }

    function refresh() { infoProc.running = true }

    Process {
        id: infoProc
        command: ["bash", Quickshell.shellDir + "/disks/disk-info.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.disks = JSON.parse(text)
                    root.updatedAt = new Date()
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ---------- na barra ----------
    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    Text {
        id: icon
        anchors.centerIn: parent
        text: root.glyph(0xF1632)   // nf-md-database_outline (contorno, melhor para OLED)
        color: root.levelColor(root.worstLevel,
               popup.visible || barMouse.containsMouse ? root.accent : root.fg)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize + 2
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
                spacing: 8

                Text {
                    text: "Storage"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize
                    font.bold: true
                }

                Text {
                    visible: root.disks.length === 0
                    text: infoProc.running ? "Loading…" : "No mount points found"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSize - 1
                }

                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 560)
                    clip: true
                    spacing: 4
                    model: root.disks

                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        readonly property var d: modelData
                        readonly property int lvl: root.level(d)
                        readonly property color barColor: lvl === 2 ? root.crit : lvl === 1 ? root.warn : root.accent
                        readonly property var b: d.btrfs || null
                        // guardado por dispositivo, para não fechar quando a lista atualiza
                        readonly property bool expanded: root.expandedDevs[d.dev] === true

                        width: ListView.view.width
                        implicitHeight: body.implicitHeight + 20
                        radius: 10
                        color: cardMouse.containsMouse ? root.hover : "transparent"

                        MouseArea {
                            id: cardMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                Popups.hide(popup)
                                Quickshell.execDetached(["xdg-open", card.d.targets[0]])
                            }
                        }

                        ColumnLayout {
                            id: body
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 5

                            // nome + selos
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: root.kindGlyph(card.d)
                                    color: card.barColor
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize + 3
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.title(card.d)
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: card.d.encrypted
                                    text: root.glyph(0xF033E)   // cadeado
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 1
                                }
                                Text {
                                    visible: card.d.readonly
                                    text: "read-only"
                                    color: root.warn
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 3
                                }
                                Text {
                                    text: card.d.stale ? "not responding" : Math.round(root.usage(card.d) * 100) + "%"
                                    color: card.lvl > 0 ? card.barColor : root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                    font.bold: card.lvl > 0
                                }
                            }

                            // disco · conexão · sistema de arquivos
                            Text {
                                Layout.fillWidth: true
                                text: root.subtitle(card.d)
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 2
                                elide: Text.ElideRight
                            }

                            // barra de uso
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                implicitHeight: 6
                                radius: 3
                                color: root.track

                                Rectangle {
                                    height: parent.height
                                    width: parent.width * Math.min(1, root.usage(card.d))
                                    radius: 3
                                    color: card.barColor
                                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                }
                            }

                            // usado / total / livre
                            RowLayout {
                                visible: !card.d.stale
                                Layout.fillWidth: true
                                Text {
                                    Layout.fillWidth: true
                                    text: root.bytes(card.d.used) + " of " + root.bytes(card.d.size)
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 2
                                }
                                Text {
                                    text: root.bytes(card.d.avail) + " free"
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 2
                                }
                            }

                            // pontos de montagem (sistemas que não são btrfs)
                            Text {
                                visible: !card.b
                                Layout.fillWidth: true
                                text: card.d.targets.join("  ·  ")
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: root.fontSize - 3
                                wrapMode: Text.Wrap
                            }

                            // ===== btrfs: resumo clicável que expande os detalhes =====
                            Rectangle {
                                visible: card.b !== null
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                implicitHeight: 24
                                radius: 6
                                color: toggleMouse.containsMouse ? root.border : "transparent"

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    spacing: 6

                                    Text {
                                        Layout.fillWidth: true
                                        text: card.b ? root.btrfsSummary(card.d) : ""
                                        color: card.b && card.b.errors > 0 ? root.crit : root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: root.fontSize - 3
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        // nf-md-chevron_up / chevron_down
                                        text: card.expanded ? root.glyph(0xF0143) : root.glyph(0xF0140)
                                        color: root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: root.fontSize
                                    }
                                }

                                MouseArea {
                                    id: toggleMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleExpanded(card.d.dev)
                                }
                            }

                            Item {
                                visible: card.b !== null && card.expanded
                                Layout.fillWidth: true
                                Layout.leftMargin: 6
                                Layout.rightMargin: 6
                                implicitHeight: details.implicitHeight

                            // cliques nos detalhes não abrem a pasta
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.AllButtons
                            }

                            ColumnLayout {
                                id: details
                                width: parent.width
                                spacing: 6

                                // --- Alocação ---
                                Text {
                                    text: "Allocation"
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 2
                                    font.bold: true
                                }

                                Repeater {
                                    model: card.b ? [
                                        { name: "Data", a: card.b.data, lvl: 0 },
                                        { name: "Metadata", a: card.b.metadata, lvl: root.metadataLevel(card.b) },
                                        { name: "System", a: card.b.system, lvl: 0 }
                                    ] : []

                                    ColumnLayout {
                                        id: allocRow
                                        required property var modelData
                                        readonly property var a: modelData.a
                                        readonly property color tone: modelData.lvl === 2 ? root.crit
                                            : modelData.lvl === 1 ? root.warn : root.accent
                                        Layout.fillWidth: true
                                        spacing: 3

                                        RowLayout {
                                            Layout.fillWidth: true
                                            Text {
                                                Layout.fillWidth: true
                                                text: allocRow.modelData.name
                                                    + (allocRow.a.profile ? "  ·  " + allocRow.a.profile.toUpperCase() : "")
                                                color: root.dim
                                                font.family: root.fontFamily
                                                font.pixelSize: root.fontSize - 3
                                            }
                                            Text {
                                                text: root.bytes(allocRow.a.used) + " / " + root.bytes(allocRow.a.total)
                                                color: allocRow.modelData.lvl > 0 ? allocRow.tone : root.fg
                                                font.family: root.fontFamily
                                                font.pixelSize: root.fontSize - 3
                                            }
                                        }
                                        Rectangle {
                                            Layout.fillWidth: true
                                            implicitHeight: 3
                                            radius: 2
                                            color: root.track
                                            Rectangle {
                                                height: parent.height
                                                width: parent.width * (allocRow.a.total > 0 ? Math.min(1, allocRow.a.used / allocRow.a.total) : 0)
                                                radius: 2
                                                color: allocRow.tone
                                            }
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: "Unallocated: " + root.bytes(card.b ? card.b.unallocated : 0)
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 3
                                }

                                // --- Subvolumes ---
                                Text {
                                    Layout.topMargin: 4
                                    text: "Subvolumes"
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 2
                                    font.bold: true
                                }

                                Repeater {
                                    model: card.d.subvolumes

                                    RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text {
                                            text: root.glyph(0xF024B)   // nf-md-folder
                                            color: root.accent
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fontSize - 2
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: parent.modelData.subvol.replace(/^\//, "") || "(root)"
                                            color: root.fg
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fontSize - 2
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: parent.modelData.target
                                            color: root.dim
                                            font.family: root.fontFamily
                                            font.pixelSize: root.fontSize - 3
                                        }
                                    }
                                }

                                // --- Saúde ---
                                Text {
                                    Layout.topMargin: 4
                                    Layout.fillWidth: true
                                    text: root.btrfsHealth(card.b)
                                    color: card.b && card.b.errors > 0 ? root.crit : root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize - 3
                                    wrapMode: Text.Wrap
                                }
                            }
                            }
                        }
                    }
                }

                // rodapé
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "Updated at " + Qt.formatTime(root.updatedAt, "HH:mm:ss")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSize - 3
                    }
                    Text {
                        text: root.glyph(0xF0450)   // refresh
                        color: refreshMouse.containsMouse ? root.accent : root.dim
                        font.family: root.fontFamily
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
            }
        }
    }
}
