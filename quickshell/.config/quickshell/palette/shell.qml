// shell.qml — editor de paletas: uma janela própria (Shell ID diferente da barra).
//
//   qs -p ~/.config/quickshell/palette          barch theme edit [id] · barch theme from-image <img>
//   BARCH_PALETTE_EDIT=<id>                     abre essa paleta
//   BARCH_PALETTE_DRAFT=<arquivo.json>          abre um rascunho (o gerador por imagem)
//   qs -p ~/.config/quickshell/palette ipc call editor open <id> | draft <arquivo> | close
//
// Os dez tons de theme/palettes.json, cada um com seletor (matiz, saturação, luz, hex), avisos de
// contraste, uma amostra (ilha da barra, botões, terminal com as 16 cores derivadas) e a própria
// janela pintada com a paleta em edição. A cada mudança a barra recebe `theme preview`, então a
// barra, as bordas do Hyprland, o GTK e o lock mostram o rascunho na hora; Save grava pela barra
// (`theme save`), fixa a paleta no seu lado e manda renderizar os papéis de parede dela; Close
// volta tudo ao que era (`theme previewEnd`). Nunca escreve em palettes.json: a barra é a dona.
// Depende de: a barra rodando (qs ipc), zenity (escolher a imagem), python3 + Pillow (gerador).

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "palette.js" as P

ShellRoot {
    id: root

    readonly property string palettesPath: Quickshell.shellDir + "/../theme/palettes.json"
    readonly property string generator: Quickshell.shellDir + "/../../../../tools/palette_from_image.py"
    readonly property string font: "SF Pro Text"
    readonly property string monoFont: "JetBrainsMono Nerd Font"
    readonly property string iconFont: "Symbols Nerd Font"
    readonly property int fontSize: 13
    readonly property var tones: P.tones
    readonly property var toneInfo: ({
        crust:   "Text over the accent (the darkest tone, or the lightest in a light palette)",
        base:    "Background of panels and windows",
        surface: "Borders, tracks, hover",
        overlay: "Muted elements",
        subtext: "Secondary text",
        text:    "Text",
        accent:  "Accent: selection, focused borders, buttons",
        green:   "Good",
        yellow:  "Warning",
        red:     "Critical"
    })

    // ---------- estado ----------
    // palettes.json: lido já na carga (blockLoading), senão `loaded` chega depois de
    // Component.onCompleted e BARCH_PALETTE_EDIT não acha a paleta
    property var palettes: readPalettes() || ({})
    property string id: ""
    property bool isNew: true
    property bool fromDraft: false
    property var pal: ({ label: "", crust: "#11111b", base: "#181825", surface: "#313244", overlay: "#45475a",
                         subtext: "#7f849c", text: "#cdd6f4", accent: "#89b4fa", green: "#a6e3a1", yellow: "#f9e2af", red: "#f38ba8" })
    property var original: null            // como abriu (Revert)
    property string selected: "accent"
    property string status: ""
    property bool statusBad: false
    property bool dirty: false
    property bool busy: false
    readonly property bool dark: P.isDark(pal)
    readonly property var term: P.terminal(pal)
    readonly property var contrasts: [
        { a: "text",    b: "base",   min: 4.5, label: "text on base" },
        { a: "subtext", b: "base",   min: 4.0, label: "subtext on base" },
        { a: "accent",  b: "base",   min: 4.5, label: "accent on base" },
        { a: "crust",   b: "accent", min: 4.5, label: "crust on accent (button text)" },
        { a: "green",   b: "base",   min: 3.0, label: "green on base" },
        { a: "yellow",  b: "base",   min: 3.0, label: "yellow on base" },
        { a: "red",     b: "base",   min: 3.0, label: "red on base" }
    ]
    readonly property var darkIds: Object.keys(palettes).filter(k => P.isDark(palettes[k]))
    readonly property var lightIds: Object.keys(palettes).filter(k => !P.isDark(palettes[k]))

    function clone(q) { return JSON.parse(JSON.stringify(q)) }
    function say(msg, bad) { status = msg; statusBad = !!bad }
    function slug(s) { return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").replace(/^[^a-z]+/, "").slice(0, 30) }

    FileView {
        id: palettesFile
        path: root.palettesPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { const r = root.readPalettes(); if (r) root.palettes = r }
    }
    function readPalettes() {
        try { return JSON.parse(palettesFile.text()) } catch (e) { return null }   // no meio de uma gravação da barra
    }

    // ---------- abrir / novo / rascunho ----------
    function openPalette(pid) {
        const q = palettes[pid]
        if (!q) { say("unknown palette: " + pid, true); return }
        id = pid; isNew = false; fromDraft = false
        pal = clone(q); original = clone(q); dirty = false
        say("")
        preview()
    }
    function newPalette(darkSide) {
        const seed = darkSide ? (palettes.mocha || pal) : (palettes.latte || pal)
        id = ""; isNew = true; fromDraft = false
        pal = clone(seed); pal.label = darkSide ? "New Dark" : "New Light"; delete pal.ansi
        original = null; dirty = true
        say("new palette: pick an id, change the tones, Save")
        preview()
    }
    function loadDraft(file) { draftProc.command = ["cat", file]; draftProc.running = true }
    Process {
        id: draftProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text)
                    if (!P.valid(d)) throw "the draft is missing tones"
                    root.id = root.slug(d.id || ""); root.isNew = !root.palettes[root.id]; root.fromDraft = true
                    const q = {}; q.label = d.label || root.id
                    for (const t of root.tones) q[t] = d[t]
                    root.pal = q; root.original = null; root.dirty = true
                    root.say("generated from the image: adjust and Save")
                    root.preview()
                } catch (e) { root.say("cannot read the draft: " + e, true) }
            }
        }
    }
    Component.onCompleted: {
        const draft = Quickshell.env("BARCH_PALETTE_DRAFT"), edit = Quickshell.env("BARCH_PALETTE_EDIT")
        if (draft) loadDraft(draft)
        else if (edit && palettes[edit]) openPalette(edit)
        else statusProc.running = true          // a paleta em uso
    }
    Process {
        id: statusProc
        command: ["qs", "ipc", "call", "theme", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let f = ""
                try { f = JSON.parse(text).flavor } catch (e) {}
                if (f && f !== "draft" && root.palettes[f]) root.openPalette(f)
                else root.openPalette(root.darkIds[0] || Object.keys(root.palettes)[0])
            }
        }
    }

    // ---------- edição ----------
    function setTone(t, hex) {
        if (!/^#[0-9a-fA-F]{6}$/.test(hex)) return
        const q = clone(pal); q[t] = hex.toLowerCase(); pal = q; dirty = true
        preview()
    }
    function setLabel(s) { const q = clone(pal); q.label = s; pal = q; dirty = true }
    function dropAnsi() { const q = clone(pal); delete q.ansi; pal = q; dirty = true; preview() }
    function revert() {
        if (!original) return
        pal = clone(original); dirty = false; say("reverted"); preview()
    }
    // HSL do tom selecionado (os sliders)
    readonly property color selColor: pal[selected] || "#000000"
    readonly property real selH: selColor.hslHue < 0 ? 0 : selColor.hslHue
    readonly property real selS: selColor.hslSaturation
    readonly property real selL: selColor.hslLightness
    function setHsl(h, s, l) { setTone(selected, Qt.hsla(h, s, l, 1).toString().slice(0, 7)) }

    // ---------- preview na barra (a cada mudança, com folga de 120 ms) ----------
    property bool previewPending: false
    function preview() { previewTimer.restart() }
    Timer { id: previewTimer; interval: 120; onTriggered: root.sendPreview() }
    function sendPreview() {
        if (previewProc.running) { previewPending = true; return }
        previewProc.command = ["qs", "ipc", "call", "theme", "preview", JSON.stringify(pal)]
        previewProc.running = true
    }
    Process {
        id: previewProc
        stdout: StdioCollector {
            onStreamFinished: { try { const r = JSON.parse(text); if (!r.ok) root.say(r.error, true) } catch (e) { root.say("the bar did not answer (is it running?)", true) } }
        }
        onExited: if (root.previewPending) { root.previewPending = false; root.sendPreview() }
    }

    // ---------- salvar / apagar / fechar ----------
    function save() {
        const pid = slug(idField.text)
        if (!pid) { say("give the palette an id (lowercase letters, digits, -)", true); return }
        if (isNew && palettes[pid]) { say("'" + pid + "' already exists; pick another id or open it", true); return }
        const existed = !!palettes[pid]
        busy = true
        saveProc.command = ["sh", "-c",
            'out=$(qs ipc call theme save "$1" "$2") || exit 1; echo "$out"; '
            + 'echo "$out" | grep -q \'"ok":true\' || exit 0; '
            + 'qs ipc call theme previewEnd >/dev/null; qs ipc call theme flavor "$3" "$1" >/dev/null; '
            + '[ "$4" = 1 ] && barch wallpaper render "$1" >/dev/null 2>&1; exit 0',
            "sh", pid, JSON.stringify(pal), dark ? "dark" : "light", existed ? "1" : "0"]
        saveProc.pid = pid
        saveProc.running = true
    }
    Process {
        id: saveProc
        property string pid: ""
        stdout: StdioCollector {
            onStreamFinished: {
                root.busy = false
                try {
                    const r = JSON.parse(text.trim().split("\n")[0])
                    if (!r.ok) { root.say(r.error, true); return }
                    root.id = saveProc.pid; root.isNew = false; root.fromDraft = false
                    root.original = root.clone(root.pal); root.dirty = false
                    root.say("saved and pinned as the " + (root.dark ? "dark" : "light") + " palette; wallpapers render in the background")
                    // a barra fixou a paleta nova: o preview recomeça dela
                    root.preview()
                } catch (e) { root.say("the bar did not answer", true) }
            }
        }
    }
    property bool confirmDelete: false
    function remove() {
        if (isNew || !id) return
        if (!confirmDelete) { confirmDelete = true; say("click Delete again to remove '" + id + "'"); return }
        confirmDelete = false
        delProc.command = ["qs", "ipc", "call", "theme", "remove", id]
        delProc.running = true
    }
    Process {
        id: delProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text)
                    if (!r.ok) { root.say(r.error, true); return }
                    root.say("deleted " + r.id)
                    const rest = Object.keys(root.palettes).filter(k => k !== r.id)
                    const q = root.clone(root.palettes); delete q[r.id]; root.palettes = q
                    if (rest.length) root.openPalette(rest[0])
                } catch (e) { root.say("the bar did not answer", true) }
            }
        }
    }
    function close() { endProc.running = true }
    Process {
        id: endProc
        command: ["qs", "ipc", "call", "theme", "previewEnd"]
        onExited: Qt.quit()
    }

    // ---------- a partir de uma imagem ----------
    function fromImage() { pickProc.running = true }
    Process {
        id: pickProc
        command: ["zenity", "--file-selection", "--title=Palette from an image",
                  "--file-filter=Images | *.png *.jpg *.jpeg *.webp *.bmp", "--filename=" + Quickshell.env("HOME") + "/Pictures/"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = text.trim()
                if (!f) return
                genProc.command = ["python3", "-I", root.generator, f]
                genProc.running = true
                root.say("reading " + f + "…")
            }
        }
    }
    Process {
        id: genProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text)
                    root.id = root.slug(d.id || ""); root.isNew = !root.palettes[root.id]; root.fromDraft = true
                    const q = { label: d.label || root.id }
                    for (const t of root.tones) q[t] = d[t]
                    root.pal = q; root.original = null; root.dirty = true
                    root.say("generated from the image: adjust and Save")
                    root.preview()
                } catch (e) { root.say("the generator failed (python3 + Pillow needed): " + e, true) }
            }
        }
    }

    IpcHandler {
        target: "editor"
        function open(pid: string): void { root.openPalette(pid); win.raise() }
        function draft(file: string): void { root.loadDraft(file); win.raise() }
        function close(): void { root.close() }
    }

    // ================= janela =================
    FloatingWindow {
        id: win
        title: "BArch palettes"
        implicitWidth: 1120
        implicitHeight: 720
        minimumSize: Qt.size(960, 620)
        color: root.pal.base

        readonly property color fg: root.pal.text
        readonly property color dim: root.pal.subtext
        readonly property color border: root.pal.surface
        readonly property color accent: root.pal.accent

        // um botão no estilo da barra
        component Btn: Rectangle {
            id: btn
            property string label: ""
            property bool primary: false
            property bool enabledBtn: true
            signal clicked()
            implicitWidth: btnText.implicitWidth + 24
            implicitHeight: 30
            radius: 8
            opacity: enabledBtn ? 1 : 0.4
            color: primary ? win.accent : (btnMouse.containsMouse ? root.pal.surface : "transparent")
            border.width: primary ? 0 : 1
            border.color: win.border
            Text {
                id: btnText
                anchors.centerIn: parent
                text: btn.label
                color: btn.primary ? root.pal.crust : win.fg
                font.family: root.font
                font.pixelSize: root.fontSize
                font.bold: btn.primary
            }
            MouseArea {
                id: btnMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: btn.enabledBtn
                cursorShape: Qt.PointingHandCursor
                onClicked: btn.clicked()
            }
        }
        component Field: TextField {
            color: win.fg
            placeholderTextColor: win.dim
            font.family: root.font
            font.pixelSize: root.fontSize
            leftPadding: 10; rightPadding: 10; topPadding: 6; bottomPadding: 6
            background: Rectangle { radius: 8; color: root.pal.surface; border.width: 1; border.color: parent.activeFocus ? win.accent : "transparent" }
        }
        // slider com trilho em degradê (matiz, saturação ou luz)
        component HslSlider: Item {
            id: sl
            property string name: ""
            property real value: 0
            property var stops: []          // [{ pos, color }]
            signal moved(real v)
            Layout.fillWidth: true
            implicitHeight: 34
            Text { text: sl.name; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 3; y: 0 }
            Rectangle {
                id: track
                y: 16; width: parent.width; height: 12; radius: 6
                border.width: 1; border.color: win.border
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: sl.stops[0] ? sl.stops[0].color : "#000" }
                    GradientStop { position: 0.17; color: sl.stops[1] ? sl.stops[1].color : (sl.stops[0] ? sl.stops[0].color : "#000") }
                    GradientStop { position: 0.33; color: sl.stops[2] ? sl.stops[2].color : (sl.stops[sl.stops.length - 1] || { color: "#fff" }).color }
                    GradientStop { position: 0.50; color: sl.stops[3] ? sl.stops[3].color : (sl.stops[sl.stops.length - 1] || { color: "#fff" }).color }
                    GradientStop { position: 0.67; color: sl.stops[4] ? sl.stops[4].color : (sl.stops[sl.stops.length - 1] || { color: "#fff" }).color }
                    GradientStop { position: 0.83; color: sl.stops[5] ? sl.stops[5].color : (sl.stops[sl.stops.length - 1] || { color: "#fff" }).color }
                    GradientStop { position: 1.00; color: sl.stops[6] ? sl.stops[6].color : (sl.stops[sl.stops.length - 1] || { color: "#fff" }).color }
                }
                Rectangle {
                    x: Math.round(sl.value * (track.width - 16)); y: -3
                    width: 16; height: 18; radius: 5
                    color: root.selColor
                    border.width: 2; border.color: win.fg
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    function set(mx) { sl.moved(Math.max(0, Math.min(1, (mx - 8) / (track.width - 16)))) }
                    onPressed: mouse => set(mouse.x - 4)
                    onPositionChanged: mouse => { if (pressed) set(mouse.x - 4) }
                }
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 16

            // ---------- esquerda: as paletas ----------
            ColumnLayout {
                Layout.preferredWidth: 230
                Layout.fillHeight: true
                spacing: 8
                Text { text: "Palettes"; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 1; font.bold: true }
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: listCol.implicitHeight
                    clip: true
                    ColumnLayout {
                        id: listCol
                        width: parent.width
                        spacing: 2
                        Repeater {
                            model: [{ title: "Dark", ids: root.darkIds }, { title: "Light", ids: root.lightIds }]
                            ColumnLayout {
                                id: grp
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 2
                                Text { text: grp.modelData.title; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 3; Layout.topMargin: 6 }
                                Repeater {
                                    model: grp.modelData.ids
                                    Rectangle {
                                        id: row
                                        required property string modelData
                                        readonly property var q: root.palettes[modelData]
                                        readonly property bool current: modelData === root.id && !root.isNew
                                        Layout.fillWidth: true
                                        implicitHeight: 32
                                        radius: 8
                                        color: current ? root.pal.surface : (rowMouse.containsMouse ? Qt.rgba(win.fg.r, win.fg.g, win.fg.b, 0.06) : "transparent")
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 8; anchors.rightMargin: 8
                                            spacing: 8
                                            Rectangle {
                                                implicitWidth: 18; implicitHeight: 18; radius: 9
                                                color: row.q ? row.q.base : "#000"
                                                border.width: 1; border.color: row.q ? row.q.surface : "#000"
                                                Rectangle { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 10; height: 10; radius: 5; color: row.q ? row.q.accent : "#000" }
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: row.q ? (row.q.label || row.modelData) : row.modelData
                                                color: row.current ? win.accent : win.fg
                                                elide: Text.ElideRight
                                                font.family: root.font; font.pixelSize: root.fontSize - 1; font.bold: row.current
                                            }
                                        }
                                        MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openPalette(row.modelData) }
                                    }
                                }
                            }
                        }
                    }
                }
                Btn { Layout.fillWidth: true; label: "New dark palette"; onClicked: root.newPalette(true) }
                Btn { Layout.fillWidth: true; label: "New light palette"; onClicked: root.newPalette(false) }
                Btn { Layout.fillWidth: true; label: "From an image…"; onClicked: root.fromImage() }
            }

            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: win.border }

            // ---------- centro: id, nome, tons, sliders ----------
            ColumnLayout {
                Layout.preferredWidth: 420
                Layout.fillHeight: true
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Field {
                        id: idField
                        Layout.preferredWidth: 150
                        placeholderText: "id"
                        text: root.id
                        enabled: root.isNew || root.fromDraft
                        onTextChanged: if (root.isNew || root.fromDraft) root.id = root.slug(text)
                    }
                    Field {
                        Layout.fillWidth: true
                        placeholderText: "Name"
                        text: root.pal.label || ""
                        onTextEdited: root.setLabel(text)
                    }
                    Rectangle {
                        implicitWidth: sideText.implicitWidth + 16; implicitHeight: 24; radius: 12
                        color: root.pal.surface
                        Text { id: sideText; anchors.centerIn: parent; text: root.dark ? "dark" : "light"; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 3 }
                    }
                }

                // os dez tons
                Repeater {
                    model: root.tones
                    Rectangle {
                        id: toneRow
                        required property string modelData
                        readonly property bool current: modelData === root.selected
                        Layout.fillWidth: true
                        implicitHeight: 40
                        radius: 8
                        color: current ? root.pal.surface : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            spacing: 10
                            Rectangle {
                                implicitWidth: 28; implicitHeight: 28; radius: 7
                                color: root.pal[toneRow.modelData]
                                border.width: 1; border.color: win.border
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text { text: toneRow.modelData; color: toneRow.current ? win.accent : win.fg; font.family: root.font; font.pixelSize: root.fontSize - 1; font.bold: true }
                                Text { Layout.fillWidth: true; text: root.toneInfo[toneRow.modelData]; color: win.dim; elide: Text.ElideRight; font.family: root.font; font.pixelSize: root.fontSize - 3 }
                            }
                            Field {
                                id: hexField
                                Layout.preferredWidth: 92
                                font.family: root.monoFont
                                text: root.pal[toneRow.modelData]
                                onActiveFocusChanged: if (activeFocus) root.selected = toneRow.modelData
                                onEditingFinished: {
                                    const v = text.trim().startsWith("#") ? text.trim() : "#" + text.trim()
                                    if (/^#[0-9a-fA-F]{6}$/.test(v)) root.setTone(toneRow.modelData, v)
                                    else text = root.pal[toneRow.modelData]
                                }
                            }
                        }
                        MouseArea { anchors.fill: parent; z: -1; cursorShape: Qt.PointingHandCursor; onClicked: root.selected = toneRow.modelData }
                    }
                }

                // sliders do tom selecionado
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 2
                    Text { text: root.selected + "  ·  " + root.pal[root.selected]; color: win.fg; font.family: root.monoFont; font.pixelSize: root.fontSize - 1 }
                    HslSlider {
                        name: "Hue"
                        value: root.selH
                        stops: [0, 1/6, 2/6, 3/6, 4/6, 5/6, 1].map(p => ({ pos: p, color: Qt.hsla(p === 1 ? 0.999 : p, Math.max(0.5, root.selS), 0.5, 1) }))
                        onMoved: v => root.setHsl(v, root.selS, root.selL)
                    }
                    HslSlider {
                        name: "Saturation"
                        value: root.selS
                        stops: [{ color: Qt.hsla(root.selH, 0, root.selL, 1) }, { color: Qt.hsla(root.selH, 1, root.selL, 1) }]
                        onMoved: v => root.setHsl(root.selH, v, root.selL)
                    }
                    HslSlider {
                        name: "Lightness"
                        value: root.selL
                        stops: [{ color: "#000000" }, { color: Qt.hsla(root.selH, root.selS, 0.5, 1) }, { color: "#ffffff" }]
                        onMoved: v => root.setHsl(root.selH, root.selS, v)
                    }
                }
                Item { Layout.fillHeight: true }
            }

            Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: win.border }

            // ---------- direita: contraste e amostra ----------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 10

                Text { text: "Contrast"; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 1; font.bold: true }
                Repeater {
                    model: root.contrasts
                    RowLayout {
                        id: cr
                        required property var modelData
                        readonly property real ratio: P.contrast(root.pal[modelData.a], root.pal[modelData.b])
                        readonly property bool ok: ratio >= modelData.min
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle {
                            implicitWidth: 44; implicitHeight: 20; radius: 5
                            color: root.pal[cr.modelData.b]
                            border.width: 1; border.color: win.border
                            Text { anchors.centerIn: parent; text: "Aa"; color: root.pal[cr.modelData.a]; font.family: root.font; font.pixelSize: root.fontSize - 2; font.bold: true }
                        }
                        Text { Layout.fillWidth: true; text: cr.modelData.label; color: win.fg; font.family: root.font; font.pixelSize: root.fontSize - 2 }
                        Text { text: cr.ratio.toFixed(1) + (cr.ok ? "  ✓" : "  ! min " + cr.modelData.min); color: cr.ok ? root.pal.green : root.pal.yellow; font.family: root.monoFont; font.pixelSize: root.fontSize - 2 }
                    }
                }
                Text {
                    visible: !!root.pal.ansi
                    text: "Terminal: 16 official colors kept (click to derive them from the tones)"
                    color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 3
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.dropAnsi() }
                }

                Text { Layout.topMargin: 6; text: "Sample"; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 1; font.bold: true }
                // ilha da barra
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 32; radius: 16
                    color: root.pal.base
                    border.width: 1; border.color: root.pal.surface
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                        Text { text: "1  2  3"; color: win.accent; font.family: root.font; font.pixelSize: root.fontSize; font.bold: true }
                        Text { text: "Firefox"; color: win.fg; font.family: root.font; font.pixelSize: root.fontSize }
                        Item { Layout.fillWidth: true }
                        Text { text: "󰖩  󰂯  󰕾"; color: win.fg; font.family: root.iconFont; font.pixelSize: root.fontSize + 1 }
                        Text { text: "14:32"; color: win.fg; font.family: root.font; font.pixelSize: root.fontSize; font.bold: true }
                    }
                }
                // cartão com botões e estados
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 86; radius: 10
                    color: root.pal.base
                    border.width: 1; border.color: root.pal.surface
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 10; spacing: 8
                        RowLayout {
                            spacing: 8
                            Rectangle { implicitWidth: 86; implicitHeight: 26; radius: 8; color: win.accent
                                Text { anchors.centerIn: parent; text: "Primary"; color: root.pal.crust; font.family: root.font; font.pixelSize: root.fontSize - 1; font.bold: true } }
                            Rectangle { implicitWidth: 86; implicitHeight: 26; radius: 8; color: root.pal.surface
                                Text { anchors.centerIn: parent; text: "Hover"; color: win.fg; font.family: root.font; font.pixelSize: root.fontSize - 1 } }
                            Rectangle { implicitWidth: 86; implicitHeight: 26; radius: 8; color: "transparent"; border.width: 1; border.color: root.pal.overlay
                                Text { anchors.centerIn: parent; text: "Muted"; color: root.pal.overlay; font.family: root.font; font.pixelSize: root.fontSize - 1 } }
                        }
                        RowLayout {
                            spacing: 14
                            Text { text: "● Good"; color: root.pal.green; font.family: root.font; font.pixelSize: root.fontSize - 1 }
                            Text { text: "● Warning"; color: root.pal.yellow; font.family: root.font; font.pixelSize: root.fontSize - 1 }
                            Text { text: "● Critical"; color: root.pal.red; font.family: root.font; font.pixelSize: root.fontSize - 1 }
                            Text { text: "secondary text"; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 1 }
                        }
                    }
                }
                // terminal: as 16 cores
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 118; radius: 10
                    color: root.term.bg
                    border.width: 1; border.color: root.pal.surface
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 10; spacing: 6
                        Text { text: "$ ls -la ~/BArch   # " + (root.pal.ansi ? "official 16" : "derived from the tones"); color: root.term.fg; font.family: root.monoFont; font.pixelSize: root.fontSize - 2 }
                        RowLayout {
                            spacing: 4
                            Repeater { model: 8; Rectangle { required property int index; implicitWidth: 30; implicitHeight: 20; radius: 4; color: root.term.regular[index] } }
                        }
                        RowLayout {
                            spacing: 4
                            Repeater { model: 8; Rectangle { required property int index; implicitWidth: 30; implicitHeight: 20; radius: 4; color: root.term.bright[index] } }
                        }
                        Text { Layout.fillWidth: true; elide: Text.ElideRight; text: "drwxr-xr-x  bruno  hypr/   quickshell/   README.md"; color: root.term.regular[4]; font.family: root.monoFont; font.pixelSize: root.fontSize - 2 }
                    }
                }
                // janela com borda em foco
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 54; radius: 10
                    color: root.pal.base
                    border.width: 2; border.color: win.accent
                    Text { anchors.centerIn: parent; text: "focused window border"; color: win.dim; font.family: root.font; font.pixelSize: root.fontSize - 2 }
                }
                Item { Layout.fillHeight: true }

                // ---------- rodapé ----------
                Text {
                    Layout.fillWidth: true
                    text: root.status || (root.dirty ? "unsaved changes (the bar shows them live)" : "")
                    color: root.statusBad ? root.pal.red : win.dim
                    wrapMode: Text.Wrap
                    font.family: root.font; font.pixelSize: root.fontSize - 2
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Btn { label: "Revert"; enabledBtn: root.dirty && root.original !== null; onClicked: root.revert() }
                    Btn { label: root.confirmDelete ? "Delete!" : "Delete"; enabledBtn: !root.isNew && root.id !== ""; onClicked: root.remove() }
                    Item { Layout.fillWidth: true }
                    Btn { label: "Close"; onClicked: root.close() }
                    Btn { label: root.isNew ? "Save & pin" : "Save"; primary: true; enabledBtn: !root.busy; onClicked: root.save() }
                }
            }
        }
    }
}
