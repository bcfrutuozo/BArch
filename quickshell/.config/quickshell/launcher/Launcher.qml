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
//   = ...    calculadora qalc (unidades e conversões: "= 5 km to mi"); Enter copia.
//   > ...    roda um comando; Shift+Enter roda no terminal e mantém aberto.
// Teclas: ↑/↓, Tab/Shift+Tab ou Ctrl+J/K navegam · PgUp/PgDn · Enter · Esc fecha.
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
    property var usage: ({})            // id do .desktop -> quantas vezes foi aberto
    property bool hasQalc: false
    property bool hasWtype: false
    property string qalcResult: ""
    property var windows: []            // de "hyprctl clients -j"
    property var clips: []              // linhas do "cliphist list"
    property var emojis: []             // [{ e, name, group, kw }]

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/quickshell"
    readonly property string usagePath: stateDir + "/launcher-usage.json"

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
        if (t.startsWith("/")) return "files"
        return "apps"
    }
    // texto depois do prefixo
    readonly property string arg: {
        switch (mode) {
        case "run": case "qalc": case "emoji": case "web": return lead.slice(1).trim()
        case "windows": case "clip": case "projects": case "agent": return lead.slice(1).trim()
        case "files": return lead.slice(1).trim()
        default: return trimmed
        }
    }
    readonly property bool runMode: mode === "run"
    readonly property bool qalcMode: mode === "qalc"

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
        agent:   { label: "Claude",    glyph: 0xF06A9 }
    })

    onModeChanged: {
        if (mode === "windows") winProc.running = true
        if (mode === "clip") clipProc.running = true
        if (mode === "projects") projProc.running = true
    }

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
        qalcResult = ""
        if (qalcMode && hasQalc && arg.length > 0) qalcDebounce.restart()
        if (mode === "files") filesDebounce.restart()
    }

    Timer {
        id: qalcDebounce
        interval: 150
        onTriggered: {
            qalcProc.command = ["qalc", "-t", root.arg]
            qalcProc.running = true
        }
    }
    Process {
        id: qalcProc
        stdout: StdioCollector {
            onStreamFinished: root.qalcResult = text.trim().split("\n").pop() || ""
        }
    }
    Process {
        command: ["sh", "-c", "command -v qalc >/dev/null && echo qalc; command -v wtype >/dev/null && echo wtype; true"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                root.hasQalc = text.includes("qalc")
                root.hasWtype = text.includes("wtype")
            }
        }
    }

    // ---------- janelas ----------
    Process {
        id: winProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const list = JSON.parse(text).filter(c => c.mapped && !c.hidden && c.title !== "")
                    // mais recentes primeiro; a janela atual vai para o fim
                    list.sort((a, b) => {
                        const fa = a.focusHistoryID === 0 ? 1e9 : a.focusHistoryID
                        const fb = b.focusHistoryID === 0 ? 1e9 : b.focusHistoryID
                        return fa - fb
                    })
                    root.windows = list
                } catch (e) { root.windows = [] }
            }
        }
    }

    function appIconFor(cls) {
        if (!cls) return ""
        let e = null
        try { e = DesktopEntries.heuristicLookup(cls) } catch (err) { e = DesktopEntries.byId(cls) }
        return e ? e.icon : cls
    }

    // A config do Hyprland é em Lua: o dispatch usa a sintaxe hl.dsp.*
    function focusWindow(address) {
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + address + '" })')
    }

    // ---------- clipboard ----------
    Process {
        id: clipProc
        command: ["sh", "-c", "command -v cliphist >/dev/null || { echo '__missing__'; exit; }; cliphist list | head -n 300"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "__missing__") { root.clips = null; return }
                root.clips = text.split("\n").filter(l => l.includes("\t"))
                if (!thumbProc.running) thumbProc.running = true
            }
        }
    }

    // miniaturas das imagens do histórico: decodifica cada imagem uma vez para o cache
    // (~/.cache/quickshell/cliphist/<id>.<ext>) e apaga as que saíram do histórico
    readonly property string thumbDir: Quickshell.env("HOME") + "/.cache/quickshell/cliphist"
    property int thumbsVersion: 0
    Process {
        id: thumbProc
        command: ["bash", Quickshell.shellDir + "/launcher/clip-thumbs.sh", root.thumbDir]
        onExited: root.thumbsVersion++
    }

    function thumbFor(line) {
        const m = line.match(/^(\d+)\t\[\[ binary data.* (png|jpeg|jpg|bmp|webp|gif) /)
        return m ? thumbDir + "/" + m[1] + "." + m[2] : ""
    }

    // ---------- projetos ----------
    // repositórios git até 3 níveis dentro de cada pasta (mais as pastas listadas sozinhas)
    property var projectRoots: ["~/Projects", "~/Source", "~/BArch"]
    property var projects: []           // [{ name, path, parent }]
    Process {
        id: projProc
        command: ["bash", "-c", `
            for r in "$@"; do
                r="\${r/#\~/$HOME}"; [[ -d "$r" ]] || continue
                [[ -d "$r/.git" ]] && echo "$r"
                find "$r" -mindepth 2 -maxdepth 4 -name .git -not -path "*/node_modules/*" -printf '%h\n' 2>/dev/null
            done | sort -u`, "bash"].concat(root.projectRoots)
        stdout: StdioCollector {
            onStreamFinished: {
                const home = Quickshell.env("HOME")
                root.projects = text.split("\n").filter(l => l.trim() !== "").map(p => {
                    const parts = p.split("/")
                    return { name: parts[parts.length - 1], path: p,
                             parent: parts.slice(0, -1).join("/").replace(home, "~") }
                })
            }
        }
    }

    function projectResults(q) {
        const out = []
        for (const p of projects) {
            const hay = (p.name + " " + p.parent).toLowerCase()
            if (q && !hay.includes(q)) continue
            const used = usage["proj:" + p.path] || 0
            out.push({ kind: "project", title: p.name, subtitle: p.parent, glyph: 0xF0CCF, path: p.path,
                       score: (q && p.name.toLowerCase().startsWith(q) ? 100 : 0) + used })
        }
        out.sort((a, b) => b.score - a.score || a.title.localeCompare(b.title))
        return out.slice(0, 50)
    }

    // ---------- arquivos ----------
    property var files: []
    property bool hasFd: true
    Timer { id: filesDebounce; interval: 160; onTriggered: if (root.mode === "files") filesProc.running = true }
    Process {
        id: filesProc
        command: ["bash", "-c", `
            command -v fd >/dev/null || { echo __missing__; exit; }
            q="$1"; [[ -n "$q" ]] || exit 0
            cd "$HOME" && fd --hidden --follow --max-results 60 --color never \
              --exclude .git --exclude node_modules --exclude .cache --exclude Games \
              --exclude .local/share/Steam --exclude .steam --exclude .wine --exclude .cargo \
              --exclude .nuget --exclude .npm --exclude .local/share/Trash -- "$q" 2>/dev/null`,
            "bash", root.arg]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "__missing__") { root.hasFd = false; root.files = []; return }
                root.hasFd = true
                root.files = text.split("\n").filter(l => l !== "")
            }
        }
    }

    function fileResults(q) {
        if (!hasFd) return [{ kind: "info", title: "fd Not Installed", subtitle: "sudo pacman -S fd", glyph: 0xF0224 }]
        if (!q) return []
        const home = Quickshell.env("HOME")
        return files.map(f => {
            const dir = f.endsWith("/")
            const clean = f.replace(/\/$/, "")
            const i = clean.lastIndexOf("/")
            return { kind: "file", title: clean.slice(i + 1), subtitle: "~/" + (i >= 0 ? clean.slice(0, i) : ""),
                     glyph: dir ? 0xF0256 : 0xF0224, path: home + "/" + clean, dir: dir }
        }).sort((a, b) => (a.title.toLowerCase().startsWith(q) ? 0 : 1) - (b.title.toLowerCase().startsWith(q) ? 0 : 1)
                          || a.subtitle.length - b.subtitle.length)
    }

    // ---------- emojis ----------
    FileView {
        path: Quickshell.shellDir + "/launcher/emojis.json"
        onLoaded: {
            try {
                root.emojis = JSON.parse(text()).map(r => ({ e: r[0], name: r[1], group: r[2], kw: r[3] }))
            } catch (e) { root.emojis = [] }
        }
    }

    // ---------- uso (ranking) ----------
    FileView {
        id: usageFile
        path: root.usagePath
        onLoaded: { try { root.usage = JSON.parse(text()) || {} } catch (e) { root.usage = {} } }
    }
    Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.stateDir])

    function bump(id) {
        const u = Object.assign({}, usage)
        u[id] = (u[id] || 0) + 1
        usage = u
        usageFile.setText(JSON.stringify(u))
    }

    // ---------- busca ----------
    function subseq(s, q) {
        let i = 0
        for (const c of s) if (c === q[i] && ++i === q.length) return true
        return false
    }

    function scoreText(name, extra, q) {
        const n = name.toLowerCase()
        if (n === q) return 100
        if (n.startsWith(q)) return 80
        if (n.split(/[\s\-_.]+/).some(w => w.startsWith(q))) return 60
        if (n.includes(q)) return 45
        for (const [text, pts] of extra)
            if (text && text.toLowerCase().includes(q)) return pts
        if (q.length > 1 && subseq(n, q)) return 10
        return 0
    }

    function usageBonus(id) { return Math.min(20, Math.log2(1 + (usage[id] || 0)) * 5) }

    readonly property var actions: [
        { title: "Lock",       glyph: 0xF0341, keywords: "lock screen",        cmd: ["loginctl", "lock-session"] },
        { title: "Suspend",    glyph: 0xF04B2, keywords: "sleep",              cmd: ["systemctl", "suspend", "-i"] },  // -i: ignore sleep inhibitors, like the power menu
        { title: "Reboot",     glyph: 0xF0709, keywords: "restart",            cmd: ["systemctl", "reboot"] },
        { title: "Shut Down",  glyph: 0xF0425, keywords: "power off poweroff", cmd: ["systemctl", "poweroff"] },
        { title: "Light Mode", glyph: 0xF05A8, keywords: "theme appearance",   cmd: ["qs", "ipc", "call", "theme", "mode", "light"] },
        { title: "Dark Mode",  glyph: 0xF0594, keywords: "theme appearance",   cmd: ["qs", "ipc", "call", "theme", "mode", "dark"] },
        { title: "Auto Theme", glyph: 0xF050E, keywords: "schedule appearance light dark mode", cmd: ["qs", "ipc", "call", "theme", "mode", "auto"] },
        // ferramentas de tela (launcher/tools.sh): digite o atalho (ocr, pick, qr)
        { title: "Copy Text from Screen", alias: "ocr",  sub: "Select an area · OCR",          glyph: 0xF113A, keywords: "ocr text extract recognize read", cmd: ["bash", Quickshell.shellDir + "/launcher/tools.sh", "ocr"] },
        { title: "Pick Color",            alias: "pick", sub: "Click any pixel · copies hex",  glyph: 0xF020A, keywords: "color picker eyedropper hex colour", cmd: ["bash", Quickshell.shellDir + "/launcher/tools.sh", "pick"] },
        { title: "Scan QR Code",          alias: "qr",   sub: "Select the code on screen",     glyph: 0xF0433, keywords: "qr qrcode barcode scan", cmd: ["bash", Quickshell.shellDir + "/launcher/tools.sh", "qr"] }
    ]

    readonly property var apps: DesktopEntries.applications.values.filter(e => !e.noDisplay)

    function appResults(q) {
        const out = []
        if (jsCalc) out.push({ kind: "calc", title: jsCalc, subtitle: trimmed + "  ·  Enter to Copy", glyph: 0xF00EC })

        const scored = []
        for (const e of apps) {
            const s = q === "" ? 1 : scoreText(e.name, [
                [e.genericName, 35], [(e.keywords || []).join(" "), 30], [e.comment, 15], [e.id, 15]
            ], q)
            if (s > 0) scored.push({ s: s + usageBonus(e.id), e: e })
        }
        if (q !== "") for (const a of actions) {
            const s = a.alias === q ? 200 : a.alias && q.length > 1 && a.alias.startsWith(q) ? 90 : scoreText(a.title, [[a.keywords, 30], [a.alias, 70]], q)
            if (s > 0) scored.push({ s: s, a: a })
        }
        scored.sort((x, y) => y.s - x.s || (x.e ? x.e.name : x.a.title).localeCompare(y.e ? y.e.name : y.a.title))

        for (const r of scored) {
            if (r.e) out.push({ kind: "app", title: r.e.name, subtitle: r.e.genericName || r.e.comment || "", icon: r.e.icon, entry: r.e })
            else out.push({ kind: "action", title: r.a.title, subtitle: r.a.sub || "System", glyph: r.a.glyph, cmd: r.a.cmd })
        }

        if (q !== "" && !jsCalc && scored.length === 0)
            out.push({ kind: "run", title: trimmed, subtitle: "Run Command", glyph: 0xF018D })
        return out
    }

    function windowResults(q) {
        const out = []
        for (const w of windows) {
            const cls = w.class || w.initialClass || ""
            const ws = w.workspace ? w.workspace.name : ""
            if (q && !(w.title + " " + cls).toLowerCase().includes(q)) continue
            out.push({ kind: "window", title: w.title, subtitle: cls + (ws ? "  ·  Workspace " + ws : ""),
                       icon: appIconFor(cls), address: w.address })
        }
        return out
    }

    function clipResults(q) {
        if (clips === null)
            return [{ kind: "info", title: "cliphist Not Installed", subtitle: "sudo pacman -S cliphist", glyph: 0xF0A38 }]
        const out = []
        for (const line of clips) {
            const preview = line.slice(line.indexOf("\t") + 1)
            if (q && !preview.toLowerCase().includes(q)) continue
            const isImage = /^\[\[ binary data/.test(preview)
            out.push({ kind: "clip", title: isImage ? "Image" : preview.replace(/\s+/g, " ").trim(),
                       subtitle: isImage ? preview.replace(/^\[\[ binary data |\s*\]\]$/g, "") : "",
                       glyph: isImage ? 0xF0976 : 0xF09ED, line: line, thumb: isImage ? thumbFor(line) : "" })
            if (out.length >= 150) break
        }
        return out
    }

    function emojiResults(q) {
        const out = []
        if (q === "") {
            for (let i = 0; i < Math.min(120, emojis.length); i++) {
                const m = emojis[i]
                out.push({ kind: "emoji", emoji: m.e, title: m.name, subtitle: m.group })
            }
            return out
        }
        const scored = []
        for (const m of emojis) {
            let s = 0
            if (m.name === q) s = 100
            else if (m.name.startsWith(q)) s = 80
            else if (m.name.split(" ").some(w => w.startsWith(q))) s = 60
            else if (m.name.includes(q)) s = 45
            else if (m.kw.split(" ").some(w => w.startsWith(q))) s = 30
            if (s) scored.push({ s: s, m: m })
        }
        scored.sort((a, b) => b.s - a.s)
        for (const r of scored.slice(0, 120))
            out.push({ kind: "emoji", emoji: r.m.e, title: r.m.name, subtitle: r.m.group })
        return out
    }

    function webResults(q) {
        if (q === "") return []
        const isUrl = /^(https?:\/\/)?[\w-]+(\.[\w-]+)*\.[a-z]{2,}(:\d+)?(\/\S*)?$/i.test(q) && !/\s/.test(q)
        const out = []
        if (isUrl) out.push({ kind: "web", title: q, subtitle: "Open Link", glyph: 0xF0339,
                              url: /^https?:\/\//.test(q) ? q : "https://" + q })
        out.push({ kind: "web", title: q, subtitle: "Search the Web", glyph: 0xF059F,
                   url: searchUrl + encodeURIComponent(q) })
        return out
    }

    readonly property var results: {
        const q = arg.toLowerCase()
        switch (mode) {
        case "run":
            return arg ? [
                { kind: "run",  title: arg, subtitle: "Run Command", glyph: 0xF018D },
                { kind: "term", title: arg, subtitle: "Run in Terminal  ·  Shift+Enter", glyph: 0xF07B7 }
            ] : []
        case "qalc":
            if (!hasQalc) return [{ kind: "info", title: "qalc Not Installed", subtitle: "sudo pacman -S libqalculate", glyph: 0xF00EC }]
            return qalcResult ? [{ kind: "calc", title: qalcResult, subtitle: arg + "  ·  Enter to Copy", glyph: 0xF00EC }] : []
        case "windows": return windowResults(q)
        case "clip":    return clipResults(q)
        case "projects": return projectResults(q)
        case "files":   return fileResults(q)
        case "emoji":   return emojiResults(q)
        case "web":     return webResults(arg)
        case "agent":
            return [
                { kind: "agent", title: arg || "New Conversation", subtitle: arg ? "Ask Claude" : "Open Claude in ~/BArch", glyph: 0xF06A9 },
                { kind: "agent", title: arg || "Last Conversation", subtitle: "Continue the Last Conversation  ·  Shift+Enter", glyph: 0xF02DA, resume: true }
            ]
        default:        return appResults(q)
        }
    }

    // ---------- ações ----------
    function activate(index, shift) {
        const r = results[index]
        if (!r || r.kind === "info") return
        switch (r.kind) {
        case "app":
            bump(r.entry.id)
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
            if (shift && hasWtype)
                Quickshell.execDetached(["sh", "-c", 'sleep 0.25; wtype -- "$1"', "sh", r.emoji])
            break
        case "web":
            Quickshell.execDetached(["xdg-open", r.url])
            break
        case "project":
            bump("proj:" + r.path)
            if (shift) Quickshell.execDetached(["thunar", r.path])
            else Quickshell.execDetached([terminal, "-D", r.path, "nvim", "."])
            break
        case "file":
            Quickshell.execDetached(["xdg-open", shift && !r.dir ? r.path.slice(0, r.path.lastIndexOf("/")) : r.path])
            break
        case "agent":
            Quickshell.execDetached(["barch", "agent", "ask"].concat(shift || r.resume ? ["--continue"] : [], arg ? [arg] : []))
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
        case "emoji":   return hasWtype ? "↵ Copy   ·   ⇧↵ Type It   ·   Esc Close" : "↵ Copy   ·   Esc Close"
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
                                    root.close()
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
                    Layout.preferredHeight: Math.min(count, root.maxRows) * (root.rowHeight + spacing)
                    visible: count > 0
                    clip: true
                    spacing: 2
                    model: root.results
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
                                    source: row.hasThumb && root.thumbsVersion > 0 ? "file://" + row.modelData.thumb : ""
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
                                    color: Theme.fg
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
                        case "projects": return root.arg ? "No matching projects" : "No git projects found in " + root.projectRoots.join(", ")
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
