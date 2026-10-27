pragma Singleton

// Theme.qml — tema central da barra. Todos os widgets leem daqui.
//
// Segue o modo claro/escuro do sistema (color-scheme do gsettings, o mesmo que o
// navegador e os apps GTK/Qt leem): usa darkFlavor no escuro e lightFlavor no claro.
//
// Comandos:
//   qs ipc call theme toggle       alterna o modo do SISTEMA inteiro (barra + apps)
//   qs ipc call theme mode light   força claro/escuro no sistema (light | dark)
//   qs ipc call theme set nord     só a barra, para testar uma paleta (até reiniciar)
//   qs ipc call theme auto         volta a seguir o sistema
//   qs ipc call theme list         paletas disponíveis

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Singleton {
    id: root

    // ================= escolha aqui =================
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
    // Cada uma tem os mesmos 10 tons; os nomes seguem o Catppuccin.
    readonly property var palettes: ({
        // ---- paleta própria: escuro OLED ----
        // Fundo preto puro (no OLED o pixel fica apagado), cinzas neutros quase sem brilho
        // e texto um pouco abaixo do branco, para gastar menos o painel.
        oled:       { crust: "#000000", base: "#000000", surface: "#1c1c1f", overlay: "#2e2e33", subtext: "#8a8a93",
                      text: "#d8d8dc", accent: "#7cacf8", green: "#8bd5a0", yellow: "#e8c07d", red: "#f08a8a" },
        // ---- Dracula (draculatheme.com/spec) ----
        // Cores oficiais; o texto secundário é o "comment" clareado um tom, porque o original
        // (#6272a4) fica abaixo do contraste mínimo de leitura sobre o fundo.
        dracula:    { crust: "#191a21", base: "#282a36", surface: "#44475a", overlay: "#6272a4", subtext: "#8b94c3",
                      text: "#f8f8f2", accent: "#bd93f9", green: "#50fa7b", yellow: "#f1fa8c", red: "#ff5555",
                      // terminal: as 16 cores oficiais do Dracula
                      ansi: { fg: "#f8f8f2", bg: "#282a36",
                              regular: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2"],
                              bright:  ["#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"] } },
        // ---- claro "nord light" (inspirado no lyne-dots) ----
        // Fundos "snow storm" do Nord, texto "polar night" e o azul ardósia (#5e81ac) como
        // destaque. Verde, amarelo e vermelho do Nord escurecidos para ler bem no fundo claro.
        nordlight:  { crust: "#ffffff", base: "#eceff4", surface: "#d8dee9", overlay: "#c5cbd6", subtext: "#5d6984",
                      text: "#2e3440", accent: "#5e81ac", green: "#4a7536", yellow: "#8a6412", red: "#a5464f" },
        // ---- paleta própria: claro "neve" ----
        // Cinza-claro neutro com um toque frio (sem o amarelado que lembra o modo noturno);
        // fica um pouco abaixo do branco puro para brilhar menos no OLED.
        snow:       { crust: "#ffffff", base: "#f3f4f6", surface: "#e1e4e9", overlay: "#c9ced6", subtext: "#5f6774",
                      text: "#262b33", accent: "#2459d6", green: "#2f7a3b", yellow: "#8a5d00", red: "#c0322c" },
        // ---- paleta própria: claro "papel" (creme quente; parece modo noturno) ----
        paper:      { crust: "#fbf7ef", base: "#f2ecdf", surface: "#e2d9c8", overlay: "#cfc4b0", subtext: "#756a59",
                      text: "#3d362c", accent: "#2a5bb8", green: "#3d7330", yellow: "#8f6208", red: "#b23a34" },

        mocha:      { crust: "#11111b", base: "#181825", surface: "#313244", overlay: "#45475a", subtext: "#7f849c",
                      text: "#cdd6f4", accent: "#89b4fa", green: "#a6e3a1", yellow: "#f9e2af", red: "#f38ba8" },
        macchiato:  { crust: "#181926", base: "#1e2030", surface: "#363a4f", overlay: "#494d64", subtext: "#8087a2",
                      text: "#cad3f5", accent: "#8aadf4", green: "#a6da95", yellow: "#eed49f", red: "#ed8796" },
        frappe:     { crust: "#232634", base: "#292c3c", surface: "#414559", overlay: "#51576d", subtext: "#838ba7",
                      text: "#c6d0f5", accent: "#8caaee", green: "#a6d189", yellow: "#e5c890", red: "#e78284" },
        tokyonight: { crust: "#16161e", base: "#1a1b26", surface: "#292e42", overlay: "#3b4261", subtext: "#737aa2",
                      text: "#c0caf5", accent: "#7aa2f7", green: "#9ece6a", yellow: "#e0af68", red: "#f7768e" },
        // Nord escuro ("polar night"); par do nordlight. Texto secundário e vermelho clareados
        // um tom para ler bem no fundo #2e3440.
        nord:       { crust: "#242933", base: "#2e3440", surface: "#3b4252", overlay: "#4c566a", subtext: "#97a2b6",
                      text: "#eceff4", accent: "#88c0d0", green: "#a3be8c", yellow: "#ebcb8b", red: "#dc8b93",
                      // terminal: as 16 cores oficiais do Nord
                      ansi: { fg: "#d8dee9", bg: "#2e3440",
                              regular: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0"],
                              bright:  ["#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"] } },
        gruvbox:    { crust: "#1d2021", base: "#282828", surface: "#3c3836", overlay: "#504945", subtext: "#928374",
                      text: "#ebdbb2", accent: "#83a598", green: "#b8bb26", yellow: "#fabd2f", red: "#fb4934" },
        // clara: aqui "crust" é o tom MAIS CLARO, porque é usado como texto sobre o destaque
        latte:      { crust: "#eff1f5", base: "#e6e9ef", surface: "#ccd0da", overlay: "#bcc0cc", subtext: "#6c6f85",
                      text: "#4c4f69", accent: "#1e66f5", green: "#40a02b", yellow: "#df8e1d", red: "#d20f39" }
    })
    readonly property var p: palettes[flavor] || palettes.mocha

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
    Component.onCompleted: { hyprApply.restart(); appsWrite.restart(); hudWrite.restart() }

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
    function paletteIsDark(p) { return Qt.color(p.base).hslLightness < 0.5 }

    // 16 cores de terminal: as oficiais (campo "ansi") ou derivadas dos 10 tons
    function terminal(p) {
        if (p.ansi) return { fg: p.ansi.fg, bg: p.ansi.bg, regular: p.ansi.regular, bright: p.ansi.bright,
                             selFg: p.text, selBg: p.overlay }
        const dark = paletteIsDark(p)
        const blue = p.accent, magenta = mix(p.red, p.accent, 0.5), cyan = mix(p.green, p.accent, 0.5)
        const adj = x => dark ? Qt.lighter(Qt.color(x), 1.15) : Qt.darker(Qt.color(x), 1.15)
        return {
            fg: p.text, bg: p.base,
            regular: [dark ? p.surface : p.text, p.red, p.green, p.yellow, blue, magenta, cyan, dark ? p.subtext : p.overlay],
            bright:  [dark ? p.overlay : p.subtext, adj(p.red), adj(p.green), adj(p.yellow), adj(blue), adj(magenta), adj(cyan),
                      dark ? p.text : p.surface],
            selFg: p.text, selBg: dark ? p.overlay : p.surface
        }
    }

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

    // ================= tela de bloqueio (hyprlock) =================
    // Gera ~/.config/hypr/hyprlock-colors.conf com a paleta ATUAL (segue o modo claro/escuro).
    // O hyprlock.conf faz "source" dele; como o hyprlock lê a config a cada bloqueio,
    // a tela sempre abre com o tema do momento.
    readonly property bool lockDark: paletteIsDark(p)
    readonly property string hyprlockConf: [
        "# Gerado automaticamente pelo Theme.qml do Quickshell (" + flavor + "). Não edite.",
        "$fg          = " + rgba(text, 0.95),
        "$fg_dim      = " + rgba(text, lockDark ? 0.65 : 0.72),
        "$accent      = " + rgba(accent),
        "$ok          = " + rgba(green),
        "$fail        = " + rgba(red),
        "$warn        = " + rgba(yellow),
        "$pill        = " + rgba(base, lockDark ? 0.45 : 0.6),
        "$outline     = " + rgba(text, 0.14),
        "$placeholder = ##" + hx(text) + "88",
        "$shadow      = " + (lockDark ? "rgba(00000066)" : "rgba(00000018)"),
        // papel de parede: os de ~/Pictures/Wallpapers já vêm no brilho de cada modo,
        // então só um leve escurecimento à noite para o relógio e a senha se destacarem
        "$bg_brightness = " + (lockDark ? "0.8" : "1.0"),
        "$bg_contrast   = " + (lockDark ? "1.0" : "1.0"),
        ""
    ].join("\n")
    onHyprlockConfChanged: lockWrite.restart()
    Timer {
        id: lockWrite
        interval: 300
        onTriggered: root.writeFile(Quickshell.env("HOME") + "/.config/hypr/hyprlock-colors.conf", root.hyprlockConf)
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
        function mode(m: string): string {
            if (m !== "light" && m !== "dark" && m !== "auto") return "use: light | dark | auto"
            root.chooseAppearance(m)
            return "appearance: " + m
        }
        function set(name: string): string {
            if (!root.palettes[name]) return "unknown theme: " + name
            root.forcedFlavor = name
            return "theme: " + name + " (until restart; 'theme auto' to follow the system)"
        }
        function auto(): string {
            root.forcedFlavor = ""
            return "following the system: " + (root.isDark ? "dark" : "light")
        }
        function list(): string { return Object.keys(root.palettes).join(", ") }
    }
}
