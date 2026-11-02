// Ui.qml — colors and fonts of the settings app, from the bar's theme state
// (~/.local/state/quickshell/theme.json, the same file the lock screen follows), live.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: ui

    readonly property string themePath: Quickshell.env("HOME") + "/.local/state/quickshell/theme.json"
    property var theme: ({})
    readonly property var c: theme.colors || ({})
    readonly property bool dark: theme.dark !== false

    readonly property color crust:   c.crust   || "#191a21"
    readonly property color base:    c.base    || "#282a36"
    readonly property color surface: c.surface || "#44475a"
    readonly property color overlay: c.overlay || "#6272a4"
    readonly property color subtext: c.subtext || "#8b94c3"
    readonly property color text:    c.text    || "#f8f8f2"
    readonly property color accent:  c.accent  || "#bd93f9"
    readonly property color green:   c.green   || "#50fa7b"
    readonly property color yellow:  c.yellow  || "#f1fa8c"
    readonly property color red:     c.red     || "#ff5555"

    // a slightly different ground for cards and the sidebar
    readonly property color raised: dark ? Qt.lighter(base, 1.12) : Qt.darker(base, 1.04)
    readonly property color sunken: dark ? Qt.darker(base, 1.12) : Qt.darker(base, 1.03)
    readonly property color faint: Qt.rgba(text.r, text.g, text.b, 0.06)

    readonly property string font: theme.font || "SF Pro Text"
    readonly property string monoFont: "JetBrainsMono Nerd Font"
    readonly property string iconFont: theme.iconFont || "Symbols Nerd Font"
    readonly property int fontSize: 13
    readonly property int radius: 8
    readonly property int cardRadius: 10

    function read() {
        try { theme = JSON.parse(themeFile.text()) } catch (e) {}
    }
    FileView {
        id: themeFile
        path: ui.themePath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: ui.read()
    }
    Component.onCompleted: read()
}
