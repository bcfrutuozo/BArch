pragma Singleton

// Wallpapers.qml — qual arquivo de ~/Pictures/Wallpapers vai em cada monitor, no modo atual
// (tools/make_wallpapers.py gera primary-<modo>.png para o principal, paisagem, e
// secondary-<modo>.png para o vertical). Usado pelo Wallpaper (fundo) e pelo Overview.
// O modo segue Theme.isDark, então a troca de tema troca o papel de parede sem script nenhum.

import Quickshell
import "../theme"

Singleton {
    id: root

    readonly property string dir: Quickshell.env("HOME") + "/Pictures/Wallpapers"
    readonly property string mode: Theme.isDark ? "dark" : "light"
    readonly property var names: ({ "HDMI-A-2": "primary" })      // os outros monitores: secondary (retrato)

    function nameFor(screenName) { return names[screenName] || "secondary" }
    function path(screenName) { return dir + "/" + nameFor(screenName) + "-" + mode + ".png" }
}
