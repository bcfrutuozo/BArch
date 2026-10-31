// Launcher.qml — lançador no visual da barra (substitui o hyprlauncher).
//
// Abre no monitor em foco com:  qs ipc call launcher toggle
//   (nada)   apps: nome, nome genérico, palavras-chave e descrição; os mais usados sobem.
//            Contas simples (2^10, 1500*0,15) resolvem na hora. Lock, Reboot etc. também aparecem.
//   w ...    janelas abertas (mais recentes primeiro); Enter foca a janela.
//   c ...    histórico do clipboard (cliphist), com miniatura das imagens; Enter copia de volta.
//   p ...    projetos (repositórios git em projectRoots); Enter abre no Neovim, Shift+Enter no Thunar.
//   / ...    arquivos da pasta pessoal pelo nome (fd); Enter abre, Shift+Enter abre a pasta.
//   : ...    emojis; Enter copia, Shift+Enter digita no app (precisa do wtype).
//   ? ...    pesquisa na web (ou abre o endereço, se for um link).
//   a ...    fala com o Claude (barch agent ask): Enter abre uma conversa nova no ~/BArch já com o
//            texto; Shift+Enter continua a última conversa de lá.
//   b ...    papéis de parede (as cenas de ~/Pictures/Wallpapers, wallpaper/Wallpapers.qml); Enter
//            pergunta onde aplicar (desktop e lock, só desktop, só lock), Shift+Enter aplica nos dois.
//   = ...    calculadora qalc (unidades e conversões: "= 5 km to mi"); Enter copia.
//   > ...    roda um comando; Shift+Enter roda no terminal e mantém aberto.
// Teclas: ↑/↓, Tab/Shift+Tab ou Ctrl+J/K navegam · PgUp/PgDn · Enter · Esc fecha.
// Este arquivo é a janela, as teclas e as ações; o que cada modo lista (processos, ranking) está
// em LauncherSources.qml (`src`).
// Depende de: wl-clipboard; opcionais: qalc (libqalculate), cliphist, wtype, fd; foot (terminal).

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import "../theme"
import "../wallpaper"

Scope {
    id: root

    property string terminal: "foot"
    property string searchUrl: "https://www.google.com/search?q="
    property string emojiFont: "Noto Color Emoji"
    property int maxRows: 8
    readonly property int rowHeight: 46

    // ---------- estado ----------
    property bool shown: false          // controla a animação; a janela some depois dela
    property string query: ""

    // as fontes de cada modo e o ranking (LauncherSources.qml)
    LauncherSources {
        id: src
        mode: root.mode
        arg: root.arg
        trimmed: root.trimmed
        jsCalc: root.jsCalc
        wallPick: root.wallPick
        searchUrl: root.searchUrl
    }

    function glyph(cp) { return String.fromCodePoint(cp) }

    function open() {
        if (Popups.current) Popups.hide(Popups.current)
        win.screen = pickScreen()
        query = ""
        search.text = ""
        list.currentIndex = 0
        hideTimer.stop()
        win.visible = true
        shown = true
        search.forceActiveFocus()
    }
    function close() {
        if (!win.visible) return
        shown = false
        hideTimer.restart()
    }
    function toggle() { win.visible && shown ? close() : open() }

    function pickScreen() {
        const m = Hyprland.focusedMonitor
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++)
            if (m && screens[i].name === m.name) return screens[i]
        return screens[0]
    }

    // ---------- modo (pelo prefixo) ----------
    readonly property string lead: query.replace(/^\s+/, "")
    readonly property string trimmed: query.trim()
    readonly property string mode: {
        const t = lead
        if (t.startsWith(">")) return "run"
        if (t.startsWith("=")) return "qalc"
        if (t.startsWith(":")) return "emoji"
        if (t.startsWith("?")) return "web"
        if (/^w\s/.test(t)) return "windows"
        if (/^c\s/.test(t)) return "clip"
        if (/^p\s/.test(t)) return "projects"
        if (/^a\s/.test(t)) return "agent"
        if (/^b\s/.test(t)) return "wall"
        if (t.startsWith("/")) return "files"
        return "apps"
    }
    // texto depois do prefixo
    readonly property string arg: {
        switch (mode) {
        case "run": case "qalc": case "emoji": case "web": return lead.slice(1).trim()
        case "windows": case "clip": case "projects": case "agent": case "wall": return lead.slice(1).trim()
        case "files": return lead.slice(1).trim()
        default: return trimmed
        }
    }
    readonly property var modeInfo: ({
        apps:    { label: "",          glyph: 0xF0349 },
        run:     { label: "Run",       glyph: 0xF018D },
        qalc:    { label: "Calc",      glyph: 0xF00EC },
        emoji:   { label: "Emoji",     glyph: 0xF01F2 },
        web:     { label: "Web",       glyph: 0xF059F },
        windows: { label: "Windows",   glyph: 0xF10AC },
        clip:    { label: "Clipboard", glyph: 0xF0A38 },
        projects:{ label: "Projects",  glyph: 0xF0CCF },
        files:   { label: "Files",     glyph: 0xF0224 },
        agent:   { label: "Claude",    glyph: 0xF06A9 },
        wall:    { label: "Wallpaper", glyph: 0xF0E09 }
    })

    // papel de parede escolhido no modo "b ", à espera de "onde aplicar" ("" = ainda na lista)
    property string wallPick: ""

    // ---------- calculadora ----------
    // conta simples, resolvida na hora sem processo externo
    readonly property string jsCalc: {
        const t = trimmed
        if (mode !== "apps" || t === "") return ""
        if (!/^[0-9.,\s()+\-*/%^]+$/.test(t) || !/\d/.test(t) || !/[+\-*/%^]/.test(t.replace(/^-/, ""))) return ""
        try {
            const expr = t.replace(/,/g, ".").replace(/\^/g, "**")
            const r = Function('"use strict"; return (' + expr + ')')()
            if (typeof r !== "number" || !isFinite(r)) return ""
            return String(parseFloat(r.toPrecision(12)))
        } catch (e) { return "" }
    }

    onQueryChanged: {
        wallPick = ""
        src.refresh(mode, arg)
    }

    // A config do Hyprland é em Lua: o dispatch usa a sintaxe hl.dsp.*
    function focusWindow(address) {
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + address + '" })')
    }

    // ---------- ações ----------
    function activate(index, shift) {
        const r = src.results[index]
        if (!r || r.kind === "info") return
        switch (r.kind) {
        case "app":
            src.bump(r.entry.id)
            if (r.entry.runInTerminal) Quickshell.execDetached([terminal, "-e"].concat(r.entry.command))
            else r.entry.execute()
            break
        case "calc":
            Quickshell.execDetached(["wl-copy", r.title])
            break
        case "run":
        case "term":
            if (shift || r.kind === "term") Quickshell.execDetached([terminal, "--hold", "sh", "-c", r.title])
            else Quickshell.execDetached(["sh", "-c", r.title])
            break
        case "action":
            Quickshell.execDetached(r.cmd)
            break
        case "window":
            focusWindow(r.address)
            break
        case "clip":
            Quickshell.execDetached(["sh", "-c", 'printf "%s" "$1" | cliphist decode | wl-copy', "sh", r.line])
            break
        case "emoji":
            Quickshell.execDetached(["wl-copy", r.emoji])
            // Shift+Enter: digita no app em foco depois que o launcher fecha
            if (shift && src.hasWtype)
                Quickshell.execDetached(["sh", "-c", 'sleep 0.25; wtype -- "$1"', "sh", r.emoji])
            break
        case "web":
            Quickshell.execDetached(["xdg-open", r.url])
            break
        case "project":
            src.bump("proj:" + r.path)
            if (shift) Quickshell.execDetached(["thunar", r.path])
            else Quickshell.execDetached([terminal, "-D", r.path, "nvim", "."])
            break
        case "file":
            Quickshell.execDetached(["xdg-open", shift && !r.dir ? r.path.slice(0, r.path.lastIndexOf("/")) : r.path])
            break
        case "agent":
            Quickshell.execDetached(["barch", "agent", "ask"].concat(shift || r.resume ? ["--continue"] : [], arg ? [arg] : []))
            break
        case "wall":                       // Enter: onde aplicar; Shift+Enter: desktop e lock de uma vez
            if (!shift) { wallPick = r.scene; list.currentIndex = 0; return }
            Wallpapers.set(r.scene, "both")
            break
        case "wallto":
            Wallpapers.set(r.scene, r.target)
            break
        }
        close()
    }

    IpcHandler {
        target: "launcher"
        function toggle(): void { root.toggle() }
        function open(): void { root.open() }
        function close(): void { root.close() }
        // abre já num modo: qs ipc call launcher openWith "c " (clipboard), ": " (emoji)…
        function openWith(prefix: string): void { root.open(); search.text = prefix; search.cursorPosition = prefix.length }
    }

    Timer { id: hideTimer; interval: 140; onTriggered: win.visible = false }

    readonly property string footer: {
        if (query === "")
            return "a Claude   ·   w Windows   ·   c Clipboard   ·   p Projects   ·   / Files   ·   : Emoji   ·   ? Web   ·   = Calc   ·   > Run"
        switch (mode) {
        case "run":     return "↵ Run   ·   ⇧↵ Run in Terminal   ·   Esc Close"
        case "emoji":   return src.hasWtype ? "↵ Copy   ·   ⇧↵ Type It   ·   Esc Close" : "↵ Copy   ·   Esc Close"
        case "clip":    return "↵ Copy   ·   Esc Close"
        case "qalc":    return "↵ Copy Result   ·   Esc Close"
        case "windows": return "↵ Focus Window   ·   Esc Close"
        case "projects": return "↵ Open in Neovim   ·   ⇧↵ Open in Thunar   ·   Esc Close"
        case "files":   return "↵ Open   ·   ⇧↵ Open Folder   ·   Esc Close"
        case "web":     return "↵ Open in Browser   ·   Esc Close"
        case "agent":   return "↵ Ask in a New Conversation   ·   ⇧↵ Continue the Last One   ·   Esc Close"
        default:        return "↑↓ Navigate   ·   ↵ Open   ·   Esc Close"
        }
    }

    // ---------- janela ----------
    PanelWindow {
        id: win
        visible: false
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-launcher"
        WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        HyprlandFocusGrab {
            windows: [win]
            active: win.visible
            onCleared: root.close()
        }

        // fundo levemente escurecido; clicar fora fecha
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, root.shown ? 0.25 : 0)
            Behavior on color { ColorAnimation { duration: 140 } }
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }

        Rectangle {
            id: box
            width: 640
            height: content.implicitHeight + 24
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.25)
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            opacity: root.shown ? 1 : 0
            scale: root.shown ? 1 : 0.97
            transform: Translate { y: root.shown ? 0 : -8; Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } } }
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            clip: true

            MouseArea { anchors.fill: parent }   // não deixa o clique passar para o fundo

            ColumnLayout {
                id: content
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                spacing: 8

                // --- busca ---
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 46
                    radius: Theme.cardRadius
                    color: Theme.hover

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: root.glyph(root.jsCalc ? 0xF00EC : root.modeInfo[root.mode].glyph)
                            color: Theme.accent
                            font.family: Theme.iconFont
                            font.pixelSize: Theme.fontSize + 5
                        }

                        TextField {
                            id: search
                            Layout.fillWidth: true
                            placeholderText: "Search apps…"
                            placeholderTextColor: Theme.dim
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize + 3
                            background: null
                            leftPadding: 0
                            rightPadding: 0

                            onTextChanged: { root.query = text; list.currentIndex = 0 }

                            Keys.onPressed: ev => {
                                const ctrl = ev.modifiers & Qt.ControlModifier
                                if (ev.key === Qt.Key_Escape) {
                                    if (root.wallPick !== "") { root.wallPick = ""; list.currentIndex = 0 }
                                    else root.close()
                                } else if (ev.key === Qt.Key_Down || ev.key === Qt.Key_Tab || (ctrl && ev.key === Qt.Key_J)) {
                                    list.incrementCurrentIndex()
                                } else if (ev.key === Qt.Key_Up || ev.key === Qt.Key_Backtab || (ctrl && ev.key === Qt.Key_K)) {
                                    list.decrementCurrentIndex()
                                } else if (ev.key === Qt.Key_PageDown) {
                                    list.currentIndex = Math.min(list.count - 1, list.currentIndex + root.maxRows)
                                } else if (ev.key === Qt.Key_PageUp) {
                                    list.currentIndex = Math.max(0, list.currentIndex - root.maxRows)
                                } else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
                                    root.activate(list.currentIndex, ev.modifiers & Qt.ShiftModifier)
                                } else {
                                    return
                                }
                                ev.accepted = true
                            }
                        }

                        // modo atual
                        Rectangle {
                            readonly property string label: root.jsCalc ? "Calc" : root.modeInfo[root.mode].label
                            visible: label !== ""
                            implicitWidth: modeLabel.implicitWidth + 16
                            implicitHeight: 22
                            radius: 11
                            color: Theme.accent
                            Text {
                                id: modeLabel
                                anchors.centerIn: parent
                                text: parent.label
                                color: Theme.crust
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                                font.bold: true
                            }
                        }
                    }
                }

                // --- resultados ---
                ListView {
                    id: list
                    Layout.fillWidth: true
                    // as linhas com miniatura (papéis de parede) são mais altas: menos delas por vez
                    Layout.preferredHeight: root.mode === "wall" && root.wallPick === ""
                                            ? Math.min(count, 5) * (84 + spacing)
                                            : Math.min(count, root.maxRows) * (root.rowHeight + spacing)
                    visible: count > 0
                    clip: true
                    spacing: 2
                    model: src.results
                    keyNavigationWraps: true
                    highlightMoveDuration: 0
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool current: ListView.isCurrentItem
                        readonly property bool hasIcon: modelData.kind === "app" || modelData.kind === "window"
                        readonly property bool hasThumb: (modelData.thumb || "") !== ""
                        width: ListView.view.width
                        height: hasThumb ? 84 : root.rowHeight
                        radius: Theme.buttonRadius
                        color: current ? Theme.hover : "transparent"

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: list.currentIndex = row.index
                            onClicked: mouse => root.activate(row.index, mouse.modifiers & Qt.ShiftModifier)
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 12
                            spacing: 12

                            // imagem do clipboard: miniatura no lugar do ícone
                            Rectangle {
                                visible: row.hasThumb
                                implicitWidth: 128
                                implicitHeight: 72
                                radius: 6
                                color: Theme.surface
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: row.hasThumb && (row.modelData.kind !== "clip" || src.thumbsVersion > 0) ? "file://" + row.modelData.thumb : ""
                                    fillMode: Image.PreserveAspectFit
                                    sourceSize: Qt.size(256, 144)
                                    asynchronous: true
                                    cache: false
                                }
                            }

                            // ícone: do app, emoji, glifo, ou a inicial do nome
                            Item {
                                visible: !row.hasThumb
                                implicitWidth: 28
                                implicitHeight: 28

                                IconImage {
                                    id: appIcon
                                    anchors.fill: parent
                                    visible: row.hasIcon && source != ""
                                    // Icon= pode ser um nome do tema de ícones ou um caminho absoluto para uma imagem
                                    source: !row.hasIcon ? ""
                                          : (row.modelData.icon || "").startsWith("/") ? "file://" + row.modelData.icon
                                          : Quickshell.iconPath(row.modelData.icon || "", true)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: row.modelData.kind === "emoji"
                                    text: row.modelData.emoji || ""
                                    font.family: root.emojiFont
                                    font.pixelSize: 22
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: !row.hasIcon && row.modelData.kind !== "emoji"
                                    text: row.modelData.glyph ? root.glyph(row.modelData.glyph) : ""
                                    color: row.current ? Theme.accent : Theme.dim
                                    font.family: Theme.iconFont
                                    font.pixelSize: 20
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    visible: row.hasIcon && !appIcon.visible
                                    radius: 8
                                    color: Theme.surface
                                    Text {
                                        anchors.centerIn: parent
                                        text: row.modelData.title.charAt(0).toUpperCase()
                                        color: Theme.accent
                                        font.family: Theme.font
                                        font.pixelSize: Theme.fontSize + 1
                                        font.bold: true
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    Layout.fillWidth: true
                                    text: row.modelData.title
                                    color: row.modelData.active ? Theme.accent : Theme.fg
                                    elide: Text.ElideRight
                                    font.family: ["calc", "run", "term"].includes(row.modelData.kind) ? Theme.monoFont : Theme.font
                                    font.pixelSize: row.modelData.kind === "calc" ? Theme.fontSize + 3 : Theme.fontSize
                                    font.bold: row.modelData.kind === "calc"
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: row.modelData.subtitle || ""
                                    color: Theme.dim
                                    elide: Text.ElideRight
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize - 2
                                }
                            }

                            Text {
                                visible: row.current
                                text: root.glyph(0xF0311)    // enter
                                color: Theme.dim
                                font.family: Theme.iconFont
                                font.pixelSize: Theme.fontSize + 1
                            }
                        }
                    }
                }

                Text {
                    visible: list.count === 0 && root.trimmed !== ""
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    Layout.bottomMargin: 2
                    text: {
                        switch (root.mode) {
                        case "qalc":    return "Type an expression…"
                        case "run":     return "Type a command…"
                        case "web":     return "Type something to search…"
                        case "windows": return root.arg ? "No matching windows" : "No open windows"
                        case "clip":    return root.arg ? "No matches" : "Clipboard history is empty"
                        case "projects": return root.arg ? "No matching projects" : "No git projects found in " + src.projectRoots.join(", ")
                        case "files":   return root.arg ? "No files found" : "Type part of a file name…"
                        default:        return "No results"
                        }
                    }
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 1
                }

                // --- rodapé ---
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    horizontalAlignment: Text.AlignLeft
                    text: root.footer
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideRight
                }
            }
        }
    }
}
