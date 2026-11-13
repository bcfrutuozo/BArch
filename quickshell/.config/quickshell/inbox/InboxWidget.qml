// InboxWidget.qml — what waits for a decision of Bruno's, in one place (inbox.sh, every 2 min and on open):
// the music pipeline's review queue (and the ones a single button settles), the library albums the
// MusicBrainz sweep could not tie, the video dub jobs in review, the book requests pending a pick, the
// failure logs of the last day, the health check's issues and the agent reports that ask for attention.
// In the island: a tray icon with the total, only while there is something; the panel lists each source
// with its count and an Open button to the right app or Center page. Each source is read with a timeout,
// so the NAS asleep only hides its lines. IPC "inbox" (status in JSON, refresh), used by `barch inbox`.

pragma ComponentBehavior: Bound
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

    property bool ipcEnabled: true          // false in the bar's copies on other screens
    property var inbox: ({ at: 0, total: 0, items: [], errors: [] })
    property bool loaded: false
    property real checkedAt: 0

    readonly property int total: inbox.total || 0
    readonly property var items: inbox.items || []
    readonly property color tint: popup.visible || barMouse.containsMouse ? Theme.accent : total > 0 ? Theme.fg : Theme.dim

    function glyph(cp) { return String.fromCodePoint(cp) }
    property bool again: false              // a refresh asked for while one was running
    function refresh() {
        if (checkProc.running) { again = true; return }
        checkProc.running = true
    }
    // failures and agent reports carry a `dismiss` command: seen, stop counting them (nothing is deleted)
    function dismiss(cmd) {
        if (dismissProc.running) return
        dismissProc.command = cmd
        dismissProc.running = true
    }
    Process { id: dismissProc; onExited: root.refresh() }
    function open(cmd) {
        Popups.hide(popup)
        Quickshell.execDetached(cmd)
    }

    Process {
        id: checkProc
        command: ["bash", Quickshell.shellDir + "/inbox/inbox.sh"]
        onExited: if (root.again) { root.again = false; root.refresh() }
        stdout: StdioCollector {
            onStreamFinished: {
                let d
                try { d = JSON.parse(text) } catch (e) { return }
                root.inbox = d
                root.loaded = true
                root.checkedAt = Date.now()
            }
        }
    }

    IpcHandler {
        target: "inbox"
        enabled: root.ipcEnabled
        function status(): string {
            const d = root.inbox || {}
            return JSON.stringify({ ok: true, at: d.at || 0, total: d.total || 0, items: d.items || [], errors: d.errors || [],
                                    loaded: root.loaded, checkedAt: root.checkedAt, running: checkProc.running })
        }
        function refresh(): string { root.refresh(); return JSON.stringify({ ok: true, checkedAt: root.checkedAt }) }
    }

    Timer { interval: 20000; running: true; onTriggered: root.refresh() }
    Timer { interval: 2 * 60000; running: true; repeat: true; onTriggered: root.refresh() }

    // ---------- in the bar ----------
    visible: loaded && total > 0
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    RowLayout {
        id: barRow
        spacing: 4
        Text {
            text: root.glyph(0xF02FB)                                 // inbox-arrow-down
            color: root.tint
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Text {
            text: root.total
            color: Theme.fg
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
        onClicked: { Popups.toggle(popup); if (Popups.isOpen(popup)) root.refresh() }
    }

    // ---------- panel ----------
    component Line: Text {
        Layout.fillWidth: true
        color: Theme.dim
        font.family: Theme.font
        font.pixelSize: Theme.fontSize - 3
        wrapMode: Text.Wrap
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
        implicitWidth: 400
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
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: root.glyph(0xF02FB); color: Theme.accent; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 2 }
                    Text { text: "Waiting for you"; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.checkedAt ? new Date(root.checkedAt).toLocaleTimeString(Qt.locale("en_US"), "HH:mm") : ""
                        color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                    }
                }

                Line { visible: root.items.length === 0; text: root.loaded ? "Nothing waits for a decision." : "reading…" }

                Repeater {
                    model: root.items
                    RowLayout {
                        id: row
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 10
                        Text {
                            text: row.modelData.count
                            color: Theme.accent; font.family: Theme.font; font.pixelSize: Theme.fontSize + 2; font.bold: true
                            Layout.preferredWidth: 36; horizontalAlignment: Text.AlignRight
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { text: row.modelData.label; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: true }
                            Line { text: row.modelData.text }
                        }
                        Btn { visible: !!row.modelData.dismiss; label: "Dismiss"; onClicked: root.dismiss(row.modelData.dismiss) }
                        Btn { label: "Open"; onClicked: root.open(row.modelData.cmd) }
                    }
                }

                Line {
                    visible: (root.inbox.errors || []).length > 0
                    color: Theme.yellow
                    text: "Not reachable: " + (root.inbox.errors || []).join(" · ")
                }

                RowLayout {
                    spacing: 6
                    Btn { label: "Refresh"; onClicked: root.refresh() }
                    Btn { label: "System Center"; onClicked: root.open(["barch", "center"]) }
                }
            }
        }
    }
}
