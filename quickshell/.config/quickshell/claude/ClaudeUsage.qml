// ClaudeUsage.qml — o uso do plano do Claude na barra, lido como o /usage do Claude Code lê (claude/usage.py,
// com o login do Claude Code em ~/.claude/.credentials.json; o token nunca sai do script). Na ilha: o ícone e a
// porcentagem da janela de cinco horas (amarelo a partir de 70 %, vermelho a partir de 90 %, ou quando qualquer
// limite chega lá). Clique: o painel com cada limite em barra (sessão, semana, a fatia do modelo do topo, "Fable"
// hoje) e quando zera, o plano (Max 5x), de onde vem o uso da semana (Claude Code, chats…), e o que os agentes
// desta máquina gastaram hoje e na semana (claude-cost.log), por fonte. Atualiza a cada 5 min e ao abrir.
// IPC "claude" (status em JSON, refresh), usado pelo "barch claude" e pelo barch-events (métricas claude.*).

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../theme"

Item {
    id: root

    readonly property Item island: {
        let p = root.parent
        while (p && p.radius === undefined) p = p.parent
        return p || root
    }

    property bool ipcEnabled: true          // falso nas cópias da barra em outras telas
    // "usage", never "data": Item.data is the default property (the children), a var named data would swallow them
    property var usage: ({ ok: false, error: "", plan: {}, limits: [], agents: {} })
    property bool loaded: false
    property real checkedAt: 0

    readonly property var session: usage.session || null
    readonly property var week: usage.week || null
    readonly property var scoped: usage.scoped || []
    readonly property int worst: Math.max(0, ...(usage.limits || []).map(l => l.percent || 0))
    readonly property int sessionPct: session ? Math.round(session.percent || 0) : 0
    readonly property color tint: !usage.ok ? Theme.dim
        : worst >= 90 ? Theme.red : worst >= 70 ? Theme.yellow
        : (popup.visible || barMouse.containsMouse ? Theme.accent : Theme.dim)

    function glyph(cp) { return String.fromCodePoint(cp) }
    function refresh(force) {
        if (checkProc.running) return
        checkProc.command = ["python3", "-I", Quickshell.shellDir + "/claude/usage.py"].concat(force ? ["--refresh"] : [])
        checkProc.running = true
    }
    function pct(l) { return l && l.percent !== null && l.percent !== undefined ? Math.round(l.percent) + " %" : "?" }
    function resetsIn(l) {
        if (!l || l.resets_in_s === null || l.resets_in_s === undefined) return ""
        const s = Math.max(0, l.resets_in_s - (Date.now() - root.checkedAt) / 1000)
        if (s < 3600) return "resets in " + Math.max(1, Math.round(s / 60)) + " min"
        if (s < 36 * 3600) return "resets in " + Math.floor(s / 3600) + " h " + Math.round((s % 3600) / 60) + " min"
        const d = new Date(Date.now() + s * 1000)
        return "resets " + d.toLocaleDateString(Qt.locale("en_US"), "ddd") + " " + d.toLocaleTimeString(Qt.locale("en_US"), "HH:mm")
    }
    function levelColor(p) { return p >= 90 ? Theme.red : p >= 70 ? Theme.yellow : Theme.accent }
    function usd(x) { return "US$ " + (x || 0).toFixed(2) }

    Process {
        id: checkProc
        stdout: StdioCollector {
            onStreamFinished: {
                let d
                try { d = JSON.parse(text) } catch (e) { return }
                root.usage = d
                root.loaded = true
                root.checkedAt = Date.now()
            }
        }
    }

    IpcHandler {
        target: "claude"
        enabled: root.ipcEnabled
        function status(): string {
            // the fields one by one: a wrapped var object may carry references JSON.stringify cannot follow
            const d = root.usage || {}
            return JSON.stringify({ ok: !!d.ok, error: d.error || "", at: d.at || 0, plan: d.plan || {}, token: d.token || {},
                                    limits: d.limits || [], session: d.session || null, week: d.week || null, scoped: d.scoped || [],
                                    breakdown: d.breakdown || [], extra_usage: d.extra_usage || null, agents: d.agents || {},
                                    loaded: root.loaded, checkedAt: root.checkedAt, running: checkProc.running })
        }
        function refresh(): string { root.refresh(true); return JSON.stringify({ ok: true, checkedAt: root.checkedAt }) }
    }

    Timer { interval: 8000; running: true; onTriggered: root.refresh(false) }
    Timer { interval: 5 * 60000; running: true; repeat: true; onTriggered: root.refresh(false) }

    // ---------- na barra ----------
    visible: loaded
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    RowLayout {
        id: barRow
        spacing: 4
        Text {
            id: iconText
            text: root.glyph(0xF06A9)                                 // robot
            color: root.tint
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Text {
            id: pctText
            visible: !!root.usage.ok
            text: root.sessionPct + "%"
            color: root.worst >= 70 ? root.tint : Theme.fg
            font.family: Theme.font
            font.pixelSize: Theme.fontSize
        }
    }

    MouseArea {
        id: barMouse
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { Popups.toggle(popup); if (Popups.isOpen(popup)) root.refresh(false) }
    }

    // ---------- painel ----------
    component Line: Text {
        Layout.fillWidth: true
        color: Theme.dim
        font.family: Theme.font
        font.pixelSize: Theme.fontSize - 3
        elide: Text.ElideRight
    }

    component Meter: ColumnLayout {
        id: m
        property var limit: null
        property string note: ""
        Layout.fillWidth: true
        spacing: 3
        RowLayout {
            Layout.fillWidth: true
            Text { text: m.limit ? m.limit.label : ""; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: true }
            Text { visible: m.note !== ""; text: m.note; color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3 }
            Item { Layout.fillWidth: true }
            Text { text: root.pct(m.limit); color: root.levelColor(m.limit ? m.limit.percent || 0 : 0); font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: true }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 6
            radius: 3
            color: Theme.track
            Rectangle {
                width: parent.width * Math.min(1, Math.max(0, (m.limit ? m.limit.percent || 0 : 0) / 100))
                height: parent.height
                radius: 3
                color: root.levelColor(m.limit ? m.limit.percent || 0 : 0)
                Behavior on width { NumberAnimation { duration: 300 } }
            }
        }
        Line { text: root.resetsIn(m.limit) }
    }

    component Btn: Rectangle {
        id: b
        property string label: ""
        signal clicked()
        implicitWidth: bt.implicitWidth + 20
        implicitHeight: 26
        radius: Theme.buttonRadius
        color: bm.containsMouse ? Theme.hover : "transparent"
        border.width: 1
        border.color: bm.containsMouse ? Theme.accent : Theme.border
        Text { id: bt; anchors.centerIn: parent; text: b.label; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2 }
        MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }

    PopupWindow {
        id: popup
        PanelAnim { win: popup }
        Connections {
            target: popup
            function onVisibleChanged() { popup.visible ? Popups.opened(popup) : Popups.closed(popup) }
        }
        visible: false
        anchor.item: root.island
        anchor.rect.x: root.island.width
        anchor.rect.y: root.island.height + Theme.popupGap
        anchor.rect.width: 1
        anchor.rect.height: 1
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Left
        implicitWidth: 380
        implicitHeight: panel.implicitHeight + 28
        color: "transparent"

        HyprlandFocusGrab {
            windows: [popup]
            active: popup.visible
            onCleared: Popups.hide(popup)
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                id: panel
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: root.glyph(0xF06A9); color: Theme.accent; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 2 }
                    Text { text: "Claude"; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: true }
                    Rectangle {
                        visible: !!(root.usage.plan && root.usage.plan.label)
                        implicitWidth: planText.implicitWidth + 12; implicitHeight: planText.implicitHeight + 4
                        radius: Theme.buttonRadius; color: Theme.hover
                        Text { id: planText; anchors.centerIn: parent; text: root.usage.plan ? root.usage.plan.label || "" : ""; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3 }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.checkedAt ? new Date(root.checkedAt).toLocaleTimeString(Qt.locale("en_US"), "HH:mm") : ""
                        color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                    }
                }

                // sem dados: por quê
                Line {
                    visible: !root.usage.ok
                    text: root.loaded ? (root.usage.error || "no answer") : "reading…"
                    color: Theme.yellow
                    wrapMode: Text.Wrap; elide: Text.ElideNone
                }

                // os limites do plano
                Meter { visible: !!root.session; limit: root.session; note: "5-hour window" }
                Meter { visible: !!root.week; limit: root.week; note: "all models" }
                Repeater {
                    model: root.scoped
                    Meter {
                        required property var modelData
                        limit: modelData
                        note: modelData.allowance_percent_of_weekly ? modelData.allowance_percent_of_weekly + " % of the week's allowance" : "this model"
                    }
                }
                Line {
                    visible: !!root.usage.ok && (root.usage.breakdown || []).length > 0
                    text: "This week: " + (root.usage.breakdown || []).filter(b => b.percent > 0).map(b => b.name + " " + Math.round(b.percent) + " %").join(" · ")
                }
                Line {
                    visible: !!(root.usage.extra_usage && root.usage.extra_usage.enabled)
                    text: root.usage.extra_usage ? "Extra usage: " + (root.usage.extra_usage.used || 0) + " " + root.usage.extra_usage.currency
                        + (root.usage.extra_usage.limit ? " of " + root.usage.extra_usage.limit : "") : ""
                }

                // os agentes desta máquina (claude-cost.log)
                ColumnLayout {
                    visible: !!root.usage.agents
                    Layout.fillWidth: true
                    spacing: 3
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "Agents on this machine"; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: root.usage.agents ? root.usd(root.usage.agents.today_usd) + " today · " + root.usd(root.usage.agents.week_usd) + " this week" : ""
                            color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                        }
                    }
                    Line {
                        readonly property var by: root.usage.agents ? root.usage.agents.by_source_today || {} : {}
                        text: Object.keys(by).length === 0 ? "nothing ran today"
                            : (root.usage.agents.runs_today + " run(s): " + Object.keys(by).sort((a, b) => by[b] - by[a]).map(k => k + " " + root.usd(by[k])).join(" · "))
                        wrapMode: Text.Wrap; elide: Text.ElideNone
                    }
                    Line {
                        visible: !!(root.usage.agents && root.usage.agents.last)
                        text: root.usage.agents && root.usage.agents.last ? "Last: " + root.usage.agents.last.source + " " + root.usd(root.usage.agents.last.usd)
                            + (root.usage.agents.last.note ? " · " + root.usage.agents.last.note : "") : ""
                    }
                }

                RowLayout {
                    spacing: 6
                    Btn { label: "Refresh"; onClicked: root.refresh(true) }
                    Btn { label: "History"; onClicked: { Popups.hide(popup); Quickshell.execDetached(["barch", "center", "history"]) } }
                    Btn { label: "Agents"; onClicked: { Popups.hide(popup); Quickshell.execDetached(["barch", "center", "agent"]) } }
                }
            }
        }
    }
}
