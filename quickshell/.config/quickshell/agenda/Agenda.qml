// Agenda.qml — próximos compromissos embaixo do calendário do relógio.
//
// Lê o calendário local com o khal (o vdirsyncer baixa o iCloud a cada 15 min):
//   khal list --json … today <days>d   → uma lista JSON por dia, de hoje em diante
// Mostra os próximos eventos agrupados por dia e diz ao calendário quais dias têm
// compromisso (hasEvents), para ele marcar com um ponto.
// Sem khal ou sem eventos, a seção mostra só um aviso discreto.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../theme"

ColumnLayout {
    id: root

    property int days: 30            // quantos dias à frente
    property int maxEvents: 6        // quantos eventos listar
    property var events: []          // [{ day: Date, title, time, allDay, location, calendar }]
    property var marked: ({})        // "aaaa-mm-dd" → true
    property bool loaded: false
    property bool available: true

    spacing: 6

    function key(d) { return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate() }
    function hasEvents(d) { return marked[key(d)] === true }
    function refresh() { if (!proc.running) proc.running = true }

    function isTrue(v) { return v === true || v === "True" || v === "true" || v === "1" }

    function dayLabel(d) {
        const t = new Date(); t.setHours(0, 0, 0, 0)
        const diff = Math.round((d - t) / 86400000)
        if (diff === 0) return "Today"
        if (diff === 1) return "Tomorrow"
        return d.toLocaleDateString(Qt.locale("en_US"), diff < 7 ? "dddd" : "ddd, MMM d")
    }

    Process {
        id: proc
        command: ["sh", "-c", 'command -v khal >/dev/null || { echo MISSING; exit; }; '
            + 'khal list --json title --json start-time --json end-time --json all-day '
            + '--json calendar --json location today "$1"d 2>/dev/null', "sh", String(root.days)]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "MISSING") { root.available = false; root.loaded = true; return }
                root.available = true
                const start = new Date(); start.setHours(0, 0, 0, 0)
                const evs = [], marks = {}
                const lines = text.split("\n").filter(l => l.trim().startsWith("["))
                for (let i = 0; i < lines.length; i++) {
                    let list = []
                    try { list = JSON.parse(lines[i]) } catch (e) { continue }
                    const day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i)
                    if (list.length > 0) marks[root.key(day)] = true
                    for (const e of list) {
                        const allDay = root.isTrue(e["all-day"])
                        const st = (e["start-time"] || "").trim(), en = (e["end-time"] || "").trim()
                        evs.push({
                            day: day,
                            title: e.title || "(no title)",
                            time: allDay || st === "" ? "All day" : (en !== "" ? st + " – " + en : st),
                            allDay: allDay,
                            location: e.location || "",
                            calendar: e.calendar || ""
                        })
                    }
                }
                root.events = evs
                root.marked = marks
                root.loaded = true
            }
        }
    }

    // ---------- lista ----------
    readonly property var shownEvents: events.slice(0, maxEvents)

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 2
        implicitHeight: 1
        color: Theme.surface
    }

    Text {
        visible: root.loaded && (!root.available || root.events.length === 0)
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: !root.available ? "Install khal to see your events" : "No events in the next " + root.days + " days"
        color: Theme.subtext
        font.family: Theme.font
        font.pixelSize: Theme.fontSize - 2
    }

    Repeater {
        model: root.shownEvents

        ColumnLayout {
            id: ev
            required property var modelData
            required property int index
            readonly property bool newDay: index === 0
                || root.shownEvents[index - 1].day.getTime() !== modelData.day.getTime()
            Layout.fillWidth: true
            spacing: 2

            Text {
                visible: ev.newDay
                Layout.topMargin: ev.index === 0 ? 0 : 4
                text: root.dayLabel(ev.modelData.day)
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 2
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 5
                    implicitWidth: 3
                    implicitHeight: ev.modelData.location !== "" ? 26 : 12
                    radius: 2
                    color: ev.modelData.allDay ? Theme.subtext : Theme.accent
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Text {
                            text: ev.modelData.time
                            color: Theme.subtext
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                        }
                        Text {
                            Layout.fillWidth: true
                            text: ev.modelData.title
                            color: Theme.text
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 1
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        visible: ev.modelData.location !== ""
                        Layout.fillWidth: true
                        text: ev.modelData.location
                        color: Theme.subtext
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize - 3
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    Text {
        visible: root.events.length > root.maxEvents
        text: "+" + (root.events.length - root.maxEvents) + " more"
        color: Theme.subtext
        font.family: Theme.font
        font.pixelSize: Theme.fontSize - 3
    }
}
