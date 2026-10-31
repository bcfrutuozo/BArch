pragma Singleton

// Theme.qml — tema central da barra. Todos os widgets leem daqui.
//
// Segue o modo claro/escuro do sistema (color-scheme do gsettings, o mesmo que o
// navegador e os apps GTK/Qt leem): usa darkFlavor no escuro e lightFlavor no claro.
//
// Comandos:
//   qs ipc call theme toggle       alterna o modo do SISTEMA inteiro (barra + apps)
//   qs ipc call theme mode light   Light / Dark / Auto da central de controle (light | dark | auto; JSON)
//   qs ipc call theme set nord     só a barra, para testar uma paleta (até reiniciar)
//   qs ipc call theme auto         volta a seguir o sistema
//   qs ipc call theme list         paletas disponíveis
//   qs ipc call theme palettes     as paletas em dois grupos, escuras e claras, com as cores (JSON)
//   qs ipc call theme flavor dark nord
//                                  fixa a paleta do modo escuro (ou claro); fica salva em
//                                  ~/.local/state/quickshell/flavors.json e vale para tudo que é gerado
//   qs ipc call theme status       aparência escolhida, modo atual e paleta (JSON)
//   qs ipc call theme get nord     uma paleta de palettes.json (JSON)
//   qs ipc call theme preview '{"crust":...}'
//                                  rascunho do editor: vira a paleta "draft" e tudo o segue
//   qs ipc call theme previewEnd   volta ao par fixado
//   qs ipc call theme save praia '{"label":"Praia","crust":...}'
//   qs ipc call theme remove praia grava / apaga uma paleta em theme/palettes.json
// O barch (~/.local/bin) usa mode, status, flavor e palettes: theme light | dark | auto | status |
// dark <paleta> | light <paleta> | palettes.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../palette/palette.js" as P   // lado, 16 cores de terminal, contraste (o editor usa o mesmo arquivo)

Singleton {
    id: root

    // ================= escolha aqui =================
    // Valores iniciais; a escolha feita na central de controle (bloco Themes) ou com
    // "theme flavor" fica em ~/.local/state/quickshell/flavors.json e vale sobre estes.
    property string darkFlavor: "dracula"     // paleta do modo escuro
    property string lightFlavor: "latte"    // paleta do modo claro
    property string defaultMode: "dark"     // se o sistema não declara preferência ("default")

    // ================= modo atual =================
    property string systemScheme: ""        // valor bruto do gsettings: prefer-dark | prefer-light | default
    property string forcedFlavor: ""            // paleta forçada pelo "theme set" (só até reiniciar)

    readonly property bool isDark: systemScheme === "prefer-dark"
        || (systemScheme !== "prefer-light" && defaultMode === "dark")
    readonly property string flavor: forcedFlavor !== "" ? forcedFlavor : (isDark ? darkFlavor : lightFlavor)

    // ================= paletas =================
    // theme/palettes.json é a fonte: id → { label, crust, base, surface, overlay, subtext, text,
    // accent, green, yellow, red, ansi? }. Os dez tons seguem os nomes do Catppuccin; "ansi"
    // (fg, bg, regular[8], bright[8]) é opcional, para as paletas com 16 cores oficiais de
    // terminal. O editor (quickshell/palette, `barch theme edit`) grava nele por "theme save" e
    // make_wallpapers.py lê o mesmo arquivo. Enquanto se edita, "theme preview" põe o rascunho
    // como a paleta "draft" e tudo que é gerado passa a segui-lo.
    readonly property string palettesPath: Quickshell.shellDir + "/theme/palettes.json"
    readonly property var tones: ["crust", "base", "surface", "overlay", "subtext", "text", "accent", "green", "yellow", "red"]
    // o mínimo para a barra subir com o arquivo faltando ou quebrado
    readonly property var fallbackPalettes: ({
        mocha: { label: "Catppuccin Mocha", crust: "#11111b", base: "#181825", surface: "#313244", overlay: "#45475a",
                 subtext: "#7f849c", text: "#cdd6f4", accent: "#89b4fa", green: "#a6e3a1", yellow: "#f9e2af", red: "#f38ba8" },
        latte: { label: "Catppuccin Latte", crust: "#eff1f5", base: "#e6e9ef", surface: "#ccd0da", overlay: "#bcc0cc",
                 subtext: "#6c6f85", text: "#4c4f69", accent: "#1e66f5", green: "#40a02b", yellow: "#df8e1d", red: "#d20f39" }
    })
    property var filePalettes: readPalettes() || ({})
    property var draft: null                // paleta em edição ("theme preview"), id "draft"
    readonly property var palettes: {
        const all = Object.assign({}, filePalettes)
        for (const k in fallbackPalettes) if (!all[k]) all[k] = fallbackPalettes[k]
        if (draft) all.draft = draft
        return all
    }
    FileView {
        id: palettesFile
        path: root.palettesPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        // um arquivo quebrado (ou lido no meio de uma gravação) nunca apaga as paletas em memória
        onLoaded: { const r = root.readPalettes(); if (r) root.filePalettes = r }
    }
    // só entra uma paleta com os dez tons em #rrggbb
    function validPalette(q) {
        return !!q && typeof q === "object" && tones.every(t => /^#[0-9a-fA-F]{6}$/.test(String(q[t] || "")))
    }
    function readPalettes() {
        try {
            const j = JSON.parse(palettesFile.text())
            const out = {}
            for (const k in j) {
                if (k !== "draft" && validPalette(j[k])) out[k] = j[k]
                else console.warn("theme: palette", k, "in palettes.json is incomplete, skipped")
            }
            return out
        } catch (e) { console.log("theme: palettes.json unreadable (being written?), keeping the current set:", e); return null }
    }
    readonly property var p: palettes[flavor] || palettes.mocha

    // nomes para a interface
    function flavorLabel(id) {
        const q = palettes[id]
        return q && q.label ? q.label : (id ? id.charAt(0).toUpperCase() + id.slice(1) : "")
    }
    // as paletas em dois grupos, pela claridade do fundo (ordem: a de cada lado primeiro)
    readonly property var darkFlavors: Object.keys(palettes).filter(k => k !== "draft" && paletteIsDark(palettes[k]))
    readonly property var lightFlavors: Object.keys(palettes).filter(k => k !== "draft" && !paletteIsDark(palettes[k]))
    function flavorInfo(id) {
        const q = palettes[id] || fallbackPalettes.mocha      // um id que acabou de ser apagado ainda pode estar num delegate
        return { id: id, label: flavorLabel(id), base: q.base, surface: q.surface, text: q.text, accent: q.accent,
                 dark: paletteIsDark(q), active: id === (paletteIsDark(q) ? darkFlavor : lightFlavor) }
    }

    // ================= paleta fixa de cada modo (persistente) =================
    readonly property string flavorsPath: stateDir + "flavors.json"
    property bool flavorsLoaded: false
    FileView {
        path: root.flavorsPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const f = JSON.parse(text())
                if (root.palettes[f.dark] && root.paletteIsDark(root.palettes[f.dark])) root.darkFlavor = f.dark
                if (root.palettes[f.light] && !root.paletteIsDark(root.palettes[f.light])) root.lightFlavor = f.light
            } catch (e) { console.warn("theme: invalid flavors.json:", e) }
            root.flavorsLoaded = true
        }
        onLoadFailed: root.flavorsLoaded = true
    }
    // Fixa a paleta de um lado. Se é o lado em uso, tudo troca na hora (barra, bordas, lock,
    // GTK: o tema é reaplicado para os apps abertos relerem o CSS novo). foot, nvim e os apps Qt
    // já abertos ficam como estão até abrirem de novo.
    function setFlavor(mode, name) {
        const q = palettes[name]
        if (!q) return "unknown palette: " + name
        const dark = paletteIsDark(q)
        if (mode === "dark" && !dark) return name + " is a light palette"
        if (mode === "light" && dark) return name + " is a dark palette"
        if (dark) darkFlavor = name; else lightFlavor = name
        writeFile(flavorsPath, JSON.stringify({ dark: darkFlavor, light: lightFlavor }, null, 2) + "\n")
        gtkKick.restart()
        return ""
    }
    // GTK 3 só relê o gtk.css quando o nome do tema muda: vai ao adw-gtk3 e volta, depois
    // que o appsWrite (400 ms) gravou os arquivos novos.
    Timer {
        id: gtkKick
        interval: 900
        onTriggered: Quickshell.execDetached(["sh", "-c",
            'cur=$(gsettings get org.gnome.desktop.interface gtk-theme | tr -d "\x27"); '
            + 'case $cur in BArch-*) gsettings set org.gnome.desktop.interface gtk-theme "$1"; sleep 0.4; '
            + 'gsettings set org.gnome.desktop.interface gtk-theme "$cur";; esac',
            "sh", root.isDark ? "adw-gtk3-dark" : "adw-gtk3"])
    }

    // ================= rascunho do editor (quickshell/palette) =================
    // preview: o rascunho vira a paleta "draft", fixada no seu lado (escuro ou claro) sem gravar
    // flavors.json; se o lado não é o modo atual, a barra é forçada a mostrá-lo mesmo assim.
    // previewEnd volta ao par de antes. save/remove gravam palettes.json (a barra é a dona do
    // arquivo: o editor nunca escreve nele).
    property var previewSaved: null         // { dark, light, forced } de antes do preview
    function previewPalette(q) {
        if (!validPalette(q)) return "a palette needs the ten tones as #rrggbb"
        if (!previewSaved) previewSaved = { dark: darkFlavor, light: lightFlavor, forced: forcedFlavor }
        draft = q
        darkFlavor = previewSaved.dark
        lightFlavor = previewSaved.light
        if (paletteIsDark(q)) darkFlavor = "draft"; else lightFlavor = "draft"
        forcedFlavor = paletteIsDark(q) !== isDark ? "draft" : ""
        gtkKick.restart()
        return ""
    }
    function previewEnd() {
        if (!previewSaved) return
        darkFlavor = previewSaved.dark
        lightFlavor = previewSaved.light
        forcedFlavor = previewSaved.forced
        previewSaved = null
        draft = null
        gtkKick.restart()
    }
    function savePalette(id, q) {
        if (!/^[a-z][a-z0-9-]{1,30}$/.test(id)) return "id: lowercase letters, digits and '-', starting with a letter"
        if (id === "draft") return "'draft' is reserved"
        if (!validPalette(q)) return "a palette needs the ten tones as #rrggbb"
        const clean = { label: String(q.label || id).trim() || id }
        for (const t of tones) clean[t] = String(q[t]).toLowerCase()
        if (q.ansi && q.ansi.regular && q.ansi.regular.length === 8 && q.ansi.bright && q.ansi.bright.length === 8)
            clean.ansi = { fg: q.ansi.fg || clean.text, bg: q.ansi.bg || clean.base, regular: q.ansi.regular, bright: q.ansi.bright }
        const all = Object.assign({}, filePalettes)
        all[id] = clean
        filePalettes = all
        writeFile(palettesPath, JSON.stringify(filePalettes, null, 2) + "\n")
        return ""
    }
    function removePalette(id) {
        if (!filePalettes[id]) return "unknown palette: " + id
        const pinnedDark = previewSaved ? previewSaved.dark : darkFlavor, pinnedLight = previewSaved ? previewSaved.light : lightFlavor
        if (id === pinnedDark || id === pinnedLight) return id + " is pinned; pin another palette first"
        const all = Object.assign({}, filePalettes)
        delete all[id]
        filePalettes = all
        writeFile(palettesPath, JSON.stringify(filePalettes, null, 2) + "\n")
        return ""
    }

    // ================= cores =================
    // Tons da paleta (os mesmos nomes que o shell.qml já usava)
    readonly property color crust: p.crust        // mais escuro: texto sobre destaque
    readonly property color base: p.base          // fundo das ilhas e painéis
    readonly property color surface: p.surface    // bordas, trilhos, hover
    readonly property color overlay: p.overlay    // elementos apagados
    readonly property color subtext: p.subtext    // texto secundário
    readonly property color text: p.text          // texto principal
    readonly property color accent: p.accent      // destaque
    readonly property color green: p.green
    readonly property color yellow: p.yellow
    readonly property color red: p.red

    // Nomes por função (os widgets usam estes)
    readonly property color fg: text
    readonly property color dim: subtext
    readonly property color bg: base
    readonly property color border: surface
    readonly property color hover: surface
    readonly property color track: surface
    readonly property color good: green
    readonly property color warn: yellow
    readonly property color crit: red

    // ================= tipografia =================
    readonly property string font: "SF Pro Text"
    readonly property string iconFont: "Symbols Nerd Font"
    readonly property int fontSize: 13
    // Fonte de largura fixa: terminal (foot) e, por consequência, o nvim
    readonly property string monoFont: "JetBrainsMono Nerd Font"
    readonly property int monoSize: 11

    // ================= forma =================
    readonly property int islandHeight: 32
    readonly property int gap: 8            // distância das ilhas até as bordas da tela
    readonly property int popupRadius: 14
    readonly property int popupGap: 14     // distância entre a ilha e o painel que abre embaixo dela
    readonly property int cardRadius: 10
    readonly property int buttonRadius: 8
    // cantos das janelas no Hyprland: o mesmo raio dos painéis que abrem da barra
    readonly property int windowRadius: popupRadius

    // (o swaync foi substituído pelas notificações do próprio Quickshell, em notifications/)
    function hex(c) { return c.toString().slice(0, 7) }
    Component.onCompleted: { hyprApply.restart(); appsWrite.restart(); hudWrite.restart(); themeJsonWrite.restart(); panelIconsProc.running = true }

    // ================= terminal (foot) e editor (nvim) =================
    // Os dois recebem SEMPRE o par darkFlavor/lightFlavor (o "theme set" só afeta a barra).
    //  - foot: ~/.config/foot/theme.ini com as seções escura e clara; ao trocar o modo,
    //    o tema manda SIGUSR1 (escuro) / SIGUSR2 (claro) a todos os foot abertos.
    //  - nvim: ~/.config/nvim/lua/system_palette.lua com as duas paletas em formato base16;
    //    o foot avisa o nvim da troca (modo 2031) e o nvim aplica a paleta certa.
    readonly property var darkPalette: palettes[darkFlavor] || palettes.mocha
    readonly property var lightPalette: palettes[lightFlavor] || palettes.latte

    function c(x) { return Qt.color(x) }
    function mix(a, b, t) { const B = Qt.color(b); return Qt.tint(Qt.color(a), Qt.rgba(B.r, B.g, B.b, t)) }
    function hx(x) { return Qt.color(x).toString().slice(1, 7) }     // sem "#", como o foot quer
    function paletteIsDark(p) { return P.isDark(p) }

    // 16 cores de terminal: as oficiais (campo "ansi") ou derivadas dos 10 tons (palette.js)
    function terminal(p) { return P.terminal(p) }

    property bool footNewSections: true     // foot >= 1.26 usa [colors-dark]/[colors-light]
    Process {
        running: true
        command: ["foot", "--version"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.match(/(\d+)\.(\d+)/)
                if (m) root.footNewSections = Number(m[1]) > 1 || Number(m[2]) >= 26
            }
        }
    }

    function footSection(name, p) {
        const t = terminal(p)
        const lines = ["[" + name + "]", "foreground=" + hx(t.fg), "background=" + hx(t.bg)]
        for (let i = 0; i < 8; i++) lines.push("regular" + i + "=" + hx(t.regular[i]))
        for (let i = 0; i < 8; i++) lines.push("bright" + i + "=" + hx(t.bright[i]))
        lines.push("selection-foreground=" + hx(t.selFg), "selection-background=" + hx(t.selBg))
        return lines.join("\n")
    }

    readonly property string footIni: [
        "# Gerado automaticamente pelo Theme.qml do Quickshell (" + darkFlavor + " / " + lightFlavor + "). Não edite.",
        "[main]",
        // foot >= 1.26 aceita dark|light; versões anteriores, 1|2
        "initial-color-theme=" + (footNewSections ? (isDark ? "dark" : "light") : (isDark ? "1" : "2")),
        "font=" + monoFont + ":size=" + monoSize,
        "",
        footSection(footNewSections ? "colors-dark" : "colors", darkPalette),
        "",
        footSection(footNewSections ? "colors-light" : "colors2", lightPalette),
        ""
    ].join("\n")

    // base16: base00..base07 do fundo ao texto, base08..base0F cores de destaque
    function base16(p) {
        const dark = paletteIsDark(p)
        const list = [
            p.base, mix(p.base, p.surface, 0.5), p.surface, mix(p.overlay, p.subtext, 0.5),
            p.subtext, p.text, mix(p.text, dark ? "#ffffff" : "#000000", 0.25), dark ? "#ffffff" : "#000000",
            p.red, mix(p.red, p.yellow, 0.5), p.yellow, p.green,
            mix(p.green, p.accent, 0.5), p.accent, mix(p.red, p.accent, 0.5), mix(p.red, p.base, 0.35)
        ]
        const names = ["base00","base01","base02","base03","base04","base05","base06","base07",
                       "base08","base09","base0A","base0B","base0C","base0D","base0E","base0F"]
        return "{ " + names.map((n, i) => n + ' = "#' + hx(list[i]) + '"').join(", ") + " }"
    }

    readonly property string nvimLua: [
        "-- Gerado automaticamente pelo Theme.qml do Quickshell (" + darkFlavor + " / " + lightFlavor + "). Não edite.",
        "return {",
        "  dark = " + base16(darkPalette) + ",",
        "  light = " + base16(lightPalette) + ",",
        "}",
        ""
    ].join("\n")

    function writeFile(path, content) {
        Quickshell.execDetached(["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s" "$1" > "$2"',
                                 "sh", content, path])
    }

    // ================= tela de bloqueio (Quickshell, lock/shell.qml) =================
    readonly property bool lockDark: paletteIsDark(p)
    // O bloqueio roda numa instância separada do Quickshell (qs -p ~/.config/quickshell/lock) e
    // NÃO importa este singleton: carregá-lo gera os arquivos de tema dos apps e aplica as bordas
    // do Hyprland, coisa que só a barra deve fazer. Em vez disso ele lê a paleta ATUAL deste
    // JSON (segue claro/escuro e o "theme set"); um FileView com watchChanges troca na hora.
    readonly property string themeJson: JSON.stringify({
        flavor: flavor, dark: lockDark, font: font, iconFont: iconFont,
        colors: { crust: hex(crust), base: hex(base), surface: hex(surface), overlay: hex(overlay),
                  subtext: hex(subtext), text: hex(text), accent: hex(accent),
                  green: hex(green), yellow: hex(yellow), red: hex(red) }
    }, null, 2) + "\n"
    onThemeJsonChanged: themeJsonWrite.restart()
    Timer {
        id: themeJsonWrite
        interval: 300
        onTriggered: root.writeFile(root.stateDir + "theme.json", root.themeJson)
    }

    onFootIniChanged: termWrite.restart()
    onNvimLuaChanged: termWrite.restart()
    Timer {
        id: termWrite
        interval: 300
        onTriggered: {
            const home = Quickshell.env("HOME")
            root.writeFile(home + "/.config/foot/theme.ini", root.footIni)
            root.writeFile(home + "/.config/nvim/lua/system_palette.lua", root.nvimLua)
        }
    }

    // ================= apps GTK e Qt =================
    // Tudo é gerado SEMPRE com o par darkFlavor/lightFlavor; quem escolhe o lado é o
    // ~/.local/bin/apps-theme (chamado pelo theme-auto), trocando tema GTK, ícones e qt6ct.
    //  - GTK 3: dois temas próprios, ~/.local/share/themes/BArch-{dark,light}, que importam o
    //    adw-gtk3 e trocam as cores nomeadas dele. Trocar o tema GTK recarrega os apps abertos.
    //  - GTK 4 / libadwaita: ~/.config/gtk-4.0/gtk.css com as duas paletas; a escura fica
    //    dentro de @media (prefers-color-scheme: dark), então os apps trocam sozinhos.
    //  - Qt: ~/.config/qt6ct/colors/barch-{dark,light}.conf (vale ao abrir o app).
    function gtkColors(p) {
        const dark = paletteIsDark(p)
        const H = x => "#" + hx(x)
        const A = (x, a) => { const q = Qt.color(x); return "rgba(" + Math.round(q.r * 255) + ", "
                              + Math.round(q.g * 255) + ", " + Math.round(q.b * 255) + ", " + a + ")" }
        const on = dark ? p.crust : "#ffffff"           // texto sobre cores fortes
        const win = p.base
        const view = dark ? mix(p.base, p.crust, 0.35) : p.crust
        const head = dark ? mix(p.base, p.crust, 0.55) : mix(p.base, p.surface, 0.25)
        const side = dark ? mix(p.base, p.crust, 0.55) : mix(p.base, p.surface, 0.35)
        const card = dark ? mix(p.base, p.surface, 0.30) : p.crust
        const pop = dark ? mix(p.base, p.surface, 0.20) : p.crust
        const shade = A("#000000", dark ? 0.36 : 0.07)
        return [
            ["accent_color", H(p.accent)], ["accent_bg_color", H(p.accent)], ["accent_fg_color", H(on)],
            ["destructive_color", H(p.red)], ["destructive_bg_color", H(p.red)], ["destructive_fg_color", H(on)],
            ["success_color", H(p.green)], ["success_bg_color", H(p.green)], ["success_fg_color", H(on)],
            ["warning_color", H(p.yellow)], ["warning_bg_color", H(p.yellow)], ["warning_fg_color", A("#000000", 0.8)],
            ["error_color", H(p.red)], ["error_bg_color", H(p.red)], ["error_fg_color", H(on)],
            ["window_bg_color", H(win)], ["window_fg_color", H(p.text)],
            ["view_bg_color", H(view)], ["view_fg_color", H(p.text)],
            ["headerbar_bg_color", H(head)], ["headerbar_fg_color", H(p.text)],
            ["headerbar_border_color", H(p.text)], ["headerbar_backdrop_color", H(win)],
            ["headerbar_shade_color", shade], ["headerbar_darker_shade_color", A("#000000", dark ? 0.9 : 0.12)],
            ["sidebar_bg_color", H(side)], ["sidebar_fg_color", H(p.text)],
            ["sidebar_backdrop_color", H(win)], ["sidebar_shade_color", shade], ["sidebar_border_color", shade],
            ["secondary_sidebar_bg_color", H(mix(side, win, 0.5))], ["secondary_sidebar_fg_color", H(p.text)],
            ["secondary_sidebar_backdrop_color", H(win)], ["secondary_sidebar_shade_color", shade],
            ["secondary_sidebar_border_color", shade],
            ["card_bg_color", H(card)], ["card_fg_color", H(p.text)], ["card_shade_color", shade],
            ["dialog_bg_color", H(pop)], ["dialog_fg_color", H(p.text)],
            ["popover_bg_color", H(pop)], ["popover_fg_color", H(p.text)], ["popover_shade_color", shade],
            ["thumbnail_bg_color", H(card)], ["thumbnail_fg_color", H(p.text)],
            ["shade_color", shade], ["scrollbar_outline_color", dark ? A("#000000", 0.5) : H("#ffffff")]
        ]
    }

    function gtk3Css(p, variant) {
        return ["/* Gerado automaticamente pelo Theme.qml do Quickshell. Não edite. */",
                '@import url("file:///usr/share/themes/' + variant + '/gtk-3.0/gtk.css");', ""]
            .concat(gtkColors(p).map(e => "@define-color " + e[0] + " " + e[1] + ";"))
            .concat([""]).join("\n")
    }

    function gtk4Vars(p, indent) {
        return gtkColors(p).map(e => indent + "--" + e[0].replace(/_/g, "-") + ": " + e[1] + ";").join("\n")
    }

    readonly property string gtk4Css: [
        "/* Gerado automaticamente pelo Theme.qml do Quickshell (" + darkFlavor + " / " + lightFlavor + "). Não edite. */",
        ":root {", gtk4Vars(lightPalette, "  "), "}", "",
        "@media (prefers-color-scheme: dark) {", "  :root {", gtk4Vars(darkPalette, "    "), "  }", "}", ""
    ].join("\n")

    function themeIndex(name) {
        return ["[Desktop Entry]", "Type=X-GNOME-Metatheme", "Name=" + name,
                "Comment=adw-gtk3 com as cores do Quickshell", "", "[X-GNOME-Metatheme]",
                "GtkTheme=" + name, ""].join("\n")
    }

    // qt6ct: 21 cores na ordem do QPalette (o qt6ct completa a de destaque sozinho)
    function qtScheme(p) {
        const dark = paletteIsDark(p)
        const g = {}
        gtkColors(p).forEach(e => g[e[0]] = e[1])
        const Q = x => "#ff" + hx(x)
        const win = g.window_bg_color, view = g.view_bg_color, pop = g.popover_bg_color
        const button = dark ? mix(p.base, p.surface, 0.45) : p.crust
        const light = dark ? mix(p.surface, p.text, 0.15) : "#ffffff"
        const darkc = dark ? p.crust : p.overlay
        const roles = (text, sub, hl, hlText) => [
            text, button, light, mix(button, light, 0.5), darkc, p.surface,
            text, dark ? "#ffffff" : "#000000", text, view, win, "#000000",
            hl, hlText, p.accent, mix(p.accent, p.red, 0.4), mix(view, p.surface, 0.25), win,
            pop, p.text, sub
        ].map(Q).join(", ")
        const off = mix(p.text, win, 0.55)
        return ["# Gerado automaticamente pelo Theme.qml do Quickshell. Não edite.", "[ColorScheme]",
                "active_colors=" + roles(p.text, p.subtext, p.accent, g.accent_fg_color),
                "inactive_colors=" + roles(p.text, p.subtext, p.accent, g.accent_fg_color),
                "disabled_colors=" + roles(off, off, p.surface, off), ""].join("\n")
    }

    // fontconfig: a fonte da barra vira a fonte de interface de todos os apps, e a do
    // terminal vira a monoespaçada padrão (menus, diálogos, páginas sem fonte própria)
    readonly property string fontsConf: [
        '<?xml version="1.0"?>',
        '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">',
        "<!-- Gerado automaticamente pelo Theme.qml do Quickshell. Não edite. -->",
        "<fontconfig>",
        "  <alias binding=\"same\"><family>sans-serif</family><prefer><family>" + font + "</family></prefer></alias>",
        "  <alias binding=\"same\"><family>sans</family><prefer><family>" + font + "</family></prefer></alias>",
        "  <alias binding=\"same\"><family>system-ui</family><prefer><family>" + font + "</family></prefer></alias>",
        "  <alias binding=\"same\"><family>monospace</family><prefer><family>" + monoFont + "</family></prefer></alias>",
        "</fontconfig>", ""
    ].join("\n")

    readonly property string appsKey: darkFlavor + "/" + lightFlavor + "/" + gtk4Css.length + "/" + fontsConf
    onAppsKeyChanged: appsWrite.restart()
    Timer {
        id: appsWrite
        interval: 400
        onTriggered: {
            const home = Quickshell.env("HOME")
            const t = home + "/.local/share/themes/"
            root.writeFile(t + "BArch-dark/index.theme", root.themeIndex("BArch-dark"))
            root.writeFile(t + "BArch-dark/gtk-3.0/gtk.css", root.gtk3Css(root.darkPalette, "adw-gtk3-dark"))
            root.writeFile(t + "BArch-light/index.theme", root.themeIndex("BArch-light"))
            root.writeFile(t + "BArch-light/gtk-3.0/gtk.css", root.gtk3Css(root.lightPalette, "adw-gtk3"))
            root.writeFile(home + "/.config/gtk-4.0/gtk.css", root.gtk4Css)
            root.writeFile(home + "/.config/qt6ct/colors/barch-dark.conf", root.qtScheme(root.darkPalette))
            root.writeFile(home + "/.config/qt6ct/colors/barch-light.conf", root.qtScheme(root.lightPalette))
            root.writeFile(home + "/.config/fontconfig/conf.d/60-barch-fonts.conf", root.fontsConf)
        }
    }

    // ================= ícones da bandeja (tray) =================
    // A barra resolve os ícones pelo tema de ícones com que ela abriu, e não troca de tema
    // sozinha. Os ícones "de painel" do Papirus (Nextcloud, Steam, Discord…) são claros no
    // Papirus-Dark e escuros no Papirus-Light; sem isso, no modo claro ficariam brancos na
    // barra clara. Aqui fica a lista dos ícones de painel do tema do modo atual, e
    // trayIcon() troca o ícone pelo arquivo certo quando ele existe.
    property var panelIcons: ({})
    // apps da bandeja que escolhem a cor do ícone sozinhos e erram o contraste: viram silhueta
    // na cor do texto da barra (compara com o id/título do item, em minúsculas)
    property var monoTrayApps: ["nextcloud"]
    Process {
        id: panelIconsProc
        command: ["sh", "-c", 'for s in 22x22 24x24 16x16; do d="/usr/share/icons/$1/$s/panel"; '
            + '[ -d "$d" ] && find -L "$d" -maxdepth 1 -name "*.svg" -printf "%f\t$d/%f\n"; done', "sh",
            root.isDark ? "Papirus-Dark" : "Papirus-Light"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {}
                for (const line of text.split("\n")) {
                    const t = line.indexOf("\t")
                    if (t < 0) continue
                    const name = line.slice(0, t).replace(/\.svg$/, "")
                    if (!(name in m)) m[name] = line.slice(t + 1)       // 22x22 tem prioridade
                }
                root.panelIcons = m
            }
        }
    }
    function trayIcon(src) {
        const s = (src || "").toString()
        const m = s.match(/^image:\/\/icon\/([^?]+)/)
        if (!m) return s
        const p = panelIcons[decodeURIComponent(m[1])]
        return p ? "file://" + p : s
    }

    // ================= jogos =================
    // Os dois botões de jogo do Control Center ficam salvos em ~/.local/state/quickshell/:
    //  - game-hud: mostra o MangoHud (o MangoHud relê a config sozinho, vale na hora);
    //  - game-hdr: o run.sh do Battle.net lê na hora de abrir (vale no próximo lançamento).
    // A config do MangoHud usa sempre a paleta escura (darkFlavor).
    property bool gameHud: false
    property bool gameHdr: true
    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/quickshell/"
    FileView { path: root.stateDir + "game-hud"; onLoaded: root.gameHud = text().trim() === "on" }
    FileView { path: root.stateDir + "game-hdr"; onLoaded: root.gameHdr = text().trim() !== "off" }
    function setGameHud(on) { gameHud = on; writeFile(stateDir + "game-hud", on ? "on" : "off") }
    function setGameHdr(on) { gameHdr = on; writeFile(stateDir + "game-hdr", on ? "on" : "off") }

    readonly property string mangohudConf: {
        const d = darkPalette
        const t = terminal(d)
        const H = x => hx(x)
        return [
            "# Gerado automaticamente pelo Theme.qml do Quickshell (" + darkFlavor + "). Não edite.",
            "# Mostrar/esconder: botão Game HUD no Control Center.",
            "legacy_layout=false",
            gameHud ? "" : "no_display",
            "horizontal", "hud_compact",
            "position=top-left", "offset_x=16", "offset_y=16",
            "font_size=22", "round_corners=" + cardRadius,
            "background_alpha=0.7", "background_color=" + H(d.crust),
            "text_color=" + H(d.text), "text_outline=0",
            "fps", "fps_color_change", "fps_value=60,120",
            "fps_color=" + [H(d.red), H(d.yellow), H(d.green)].join(","),
            "frametime", "frametime_color=" + H(d.subtext), "frame_timing=0",
            "gpu_stats", "gpu_temp", "gpu_power", "gpu_color=" + H(d.accent),
            "cpu_stats", "cpu_temp", "cpu_color=" + H(t.regular[6]),
            "vram", "vram_color=" + H(t.regular[5]),
            "ram", "ram_color=" + H(t.bright[5]),
            "engine_color=" + H(d.accent), "wine_color=" + H(d.accent),
            "toggle_hud=Shift_L+F12", ""
        ].filter((l, i, a) => l !== "" || i === a.length - 1).join("\n")
    }
    onMangohudConfChanged: hudWrite.restart()
    Timer {
        id: hudWrite
        interval: 300
        onTriggered: root.writeFile(Quickshell.env("HOME") + "/.config/MangoHud/MangoHud.conf", root.mangohudConf)
    }

    // troca o tema dos terminais abertos quando o modo do sistema muda
    property bool modeKnown: false
    onIsDarkChanged: {
        panelIconsProc.running = true          // ícones da bandeja do modo novo
        if (!modeKnown) return
        Quickshell.execDetached(["pkill", isDark ? "-USR1" : "-USR2", "-x", "foot"])
        Quickshell.execDetached(["pkill", isDark ? "-USR1" : "-USR2", "-x", "footclient"])
    }
    onSystemSchemeChanged: if (systemScheme !== "") modeKnownTimer.restart()
    Timer { id: modeKnownTimer; interval: 1000; onTriggered: root.modeKnown = true }

    // ================= bordas do Hyprland =================
    // A config do Hyprland é em Lua, então as cores são aplicadas ao vivo com
    // "hyprctl eval" chamando hl.config(), sem mexer nos arquivos da config. Acontece a cada
    // troca de paleta, quando a barra inicia e sempre que o Hyprland recarrega a config
    // (que voltaria às cores originais dela). Cada grupo vai num pcall separado: se alguma
    // opção não existir na sua versão, as outras continuam valendo.
    function rgba(x, a) {
        const col = Qt.color(x)
        const h = v => Math.round(v * 255).toString(16).padStart(2, "0")
        return "rgba(" + h(col.r) + h(col.g) + h(col.b) + h(a === undefined ? 1 : a) + ")"
    }
    function q(x) { return '"' + x + '"' }
    readonly property string hyprLua: [
        "for _, t in ipairs({",
        // janela em foco: degradê do destaque para o verde da paleta; sem foco: tom das bordas
        "  { general = { col = { active_border = { colors = { " + q(rgba(accent)) + ", "
            + q(rgba(mix(accent, green, 0.6))) + " }, angle = 45 }, inactive_border = " + q(rgba(surface)) + " } } },",
        // grupos de janelas (abas)
        "  { group = { col = { border_active = " + q(rgba(accent)) + ", border_inactive = " + q(rgba(surface)) + " } } },",
        "  { group = { groupbar = { col = { active = " + q(rgba(accent)) + ", inactive = " + q(rgba(surface)) + " } } } },",
        // cantos das janelas iguais aos painéis da barra
        "  { decoration = { rounding = " + windowRadius + " } },",
        // fundo visível quando não há papel de parede
        "  { misc = { background_color = " + q(rgba(base)) + " } },",
        "}) do pcall(hl.config, t) end"
    ].join(" ")

    onHyprLuaChanged: hyprApply.restart()
    Timer {
        id: hyprApply
        interval: 300
        onTriggered: Quickshell.execDetached(["hyprctl", "eval", root.hyprLua])
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded") hyprApply.restart()
        }
    }

    // ================= modo claro/escuro do sistema =================
    function readScheme(line) {
        const m = line.match(/'([^']+)'/)
        if (m) systemScheme = m[1]
    }
    // Troca o modo do sistema. Se existir o ~/.local/bin/theme-auto, usa ele (que também troca
    // o tema do Hyprland e do GTK); senão, só o gsettings.
    function setSystemMode(mode) {
        if (hasThemeScript)
            Quickshell.execDetached([themeScript, mode === "light" ? "light" : "dark"])
        else
            Quickshell.execDetached(["gsettings", "set", "org.gnome.desktop.interface", "color-scheme",
                                     mode === "light" ? "prefer-light" : "prefer-dark"])
    }

    // ================= aparência: Light / Dark / Auto (central de controle) =================
    // Light e Dark fixam o modo. Auto troca sozinho nos horários do theme-auto
    // (DAY_START e NIGHT_START, lidos do próprio script). No Auto, um toggle manual
    // (atalho ou "qs ipc call theme toggle") vale até a próxima virada de horário.
    // A escolha fica salva em ~/.local/state/quickshell/appearance.
    readonly property string themeScript: Quickshell.env("HOME") + "/.local/bin/theme-auto"
    property bool hasThemeScript: false
    property int dayStart: 8
    property int nightStart: 18
    property string appearance: ""              // light | dark | auto ("" = nunca escolhido)
    readonly property string currentMode: isDark ? "dark" : "light"
    property string lastAuto: ""

    Process {
        running: true
        command: ["sh", "-c", '[ -x "$1" ] || exit 1; grep -E "^(DAY|NIGHT)_START=[0-9]+" "$1"; exit 0',
                  "sh", root.themeScript]
        stdout: StdioCollector {
            onStreamFinished: {
                const d = text.match(/DAY_START=(\d+)/), n = text.match(/NIGHT_START=(\d+)/)
                if (d) root.dayStart = Number(d[1])
                if (n) root.nightStart = Number(n[1])
            }
        }
        onExited: code => root.hasThemeScript = (code === 0)
    }

    readonly property string appearancePath: Quickshell.env("HOME") + "/.local/state/quickshell/appearance"
    FileView {
        path: root.appearancePath
        onLoaded: {
            const a = text().trim()
            if (a === "light" || a === "dark" || a === "auto") root.appearance = a
        }
    }

    function scheduledMode() {
        const h = new Date().getHours()
        return (h >= dayStart && h < nightStart) ? "light" : "dark"
    }

    function applyAuto(force) {
        if (appearance !== "auto") return
        const m = scheduledMode()
        if (force || m !== lastAuto) {
            lastAuto = m
            if (m !== currentMode) { forcedFlavor = ""; setSystemMode(m) }
        }
    }

    function chooseAppearance(a) {
        if (a !== "light" && a !== "dark" && a !== "auto") return
        appearance = a
        writeFile(appearancePath, a)
        forcedFlavor = ""
        if (a === "auto") applyAuto(true)
        else setSystemMode(a)
    }

    // ao iniciar a barra: reaplica a escolha salva (só mexe se o modo atual for diferente)
    Timer {
        interval: 1500
        running: true
        onTriggered: {
            if (root.appearance === "auto") root.applyAuto(true)
            else if (root.appearance !== "" && root.appearance !== root.currentMode) root.setSystemMode(root.appearance)
        }
    }
    Timer {
        interval: 60000
        running: root.appearance === "auto"
        repeat: true
        onTriggered: root.applyAuto(false)
    }

    // valor inicial
    Process {
        running: true
        command: ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]
        stdout: SplitParser { onRead: line => root.readScheme(line) }
    }

    // acompanha as mudanças em tempo real (vindas daqui, de outro app ou de um atalho)
    Process {
        id: monitor
        running: true
        command: ["gsettings", "monitor", "org.gnome.desktop.interface", "color-scheme"]
        stdout: SplitParser { onRead: line => root.readScheme(line) }
        onExited: monitorRestart.start()
    }
    Timer { id: monitorRestart; interval: 5000; onTriggered: monitor.running = true }

    // ================= comandos =================
    IpcHandler {
        target: "theme"
        function toggle(): string {
            const next = root.isDark ? "light" : "dark"
            if (root.appearance === "auto") {           // vale até a próxima virada de horário
                root.forcedFlavor = ""
                root.setSystemMode(next)
                return "mode: " + next + " (auto resumes at the next switch)"
            }
            root.chooseAppearance(next)
            return "mode: " + next
        }
        // Light / Dark / Auto, como na central de controle (JSON, usado pelo barch)
        function mode(m: string): string {
            if (m !== "light" && m !== "dark" && m !== "auto")
                return JSON.stringify({ ok: false, error: "use: light | dark | auto" })
            root.chooseAppearance(m)
            return JSON.stringify({ ok: true, appearance: m })
        }
        function status(): string {
            return JSON.stringify({ ok: true, appearance: root.appearance || "unset", mode: root.currentMode,
                                    flavor: root.flavor, dark: root.darkFlavor, light: root.lightFlavor,
                                    dayStart: root.dayStart, nightStart: root.nightStart })
        }
        function set(name: string): string {
            if (!root.palettes[name]) return "unknown theme: " + name
            root.forcedFlavor = name
            return "theme: " + name + " (until restart; 'theme auto' to follow the system)"
        }
        // paleta fixa do modo escuro ou claro (JSON, usado pelo barch e pela central de controle)
        function flavor(mode: string, name: string): string {
            if (mode !== "dark" && mode !== "light") return JSON.stringify({ ok: false, error: "use: dark | light" })
            const err = root.setFlavor(mode, name)
            if (err) return JSON.stringify({ ok: false, error: err, palettes: (mode === "dark" ? root.darkFlavors : root.lightFlavors) })
            return JSON.stringify({ ok: true, dark: root.darkFlavor, light: root.lightFlavor, mode: root.currentMode, flavor: root.flavor })
        }
        function palettes(): string {
            return JSON.stringify({ ok: true, dark: root.darkFlavors.map(root.flavorInfo), light: root.lightFlavors.map(root.flavorInfo),
                                    current: { dark: root.darkFlavor, light: root.lightFlavor } })
        }
        function auto(): string {
            root.forcedFlavor = ""
            return "following the system: " + (root.isDark ? "dark" : "light")
        }
        function list(): string { return Object.keys(root.palettes).join(", ") }
        // ---- editor de paletas (JSON) ----
        function get(id: string): string {
            const q = root.filePalettes[id]
            return q ? JSON.stringify({ ok: true, id: id, palette: q, dark: root.paletteIsDark(q) })
                     : JSON.stringify({ ok: false, error: "unknown palette: " + id })
        }
        function preview(json: string): string {
            let q
            try { q = JSON.parse(json) } catch (e) { return JSON.stringify({ ok: false, error: "invalid JSON: " + e }) }
            const err = root.previewPalette(q)
            return err ? JSON.stringify({ ok: false, error: err }) : JSON.stringify({ ok: true, dark: root.paletteIsDark(q) })
        }
        function previewEnd(): string {
            root.previewEnd()
            return JSON.stringify({ ok: true, dark: root.darkFlavor, light: root.lightFlavor })
        }
        function save(id: string, json: string): string {
            let q
            try { q = JSON.parse(json) } catch (e) { return JSON.stringify({ ok: false, error: "invalid JSON: " + e }) }
            const err = root.savePalette(id, q)
            return err ? JSON.stringify({ ok: false, error: err }) : JSON.stringify({ ok: true, id: id, dark: root.paletteIsDark(q) })
        }
        function remove(id: string): string {
            const err = root.removePalette(id)
            return err ? JSON.stringify({ ok: false, error: err }) : JSON.stringify({ ok: true, id: id })
        }
    }
}
