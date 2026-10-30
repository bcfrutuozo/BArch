pragma Singleton

// Wallpapers.qml — qual cena de ~/Pictures/Wallpapers vai no desktop e na tela de bloqueio, e qual
// arquivo dela vai em cada monitor no modo atual. tools/make_wallpapers.py gera, por cena,
// <cena>/primary-<modo>.png (principal, paisagem), secondary-<modo>.png (vertical), as versões
// *-lock-* (pequenas, desfocadas, para o lock) e thumb-<modo>.png (seletor), e lista as cenas em
// scenes.json. O modo segue Theme.isDark, então a troca de tema troca o papel de parede sem script.
//
// A escolha fica em ~/.local/state/quickshell/wallpaper.json ({"desktop": id, "lock": id}); o lock
// (quickshell/lock, outro processo) lê o mesmo arquivo com um FileView que acompanha mudanças.
// Seletor: launcher "b " (Launcher.qml) e o bloco Wallpaper da central de controle.
//   qs ipc call wallpaper status | list | set <cena> <desktop|lock|both>     (JSON; barch wallpaper)

import Quickshell
import Quickshell.Io
import "../theme"

Singleton {
    id: root

    readonly property string dir: Quickshell.env("HOME") + "/Pictures/Wallpapers"
    readonly property string stateFile: Quickshell.env("HOME") + "/.local/state/quickshell/wallpaper.json"
    readonly property string mode: Theme.isDark ? "dark" : "light"
    readonly property var names: ({ "HDMI-A-2": "primary" })      // os outros monitores: secondary (retrato)
    readonly property string defaultScene: "mountains"

    property var scenes: []                 // [{ id, label, description }] (scenes.json)
    property string desktop: defaultScene
    property string lock: defaultScene

    FileView {
        path: root.dir + "/scenes.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try { root.scenes = JSON.parse(text()).scenes || [] }
            catch (e) { console.warn("wallpapers: invalid scenes.json:", e) }
        }
    }
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
    function path(screenName) { return dir + "/" + desktop + "/" + nameFor(screenName) + "-" + mode + ".png" }
    function thumb(scene, m) { return dir + "/" + scene + "/thumb-" + (m || mode) + ".png" }
    function has(id) { return scenes.some(s => s.id === id) }
    function label(id) {
        const s = scenes.find(s => s.id === id)
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
        return { ok: true, desktop: desktop, lock: lock, mode: mode, scenes: scenes.map(s => s.id) }
    }
    IpcHandler {
        target: "wallpaper"
        function status(): string { return JSON.stringify(root.state()) }
        function list(): string { return JSON.stringify({ ok: true, scenes: root.scenes, desktop: root.desktop, lock: root.lock }) }
        function set(scene: string, target: string): string {
            if (target !== "desktop" && target !== "lock" && target !== "both")
                return JSON.stringify({ ok: false, error: "target: desktop | lock | both" })
            if (!root.set(scene, target))
                return JSON.stringify({ ok: false, error: "unknown scene: " + scene + " (" + root.scenes.map(s => s.id).join(", ") + ")" })
            return JSON.stringify(root.state())
        }
    }
}
