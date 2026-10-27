// QuickNotes.qml — bloco de notas rápido (Super+N), no visual da barra.
// Um painel no canto direito com um texto que se salva sozinho em ~/Documents/Quick Notes.md
// (dá para abrir em qualquer editor). Esc ou clicar fora fecha; o texto continua lá.
// Abre com:  qs ipc call notes toggle

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"

Scope {
    id: root

    property bool shown: false
    readonly property string path: Quickshell.env("HOME") + "/Documents/Quick Notes.md"
    property bool loadedOnce: false
    property bool dirty: false

    function pickScreen() {
        const m = Hyprland.focusedMonitor
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; i++)
            if (m && screens[i].name === m.name) return screens[i]
        return screens[0]
    }
    function open() {
        if (Popups.current) Popups.hide(Popups.current)
        win.screen = pickScreen()
        hideTimer.stop()
        win.visible = true
        shown = true
        Qt.callLater(() => { editor.forceActiveFocus(); editor.cursorPosition = editor.length })
    }
    function close() {
        if (!win.visible) return
        if (dirty) save()
        shown = false
        hideTimer.restart()
    }
    function toggle() { win.visible && shown ? close() : open() }

    function save() {
        dirty = false
        Quickshell.execDetached(["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s" "$1" > "$2"',
                                 "sh", editor.text, path])
    }

    FileView {
        id: file
        path: root.path
        onLoaded: { if (!root.loadedOnce) { editor.text = text(); root.loadedOnce = true } }
        onLoadFailed: root.loadedOnce = true
    }

    IpcHandler {
        target: "notes"
        function toggle(): void { root.toggle() }
        function open(): void { root.open() }
        function close(): void { root.close() }
    }

    Timer { id: hideTimer; interval: 140; onTriggered: win.visible = false }
    Timer { id: autosave; interval: 600; onTriggered: root.save() }

    PanelWindow {
        id: win
        visible: false
        color: "transparent"
        anchors { top: true; right: true }
        margins { top: Theme.islandHeight + Theme.gap + Theme.popupGap; right: Theme.gap }
        implicitWidth: 440
        implicitHeight: 520
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-notes"
        WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        HyprlandFocusGrab {
            windows: [win]
            active: win.visible
            onCleared: root.close()
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            opacity: root.shown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            transform: Translate { y: root.shown ? 0 : -8; Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: "Quick Notes"
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                        font.bold: true
                    }
                    Text {
                        text: root.dirty ? "Saving…" : "Saved"
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 3
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    TextArea {
                        id: editor
                        wrapMode: TextEdit.Wrap
                        color: Theme.fg
                        selectionColor: Theme.accent
                        selectedTextColor: Theme.crust
                        placeholderText: "Write anything… it saves by itself."
                        placeholderTextColor: Theme.dim
                        font.family: Theme.monoFont
                        font.pixelSize: Theme.fontSize
                        background: null
                        padding: 4
                        onTextChanged: if (root.loadedOnce) { root.dirty = true; autosave.restart() }
                        Keys.onEscapePressed: root.close()
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "~/Documents/Quick Notes.md   ·   Esc Close"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize - 3
                    elide: Text.ElideMiddle
                }
            }
        }
    }
}
