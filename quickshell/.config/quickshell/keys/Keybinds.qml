// Keybinds.qml — folha de atalhos do Hyprland (Super + /).
//
// Lê os atalhos de "hyprctl binds -j" toda vez que abre, então mostra sempre o que
// está valendo (inclusive os criados em laços, como os dos workspaces).
// O texto vem da opção description de cada hl.bind, no formato "Grupo|Descrição":
//     hl.bind(mainMod .. " + T", hl.dsp.exec_cmd(terminal), { description = "Apps|Terminal" })
// Atalhos sem description aparecem em "Other", com o comando que executam;
// os do grupo "Hidden" não aparecem.
// Sequências numeradas ("Go to Workspace 1", "… 2", …) viram uma linha só.
//
// Abre no monitor em foco com:  qs ipc call keys toggle
// Teclas: digite para filtrar · Esc fecha.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../theme"

Scope {
    id: root

    property bool shown: false
    property var groups: []          // [{ name, items: [{ keys: [..], label }] }]
    property string filter: ""

    function open() {
        if (Popups.current) Popups.hide(Popups.current)
        win.screen = pickScreen()
        filter = ""
        search.text = ""
        hideTimer.stop()
        bindsProc.running = true
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

    IpcHandler {
        target: "keys"
        function toggle(): void { root.toggle() }
        function open(): void { root.open() }
        function close(): void { root.close() }
    }

    Timer { id: hideTimer; interval: 140; onTriggered: win.visible = false }

    // ---------- leitura ----------
    Process {
        id: bindsProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.groups = root.build(JSON.parse(text)) }
                catch (e) { root.groups = [{ name: "Error", items: [{ keys: [], label: "Couldn't read hyprctl binds: " + e }] }] }
            }
        }
    }

    // modmask do Hyprland → nomes
    readonly property var modNames: [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"]]
    readonly property var keyNames: ({
        left: "←", right: "→", up: "↑", down: "↓",
        slash: "/", period: ".", comma: ",", space: "Space", SPACE: "Space", Return: "Enter", Escape: "Esc", Tab: "Tab",
        Print: "Print Screen", BackSpace: "Backspace", Delete: "Del",
        "mouse:272": "Left Drag", "mouse:273": "Right Drag", "mouse:274": "Middle Click",
        mouse_down: "Scroll Down", mouse_up: "Scroll Up",
        XF86AudioRaiseVolume: "Volume Up", XF86AudioLowerVolume: "Volume Down",
        XF86AudioMute: "Mute", XF86AudioMicMute: "Mic Mute",
        XF86MonBrightnessUp: "Brightness Up", XF86MonBrightnessDown: "Brightness Down",
        XF86AudioNext: "Next Track", XF86AudioPrev: "Previous Track",
        XF86AudioPlay: "Play", XF86AudioPause: "Pause"
    })

    function keyName(k) {
        if (keyNames[k] !== undefined) return keyNames[k]
        if (k.length === 1) return k.toUpperCase()
        return k.charAt(0).toUpperCase() + k.slice(1)
    }

    function mods(mask) {
        return modNames.filter(m => (mask & m[0]) !== 0).map(m => m[1])
    }

    function describe(b) {
        const arg = (b.arg || "").toString().trim()
        const d = (b.dispatcher || "").toString()
        const s = d && arg ? d + " " + arg : (d || arg)
        return s.length > 70 ? s.slice(0, 67) + "…" : s
    }

    function build(list) {
        const order = []
        const byName = {}
        const merged = {}           // grupo|mods|prefixo → item numerado
        for (const b of list) {
            if (b.submap && b.submap !== "" && b.submap !== "global") continue
            const raw = (b.description || b.desc || "").toString().trim()
            let group = "Other", label = raw
            const bar = raw.indexOf("|")
            if (bar >= 0) { group = raw.slice(0, bar).trim() || "Other"; label = raw.slice(bar + 1).trim() }
            if (group === "Hidden") continue          // atalhos auxiliares (ex.: soltar o Alt do Alt+Tab)
            if (label === "") label = describe(b)

            const m = mods(b.modmask || 0)
            const key = keyName((b.key || "").toString())
            if (!byName[group]) { byName[group] = { name: group, items: [] }; order.push(group) }

            // "Go to Workspace 3" → junta com os outros números do mesmo grupo e modificadores
            const num = label.match(/^(.*\S)\s+(\d+)$/)
            if (num) {
                const id = group + "|" + m.join("+") + "|" + num[1]
                if (merged[id]) {
                    const it = merged[id]
                    const n = Number(num[2])
                    if (n < it.lo) { it.lo = n; it.loKey = key }
                    if (n > it.hi) { it.hi = n; it.hiKey = key }
                    it.label = num[1] + " " + it.lo + "–" + it.hi
                    it.keys = m.concat([it.loKey + " … " + it.hiKey])
                    continue
                }
                const it = { keys: m.concat([key]), label: label, lo: Number(num[2]), hi: Number(num[2]),
                             loKey: key, hiKey: key }
                merged[id] = it
                byName[group].items.push(it)
                continue
            }
            // mesmo texto e mesmos modificadores (ex.: Play e Pause): uma linha com as duas teclas
            const same = byName[group].items.find(it => it.label === label && it.mods === m.join("+") && !it.lo)
            if (same) { same.keys[same.keys.length - 1] += " / " + key; continue }
            byName[group].items.push({ keys: m.concat([key]), label: label, mods: m.join("+") })
        }
        // "Other" sempre por último
        return order.filter(n => n !== "Other").concat(order.filter(n => n === "Other")).map(n => byName[n])
    }

    readonly property var visibleGroups: {
        const f = filter.trim().toLowerCase()
        if (f === "") return groups
        return groups.map(g => ({
            name: g.name,
            items: g.items.filter(it => (g.name + " " + it.label + " " + it.keys.join(" ")).toLowerCase().includes(f))
        })).filter(g => g.items.length > 0)
    }

    // ---------- janela ----------
    PanelWindow {
        id: win
        visible: false
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-keybinds"
        WlrLayershell.keyboardFocus: win.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        HyprlandFocusGrab {
            windows: [win]
            active: win.visible
            onCleared: root.close()
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, root.shown ? 0.25 : 0)
            Behavior on color { ColorAnimation { duration: 140 } }
            MouseArea { anchors.fill: parent; onClicked: root.close() }
        }

        Rectangle {
            id: box
            readonly property int columns: Math.max(1, Math.min(3, Math.floor((win.width - 96) / 340)))
            width: columns * 340 + (columns - 1) * 12 + 32
            height: Math.min(win.height * 0.8, header.height + flow.implicitHeight + 48)
            anchors.centerIn: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1
            clip: true

            opacity: root.shown ? 1 : 0
            scale: root.shown ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            MouseArea { anchors.fill: parent }

            RowLayout {
                id: header
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                spacing: 12

                Text {
                    text: "Keyboard Shortcuts"
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize + 4
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    implicitWidth: 220
                    implicitHeight: 32
                    radius: Theme.buttonRadius
                    color: Theme.hover
                    TextInput {
                        id: search
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.fg
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize
                        selectionColor: Theme.accent
                        onTextChanged: root.filter = text
                        Keys.onEscapePressed: root.close()
                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: search.text === ""
                            text: "Filter…"
                            color: Theme.dim
                            font: search.font
                        }
                    }
                }
            }

            Flickable {
                anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom
                          leftMargin: 16; rightMargin: 16; topMargin: 12; bottomMargin: 16 }
                contentHeight: flow.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                // colunas: cada grupo vai para a coluna mais baixa no momento (estilo "masonry")
                Item {
                    id: flow
                    width: parent.width
                    implicitHeight: {
                        let h = 0
                        for (let i = 0; i < cards.count; i++) {
                            const c = cards.itemAt(i)
                            if (c) h = Math.max(h, c.y + c.height)
                        }
                        return h
                    }

                    function relayout() {
                        const cols = box.columns
                        const colW = (width - (cols - 1) * 12) / cols
                        const tops = new Array(cols).fill(0)
                        for (let i = 0; i < cards.count; i++) {
                            const c = cards.itemAt(i)
                            if (!c) continue
                            let k = 0
                            for (let j = 1; j < cols; j++) if (tops[j] < tops[k]) k = j
                            c.width = colW
                            c.x = k * (colW + 12)
                            c.y = tops[k]
                            tops[k] += c.height + 12
                        }
                        implicitHeightChanged()
                    }
                    onWidthChanged: relayout()

                    Repeater {
                        id: cards
                        model: root.visibleGroups
                        onItemAdded: Qt.callLater(flow.relayout)
                        onItemRemoved: Qt.callLater(flow.relayout)

                        Rectangle {
                            id: card
                            required property var modelData
                            height: col.implicitHeight + 20
                            radius: Theme.cardRadius
                            color: Theme.hover
                            onHeightChanged: Qt.callLater(flow.relayout)

                            ColumnLayout {
                                id: col
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                                spacing: 6

                                Text {
                                    text: card.modelData.name
                                    color: Theme.accent
                                    font.family: Theme.font
                                    font.pixelSize: Theme.fontSize
                                    font.weight: Font.DemiBold
                                    Layout.bottomMargin: 2
                                }

                                Repeater {
                                    model: card.modelData.items
                                    RowLayout {
                                        id: row
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Text {
                                            Layout.fillWidth: true
                                            text: row.modelData.label
                                            color: Theme.fg
                                            font.family: Theme.font
                                            font.pixelSize: Theme.fontSize - 1
                                            elide: Text.ElideRight
                                        }
                                        Row {
                                            spacing: 3
                                            Repeater {
                                                model: row.modelData.keys
                                                Rectangle {
                                                    required property var modelData
                                                    implicitWidth: kt.implicitWidth + 12
                                                    implicitHeight: kt.implicitHeight + 6
                                                    radius: 5
                                                    color: Theme.bg
                                                    border.color: Theme.border
                                                    border.width: 1
                                                    Text {
                                                        id: kt
                                                        anchors.centerIn: parent
                                                        text: parent.modelData
                                                        color: Theme.dim
                                                        font.family: Theme.monoFont
                                                        font.pixelSize: Theme.fontSize - 2
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.visibleGroups.length === 0
                text: root.groups.length === 0 ? "Reading shortcuts…" : "No shortcuts match"
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSize
            }
        }
    }
}
