// LauncherSources.qml — o que o launcher lista: as fontes de cada modo (apps, janelas, clipboard,
// projetos, arquivos, emojis, web, papéis de parede, calculadora) e o ranking. Launcher.qml
// (janela, teclas, ações) liga `mode`, `arg`, `trimmed`, `jsCalc` e `wallPick` aqui e lê
// `results`; chama refresh() a cada tecla e bump() quando algo é aberto.
//
// Cada resultado é { kind, title, subtitle, ... } com o que a ação do kind precisa (entry, cmd,
// address, line, emoji, url, path, scene...). kind "info" é só uma linha de aviso.

import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"
import "../wallpaper"

Scope {
    id: src

    // ligados pelo Launcher
    property string mode: "apps"
    property string arg: ""
    property string trimmed: ""
    property string jsCalc: ""          // conta simples já resolvida pelo Launcher ("" = nenhuma)
    property string wallPick: ""        // cena escolhida no modo "b ", à espera de "onde aplicar"
    property string searchUrl: "https://www.google.com/search?q="

    property var usage: ({})            // id do .desktop -> quantas vezes foi aberto
    property bool hasQalc: false
    property bool hasWtype: false
    property string qalcResult: ""
    property var windows: []            // de "hyprctl clients -j"
    property var clips: []              // linhas do "cliphist list"
    property var emojis: []             // [{ e, name, group, kw }]

    readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/quickshell"
    readonly property string usagePath: stateDir + "/launcher-usage.json"

    onModeChanged: {
        if (mode === "windows") winProc.running = true
        if (mode === "clip") clipProc.running = true
        if (mode === "projects") projProc.running = true
    }

    // a cada tecla (o Launcher chama com os valores já atualizados)
    function refresh(mode, arg) {
        qalcResult = ""
        if (mode === "qalc" && hasQalc && arg.length > 0) qalcDebounce.restart()
        if (mode === "files") filesDebounce.restart()
    }

    // ---------- calculadora ----------
    Timer {
        id: qalcDebounce
        interval: 150
        onTriggered: {
            qalcProc.command = ["qalc", "-t", src.arg]
            qalcProc.running = true
        }
    }
    Process {
        id: qalcProc
        stdout: StdioCollector {
            onStreamFinished: src.qalcResult = text.trim().split("\n").pop() || ""
        }
    }
    Process {
        command: ["sh", "-c", "command -v qalc >/dev/null && echo qalc; command -v wtype >/dev/null && echo wtype; true"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                src.hasQalc = text.includes("qalc")
                src.hasWtype = text.includes("wtype")
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
                    src.windows = list
                } catch (e) { src.windows = [] }
            }
        }
    }

    function appIconFor(cls) {
        if (!cls) return ""
        let e = null
        try { e = DesktopEntries.heuristicLookup(cls) } catch (err) { e = DesktopEntries.byId(cls) }
        return e ? e.icon : cls
    }

    // ---------- clipboard ----------
    Process {
        id: clipProc
        command: ["sh", "-c", "command -v cliphist >/dev/null || { echo '__missing__'; exit; }; cliphist list | head -n 300"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "__missing__") { src.clips = null; return }
                src.clips = text.split("\n").filter(l => l.includes("\t"))
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
        command: ["bash", Quickshell.shellDir + "/launcher/clip-thumbs.sh", src.thumbDir]
        onExited: src.thumbsVersion++
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
            done | sort -u`, "bash"].concat(src.projectRoots)
        stdout: StdioCollector {
            onStreamFinished: {
                const home = Quickshell.env("HOME")
                src.projects = text.split("\n").filter(l => l.trim() !== "").map(p => {
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
    Timer { id: filesDebounce; interval: 160; onTriggered: if (src.mode === "files") filesProc.running = true }
    Process {
        id: filesProc
        command: ["bash", "-c", `
            command -v fd >/dev/null || { echo __missing__; exit; }
            q="$1"; [[ -n "$q" ]] || exit 0
            cd "$HOME" && fd --hidden --follow --max-results 60 --color never \
              --exclude .git --exclude node_modules --exclude .cache --exclude Games \
              --exclude .local/share/Steam --exclude .steam --exclude .wine --exclude .cargo \
              --exclude .nuget --exclude .npm --exclude .local/share/Trash -- "$q" 2>/dev/null`,
            "bash", src.arg]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "__missing__") { src.hasFd = false; src.files = []; return }
                src.hasFd = true
                src.files = text.split("\n").filter(l => l !== "")
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
                src.emojis = JSON.parse(text()).map(r => ({ e: r[0], name: r[1], group: r[2], kw: r[3] }))
            } catch (e) { src.emojis = [] }
        }
    }

    // ---------- uso (ranking) ----------
    FileView {
        id: usageFile
        path: src.usagePath
        onLoaded: { try { src.usage = JSON.parse(text()) || {} } catch (e) { src.usage = {} } }
    }
    Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", src.stateDir])

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
        { title: "Palette Editor", alias: "palette", sub: "New palettes, from an image, live preview", glyph: 0xF03D8, keywords: "theme colors palette editor create", cmd: ["barch", "theme", "edit"] },
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

    function wallResults(q) {
        if (wallPick !== "") {
            const name = Wallpapers.label(wallPick)
            return [
                { kind: "wallto", target: "both",    title: "Desktop and Lock Screen", subtitle: name, glyph: 0xF0E09, scene: wallPick },
                { kind: "wallto", target: "desktop", title: "Desktop Only",            subtitle: name, glyph: 0xF0379, scene: wallPick },
                { kind: "wallto", target: "lock",    title: "Lock Screen Only",        subtitle: name, glyph: 0xF033E, scene: wallPick }
            ]
        }
        if (Wallpapers.scenes.length === 0)
            return [{ kind: "info", title: "No Wallpapers Found", subtitle: "tools/make_wallpapers.py ~/Pictures/Wallpapers", glyph: 0xF0E09 }]
        const out = []
        if (!Wallpapers.available)
            out.push({ kind: "info", title: (Wallpapers.rendering ? "Rendering the " : "No ") + Theme.flavorLabel(Wallpapers.palette) + " set"
                       + (Wallpapers.rendering ? "…" : ""), subtitle: "Showing " + Theme.flavorLabel(Wallpapers.used) + " meanwhile", glyph: 0xF0E09 })
        for (const sc of Wallpapers.scenes) {
            if (q && !(sc.label + " " + sc.id + " " + sc.description).toLowerCase().includes(q)) continue
            const used = Wallpapers.usedIn(sc.id)
            out.push({ kind: "wall", title: sc.label, subtitle: sc.description + (used ? "  ·  " + used : ""),
                       scene: sc.id, thumb: Wallpapers.thumb(sc.id), active: used !== "" })
        }
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
        case "wall":    return wallResults(q)
        case "agent":
            return [
                { kind: "agent", title: arg || "New Conversation", subtitle: arg ? "Ask Claude" : "Open Claude in ~/BArch", glyph: 0xF06A9 },
                { kind: "agent", title: arg || "Last Conversation", subtitle: "Continue the Last Conversation  ·  Shift+Enter", glyph: 0xF02DA, resume: true }
            ]
        default:        return appResults(q)
        }
    }
}
