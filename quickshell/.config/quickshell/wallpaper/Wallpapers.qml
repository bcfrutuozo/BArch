pragma Singleton

// Wallpapers.qml — qual cena de ~/Pictures/Wallpapers vai no desktop e na tela de bloqueio, e qual
// arquivo dela vai em cada monitor. tools/make_wallpapers.py desenha cada cena nas cores de cada
// paleta do Theme.qml: <paleta>/<cena>/primary.png (principal, paisagem), secondary.png
// (vertical), as versões *-lock.png (pequenas, desfocadas, para o lock) e thumb.png (seletor);
// <paleta>/scenes.json lista as cenas prontas e scenes.json (na raiz) o catálogo e as paletas
// renderizadas. A pasta usada é a da paleta em uso (Theme.flavor): trocar o modo ou a paleta
// fixada troca o papel de parede sem script. Uma paleta ainda sem pasta usa a padrão do seu lado
// (dracula / latte) e é renderizada aqui, em segundo plano, na primeira vez.
//
// A escolha fica em ~/.local/state/quickshell/wallpaper.json ({"desktop": id, "lock": id}); o lock
// (quickshell/lock, outro processo) lê o mesmo arquivo, e a paleta pelo theme.json.
// Seletor: launcher "b " (Launcher.qml) e o bloco Wallpaper da central de controle.
//   qs ipc call wallpaper status | list | set <cena> <desktop|lock|both> | render [<paleta>|all]

import Quickshell
import Quickshell.Io
import "../theme"

Singleton {
    id: root

    readonly property string dir: Quickshell.env("HOME") + "/Pictures/Wallpapers"
    readonly property string stateFile: Quickshell.env("HOME") + "/.local/state/quickshell/wallpaper.json"
    readonly property var names: ({ "HDMI-A-2": "primary" })      // os outros monitores: secondary (retrato)
    readonly property string defaultScene: "mountains"

    // ---- paleta ----
    readonly property string palette: Theme.flavor                               // a em uso
    readonly property string fallbackPalette: Theme.isDark ? "dracula" : "latte"  // a que o install.sh gera
    property var catalog: []                // [{ id, label, description }] (scenes.json)
    property var rendered: []               // paletas com pasta pronta
    readonly property bool available: rendered.indexOf(palette) >= 0
    readonly property string used: available ? palette : (rendered.indexOf(fallbackPalette) >= 0 ? fallbackPalette : palette)
    property var paletteScenes: []          // ids prontos na pasta usada

    FileView {
        id: catalogView
        path: root.dir + "/scenes.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const c = JSON.parse(text())
                if (JSON.stringify(c.scenes || []) !== JSON.stringify(root.catalog)) root.catalog = c.scenes || []
                if (JSON.stringify(c.palettes || []) !== JSON.stringify(root.rendered)) { root.rendered = c.palettes || []; root.otherRunning = false }
            } catch (e) { console.warn("wallpapers: invalid scenes.json:", e) }
        }
    }
    FileView {
        id: paletteView
        path: root.dir + "/" + root.used + "/scenes.json"
        watchChanges: true
        printErrors: false
        onPathChanged: reload()
        onFileChanged: reload()
        onLoaded: {
            try { root.paletteScenes = JSON.parse(text()).scenes || [] }
            catch (e) { console.warn("wallpapers: invalid", path, e) }
        }
        onLoadFailed: root.paletteScenes = []
    }
    readonly property var scenes: catalog.filter(s => paletteScenes.indexOf(s.id) >= 0)

    // ---- render em segundo plano da paleta que ainda não tem pasta ----
    property bool rendering: false
    property string renderingPalette: ""
    Process {
        id: renderProc
        property string target: ""
        // o próprio script sai com 75 quando outro gerador já está rodando (trava em <pasta>/.lock)
        command: ["sh", "-c", 'exec nice -n 10 python3 "$(readlink -f "$HOME/.config/quickshell")/../../../tools/make_wallpapers.py" "$1" $2',
                  "sh", root.dir, target === "all" ? "--all" : "-p " + target]
        stdout: StdioCollector {}
        stderr: StdioCollector { id: renderErr }
        onExited: code => {
            root.rendering = false
            catalogView.reload()
            if (code === 0)
                Quickshell.execDetached(["barch", "notify", "Wallpapers", "The " + Theme.flavorLabel(root.renderingPalette) + " set is ready.", "--low", "--app", "Wallpapers"])
            else if (code === 75) {
                console.log("wallpapers: another make_wallpapers.py is running; waiting for its catalog")
                root.otherRunning = true
            }
            else {
                console.warn("wallpapers: render failed:", renderErr.text)
                Quickshell.execDetached(["barch", "notify", "Wallpapers", "Rendering " + root.renderingPalette + " failed (see the bar log).", "--app", "Wallpapers"])
            }
            root.renderingPalette = ""
            if (code !== 75) root.ensure()
        }
    }
    property bool otherRunning: false       // um gerador de fora está rodando: espera o catálogo dele
    function render(target) {
        if (rendering || target === "draft") return false      // o rascunho do editor não tem pasta nem entra no JSON
        renderProc.target = target
        renderingPalette = target
        rendering = true
        renderProc.running = true
        Quickshell.execDetached(["barch", "notify", "Wallpapers",
            target === "all" ? "Rendering every palette in the background…"
                             : "Rendering the " + Theme.flavorLabel(target) + " set in the background (about a minute)…",
            "--low", "--app", "Wallpapers"])
        return true
    }
    // a paleta em uso sem pasta: manda renderizar (uma vez por vez; o catálogo avisa quando ficar pronta)
    function ensure() {
        if (catalog.length === 0) return                   // sem catálogo nenhum, o install ainda não gerou nada
        // `rendered` lido direto: quando onRenderedChanged chama isto, o binding `available` ainda
        // pode não ter sido reavaliado (dava false com a paleta já na lista) e cada início da barra
        // mandava renderizar de novo a paleta em uso
        // "draft" (preview do editor) não está em palettes.json: o gerador saía com 2, a falha
        // chamava ensure() de novo e cada volta mandava uma notificação
        if (palette === "draft" || rendered.indexOf(palette) >= 0 || rendering || otherRunning || !Theme.palettes[palette]) return
        render(palette)
    }
    onPaletteChanged: ensure()
    onRenderedChanged: ensure()

    // ---- cena de cada lado ----
    property string desktop: defaultScene
    property string lock: defaultScene
    FileView {
        path: root.stateFile
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const s = JSON.parse(text())
                if (typeof s.desktop === "string" && s.desktop !== "") root.desktop = s.desktop
                if (typeof s.lock === "string" && s.lock !== "") root.lock = s.lock
            } catch (e) { console.warn("wallpapers: invalid wallpaper.json:", e) }
        }
    }

    function nameFor(screenName) { return names[screenName] || "secondary" }
    function path(screenName) { return dir + "/" + used + "/" + desktop + "/" + nameFor(screenName) + ".png" }
    function thumb(scene) { return dir + "/" + used + "/" + scene + "/thumb.png" }
    function has(id) { return catalog.some(s => s.id === id) }
    function label(id) {
        const s = catalog.find(s => s.id === id)
        return s ? s.label : (id ? id.charAt(0).toUpperCase() + id.slice(1) : "")
    }
    // onde a cena está em uso: "Desktop & Lock Screen", "Desktop", "Lock Screen" ou ""
    function usedIn(id) {
        if (id === desktop && id === lock) return "Desktop & Lock Screen"
        if (id === desktop) return "Desktop"
        if (id === lock) return "Lock Screen"
        return ""
    }

    // target: "desktop" | "lock" | "both"
    function set(scene, target) {
        if (!has(scene)) return false
        if (target !== "lock") desktop = scene
        if (target !== "desktop") lock = scene
        Theme.writeFile(stateFile, JSON.stringify({ desktop: desktop, lock: lock }, null, 2) + "\n")
        return true
    }

    function state() {
        return { ok: true, desktop: desktop, lock: lock, palette: palette, used: used, available: available,
                 rendering: rendering ? renderingPalette : "", palettes: rendered, scenes: scenes.map(s => s.id) }
    }
    IpcHandler {
        target: "wallpaper"
        function status(): string { return JSON.stringify(root.state()) }
        function list(): string { return JSON.stringify({ ok: true, scenes: root.scenes, desktop: root.desktop, lock: root.lock, palette: root.used }) }
        function set(scene: string, target: string): string {
            if (target !== "desktop" && target !== "lock" && target !== "both")
                return JSON.stringify({ ok: false, error: "target: desktop | lock | both" })
            if (!root.set(scene, target))
                return JSON.stringify({ ok: false, error: "unknown scene: " + scene + " (" + root.catalog.map(s => s.id).join(", ") + ")" })
            return JSON.stringify(root.state())
        }
        // renderiza a pasta de uma paleta (ou "all"); "" = a em uso
        function render(target: string): string {
            const t = target === "" ? root.palette : target
            if (t !== "all" && !Theme.palettes[t]) return JSON.stringify({ ok: false, error: "unknown palette: " + t })
            if (!root.render(t)) return JSON.stringify({ ok: false, error: t === "draft" ? "'draft' is the editor's preview, save it first" : "already rendering " + root.renderingPalette })
            return JSON.stringify(root.state())
        }
    }
}
