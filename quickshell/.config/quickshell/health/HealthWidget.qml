// HealthWidget.qml — saúde do sistema na barra. Só aparece quando há algo para ver:
//   - arquivos .pacnew/.pacsave (configs novas que o pacman deixou de lado) → Review (pacdiff no nvim)
//   - serviços com falha → Details (systemctl status) / Reset
//   - disco pediu senha no boot (o TPM não destravou) → comando de reenroll pronto (Copy / Run)
//   - limpeza mensal (órfãos, cache, journal) → Clean Up (passo a passo, pergunta antes)
// O aviso do TPM também chega como notificação, uma vez por boot.
// Depende de health-check.sh e clean.sh (nesta pasta), pacman-contrib (pacdiff, paccache), jq e foot.

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

    // ---------- configuração ----------
    property string luksDevice: "/dev/nvme0n1p2"
    property string tpmPcrs: "7"
    property int cleanupDays: 30
    property var terminal: ["foot", "--title", "System Health", "-e"]

    // ---------- estado ----------
    property var pacnew: []
    property var failedSys: []
    property var failedUsr: []
    property string tpm: "ok"
    property var clean: ({ orphans: 0, cache: "?", journal: "?" })
    property real lastCleanup: 0
    property bool loaded: false

    readonly property string reenroll: "sudo systemd-cryptenroll " + luksDevice
        + " --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=" + tpmPcrs
    readonly property bool cleanupDue: loaded && (Date.now() - lastCleanup) > cleanupDays * 86400000
    readonly property int issues: pacnew.length + failedSys.length + failedUsr.length + (tpm === "failed" ? 1 : 0)
    readonly property bool shown: issues > 0 || cleanupDue

    function glyph(cp) { return String.fromCodePoint(cp) }
    function refresh() { if (!checkProc.running) checkProc.running = true }
    function run(cmd) {
        Popups.hide(popup)
        runProc.command = root.terminal.concat(["bash", "-c", cmd + '; echo; read -rsn1 -p "Press any key to close…"'])
        runProc.running = true
    }

    Process {
        id: checkProc
        command: ["bash", Quickshell.shellDir + "/health/health-check.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                let d
                try { d = JSON.parse(text) } catch (e) { return }
                root.pacnew = d.pacnew || []
                root.failedSys = d.failed.system || []
                root.failedUsr = d.failed.user || []
                root.tpm = d.tpm
                root.clean = d.clean
                root.loaded = true
                if (root.tpm === "failed") tpmNotice.running = true
            }
        }
    }

    // última limpeza
    FileView {
        path: Quickshell.env("HOME") + "/.local/state/quickshell/last-cleanup"
        onLoaded: root.lastCleanup = Number(text().trim()) * 1000 || 0
        // nunca limpou: começa a contar de hoje
        onLoadFailed: {
            root.lastCleanup = Date.now()
            Theme.writeFile(Quickshell.env("HOME") + "/.local/state/quickshell/last-cleanup", String(Math.floor(Date.now() / 1000)))
        }
        watchChanges: true
        onFileChanged: reload()
    }

    // notificação do TPM: uma vez por boot (guarda o boot_id)
    Process {
        id: tpmNotice
        command: ["bash", "-c", `
            f="\${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/tpm-notified"
            id=$(cat /proc/sys/kernel/random/boot_id)
            [[ "$(cat "$f" 2>/dev/null)" == "$id" ]] && exit 0
            mkdir -p "$(dirname "$f")"; echo "$id" > "$f"
            notify-send -a "System Health" -u critical -i dialog-password \\
              "Disk asked for the password" "The TPM didn't unlock the disk this boot (usually after a firmware or Secure Boot update). Re-enroll it from the health icon in the bar."`]
    }

    Process { id: runProc; onExited: root.refresh() }

    Timer { interval: 45000; running: true; onTriggered: root.refresh() }   // depois do boot assentar
    Timer { interval: 30 * 60000; running: true; repeat: true; onTriggered: root.refresh() }

    // ---------- na barra ----------
    visible: shown
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    Row {
        id: barRow
        spacing: 4
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.tpm === "failed" ? root.glyph(0xF0BC5)          // shield_key_outline
                : root.issues > 0 ? root.glyph(0xF002A)                 // alert_outline
                : root.glyph(0xF00E2)                                   // broom
            color: root.tpm === "failed" ? Theme.red
                 : root.issues > 0 ? Theme.yellow
                 : (popup.visible || barMouse.containsMouse ? Theme.accent : Theme.dim)
            font.family: Theme.iconFont
            font.pixelSize: Theme.fontSize + 2
        }
        Text {
            visible: root.issues > 1
            anchors.verticalCenter: parent.verticalCenter
            text: root.issues
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

    // ---------- painel ----------
    component Section: ColumnLayout {
        id: sec
        property string title: ""
        property int icon: 0
        property color tint: Theme.accent
        default property alias content: body.data
        Layout.fillWidth: true
        spacing: 4
        RowLayout {
            spacing: 8
            Text { text: root.glyph(sec.icon); color: sec.tint; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 2 }
            Text { text: sec.title; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: true }
        }
        ColumnLayout { id: body; Layout.fillWidth: true; Layout.leftMargin: 26; spacing: 3 }
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

    component Line: Text {
        Layout.fillWidth: true
        color: Theme.dim
        font.family: Theme.font
        font.pixelSize: Theme.fontSize - 3
        elide: Text.ElideMiddle
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
        implicitWidth: 420
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

                Text {
                    text: "System Health"
                    color: Theme.fg
                    font.family: Theme.font
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                // --- TPM ---
                Section {
                    visible: root.tpm === "failed"
                    title: "Disk Asked for the Password"
                    icon: 0xF0BC5
                    tint: Theme.red
                    Line {
                        text: "The TPM didn't unlock the disk this boot (usually after a firmware, dbx or Secure Boot change). Re-enroll it so the next boot unlocks by itself:"
                        wrapMode: Text.Wrap
                        elide: Text.ElideNone
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: cmdText.implicitHeight + 12
                        radius: 6
                        color: Theme.hover
                        Text {
                            id: cmdText
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 8 }
                            text: root.reenroll
                            color: Theme.fg
                            font.family: Theme.monoFont
                            font.pixelSize: Theme.fontSize - 3
                            wrapMode: Text.WrapAnywhere
                        }
                    }
                    RowLayout {
                        spacing: 6
                        Btn { label: "Copy"; onClicked: Quickshell.execDetached(["wl-copy", root.reenroll]) }
                        Btn { label: "Run in Terminal"; onClicked: root.run(root.reenroll) }
                    }
                }

                // --- .pacnew ---
                Section {
                    visible: root.pacnew.length > 0
                    title: root.pacnew.length === 1 ? "1 Config File to Review" : root.pacnew.length + " Config Files to Review"
                    icon: 0xF08AA
                    tint: Theme.yellow
                    Repeater { model: root.pacnew.slice(0, 6); Line { required property var modelData; text: modelData } }
                    Line { visible: root.pacnew.length > 6; text: "+" + (root.pacnew.length - 6) + " more" }
                    RowLayout {
                        spacing: 6
                        Btn { label: "Review"; onClicked: root.run('sudo DIFFPROG="nvim -d" pacdiff') }
                    }
                }

                // --- serviços com falha ---
                Section {
                    visible: root.failedSys.length + root.failedUsr.length > 0
                    title: "Failed Services"
                    icon: 0xF002A
                    tint: Theme.yellow
                    Repeater { model: root.failedSys; Line { required property var modelData; text: modelData } }
                    Repeater { model: root.failedUsr; Line { required property var modelData; text: modelData + "  (user)" } }
                    RowLayout {
                        spacing: 6
                        Btn {
                            label: "Details"
                            onClicked: root.run(root.failedSys.map(u => "systemctl status --no-pager " + u).concat(
                                root.failedUsr.map(u => "systemctl --user status --no-pager " + u)).join("; echo; "))
                        }
                        Btn {
                            label: "Reset"
                            onClicked: root.run("sudo systemctl reset-failed; systemctl --user reset-failed; echo Cleared.")
                        }
                    }
                }

                // --- limpeza ---
                Section {
                    title: root.cleanupDue ? "Monthly Cleanup Available" : "Cleanup"
                    icon: 0xF00E2
                    tint: root.cleanupDue ? Theme.accent : Theme.dim
                    Line {
                        text: root.clean.orphans + " orphan packages   ·   package cache " + root.clean.cache
                            + "   ·   journal " + root.clean.journal
                    }
                    Line {
                        visible: root.lastCleanup > 0
                        text: "Last cleanup: " + new Date(root.lastCleanup).toLocaleDateString(Qt.locale("en_US"), "MMM d, yyyy")
                    }
                    RowLayout {
                        spacing: 6
                        Btn { label: "Clean Up"; onClicked: root.run("bash " + Quickshell.shellDir + "/health/clean.sh") }
                    }
                }

                // --- tudo certo ---
                RowLayout {
                    visible: root.issues === 0
                    spacing: 8
                    Text { text: root.glyph(0xF05E1); color: Theme.green; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize + 2 }
                    Text { text: "No problems found"; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1 }
                }
            }
        }
    }
}
