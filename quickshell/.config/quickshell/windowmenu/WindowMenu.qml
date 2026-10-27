// WindowMenu.qml — menu de janela no clique direito (Alt+Tab, visão geral, minimizados).
//
// Uso:  WindowMenu { id: menu; onDone: … }   e no clique direito:
//       menu.show(item, x, y, { address, title, ws, floating, pinned, minimized })
// Ações: Restore (se minimizada) ou Minimize, Always on Top, Fullscreen, Move to Workspace 1–10, Close.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "../theme"
import "../minimize"
import "../pin"

PopupWindow {
    id: menu

    property var win: null              // a janela do menu
    signal done()                       // depois de uma ação (o dono fecha/atualiza)

    function strip(a) { return (a || "").toString().replace(/^0x/, "") }
    function sel() { return '"address:0x' + strip(win.address) + '"' }
    function dispatch(s) { Hyprland.dispatch(s) }

    function show(item, x, y, w) {
        win = w
        anchor.item = item
        anchor.rect.x = x
        anchor.rect.y = y
        visible = true
    }

    function act(name, arg) {
        const w = win
        visible = false
        if (!w) return
        switch (name) {
        case "restore":    Minimized.restore(w.address); break
        case "minimize":   Minimized.minimize(w.address, w.ws); break
        case "pin":        w.pinned ? Pinned.unpin(strip(w.address), w.floating) : Pinned.pin(strip(w.address), w.floating); break
        case "fullscreen":
            dispatch('hl.dsp.focus({ window = ' + sel() + ' })')
            dispatch('hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle", window = ' + sel() + ' })')
            break
        case "move":       dispatch('hl.dsp.window.move({ workspace = "' + arg + '", follow = false, window = ' + sel() + ' })'); break
        case "close":      dispatch('hl.dsp.window.close({ window = ' + sel() + ' })'); break
        }
        done()
    }

    anchor.rect.width: 1
    anchor.rect.height: 1
    anchor.edges: Edges.Top | Edges.Left
    anchor.gravity: Edges.Bottom | Edges.Right
    implicitWidth: 230
    implicitHeight: body.implicitHeight + 16
    visible: false
    color: "transparent"

    HyprlandFocusGrab {
        windows: [menu]
        active: menu.visible
        onCleared: menu.visible = false
    }

    component Item_: Rectangle {
        id: it
        property int icon: 0
        property string label: ""
        property bool danger: false
        signal triggered()
        Layout.fillWidth: true
        implicitHeight: 30
        radius: Theme.buttonRadius
        color: m.containsMouse ? Theme.hover : "transparent"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10
            Text {
                text: String.fromCodePoint(it.icon)
                color: it.danger && m.containsMouse ? Theme.red : Theme.dim
                font.family: Theme.iconFont
                font.pixelSize: Theme.fontSize + 1
            }
            Text {
                Layout.fillWidth: true
                text: it.label
                color: it.danger && m.containsMouse ? Theme.red : Theme.fg
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 1
            }
        }
        MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: it.triggered() }
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.popupRadius
        color: Theme.bg
        border.color: Theme.border
        border.width: 1

        ColumnLayout {
            id: body
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
            spacing: 2

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                Layout.bottomMargin: 4
                text: menu.win ? menu.win.title : ""
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 3
                elide: Text.ElideRight
            }

            Item_ {
                visible: menu.win && menu.win.minimized
                icon: 0xF05B2; label: "Restore"           // window_restore
                onTriggered: menu.act("restore")
            }
            Item_ {
                visible: menu.win && !menu.win.minimized
                icon: 0xF05B0; label: "Minimize"          // window_minimize
                onTriggered: menu.act("minimize")
            }
            Item_ {
                visible: menu.win && !menu.win.minimized
                icon: menu.win && menu.win.pinned ? 0xF0930 : 0xF0931
                label: menu.win && menu.win.pinned ? "Unpin" : "Always on Top"
                onTriggered: menu.act("pin")
            }
            Item_ {
                visible: menu.win && !menu.win.minimized
                icon: 0xF0293; label: "Fullscreen"        // fullscreen
                onTriggered: menu.act("fullscreen")
            }

            Text {
                Layout.leftMargin: 6
                Layout.topMargin: 4
                text: "Move to Workspace"
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 3
            }
            GridLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 4
                Layout.rightMargin: 4
                columns: 5
                rowSpacing: 4
                columnSpacing: 4
                Repeater {
                    model: 10
                    Rectangle {
                        id: wsBtn
                        required property int index
                        readonly property string ws: String(index + 1)
                        readonly property bool here: menu.win && menu.win.ws === ws
                        Layout.fillWidth: true
                        implicitHeight: 26
                        radius: 6
                        color: wm.containsMouse ? Theme.hover : "transparent"
                        border.width: 1
                        border.color: here ? Theme.accent : Theme.border
                        Text {
                            anchors.centerIn: parent
                            text: wsBtn.ws
                            color: wsBtn.here ? Theme.accent : Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                        }
                        MouseArea {
                            id: wm
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: menu.act("move", wsBtn.ws)
                        }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.topMargin: 4; Layout.bottomMargin: 2; implicitHeight: 1; color: Theme.surface }

            Item_ {
                icon: 0xF05AD; label: "Close"; danger: true   // window_close
                onTriggered: menu.act("close")
            }
        }
    }
}
