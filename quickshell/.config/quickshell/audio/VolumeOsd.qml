// VolumeOsd.qml — a pill on every monitor (wherever the eyes are) whenever the default output's volume or mute
// changes (media keys, the keyboard's roller, a voice command, the headset's own buttons), or
// the microphone is muted / unmuted. It watches PipeWire, not the keys, so it shows the value
// that was really set, whoever set it.
//
// Not shown: while the bar's own volume widget is in use (`quiet`, set by shell.qml: the
// eyes are already there), and for the jump a change of default device brings (`armed`).
// The microphone's *volume* is never watched: apps with automatic gain move it all the time.
// Click-through (empty mask) and above fullscreen windows (overlay layer), so it shows in games.

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "../theme"
import "../screens"

Scope {
    id: root

    property string position: "bottom"   // "bottom": `offset` of the screen's height above its bottom edge · "center": dead center
    property real offset: 0.12
    property int hold: 1400              // ms on screen after the last change
    property bool quiet: false

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    PwObjectTracker { objects: [root.sink, root.source].filter(o => o) }

    readonly property real level: sink && sink.audio ? sink.audio.volume : 0
    readonly property bool muted: sink && sink.audio ? sink.audio.muted : false
    readonly property bool micMuted: source && source.audio ? source.audio.muted : false

    // a new default device (or the bar starting) loads its volume a moment later: not a change
    property bool armed: false
    Timer { id: settle; interval: 1000; running: true; onTriggered: root.armed = true }
    onSinkChanged: { armed = false; settle.restart() }
    onSourceChanged: { armed = false; settle.restart() }

    onLevelChanged: flash("out")
    onMutedChanged: flash("out")
    onMicMutedChanged: flash("mic")

    property string kind: "out"          // what the pill is showing: "out" | "mic"
    property bool shown: false
    property bool mapped: false          // the surfaces exist: from the first change until the fade-out is over

    function flash(what) {
        if (!armed || quiet) return
        kind = what
        mapped = true
        shown = true
        hideTimer.restart()
    }

    Timer { id: hideTimer; interval: root.hold; onTriggered: { root.shown = false; unmap.restart() } }
    // the surfaces go away once the fade-out is over
    Timer { id: unmap; interval: 200; onTriggered: if (!root.shown) root.mapped = false }

    function glyph(cp) { return String.fromCodePoint(cp) }
    readonly property bool off: kind === "mic" ? micMuted : (muted || level === 0)
    readonly property string icon: kind === "mic" ? glyph(micMuted ? 0xF036D : 0xF036C)
        : off ? glyph(0xF0581)
        : level < 0.34 ? glyph(0xF057F)
        : level < 0.67 ? glyph(0xF0580) : glyph(0xF057E)

    // One window per monitor. The model is Screens.names (plain strings, settled), never
    // Quickshell.screens: see screens/Screens.qml for the crash that avoids.
    Variants {
        model: Screens.names

        PanelWindow {
            id: win
            required property string modelData   // monitor name

            screen: Screens.byName(modelData)
            visible: root.mapped
            color: "transparent"
            anchors.bottom: root.position === "bottom"
            margins.bottom: root.position === "bottom" && screen ? Math.round(screen.height * root.offset) : 0
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "qs-osd"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}

            implicitWidth: 320
            implicitHeight: 48

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: Theme.base
                border.color: Theme.surface
                border.width: 1
                opacity: root.shown ? 1 : 0
                scale: root.shown ? 1 : 0.96
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    spacing: 12

                    Text {
                        text: root.icon
                        color: root.off ? Theme.subtext : Theme.accent
                        font.family: Theme.font
                        font.pixelSize: 20
                        horizontalAlignment: Text.AlignHCenter
                        Layout.preferredWidth: 24
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    // output: the level · microphone: only its state, in words
                    Rectangle {
                        visible: root.kind === "out"
                        Layout.fillWidth: true
                        implicitHeight: 6
                        radius: 3
                        color: Theme.surface

                        Rectangle {
                            width: parent.width * Math.max(0, Math.min(1, root.level))
                            height: parent.height
                            radius: 3
                            color: root.muted ? Theme.overlay : Theme.accent
                            Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                    }
                    Text {
                        visible: root.kind === "out"
                        text: root.muted ? "muted" : Math.round(root.level * 100) + "%"
                        color: root.muted ? Theme.subtext : Theme.text
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize + 1
                        font.bold: !root.muted
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: 46
                    }
                    Text {
                        visible: root.kind === "mic"
                        text: root.micMuted ? "Microphone muted" : "Microphone on"
                        color: root.micMuted ? Theme.subtext : Theme.text
                        font.family: Theme.font
                        font.pixelSize: Theme.fontSize + 1
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }
}
