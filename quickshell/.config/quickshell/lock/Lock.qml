// Lock.qml — the lock screen controller: session lock (ext-session-lock-v1), PAM, theme and the
// extra data (weather, music, notifications while away). One instance per Quickshell process.
//
//   shell.qml    Lock {}                 the real lock: `qs -p ~/.config/quickshell/lock -n`
//   preview.qml  Lock { preview: true }  the same screen in a normal window, no session lock
//
// shell.qml and preview.qml are DIFFERENT Quickshell configs (different Shell IDs on purpose), so
// `qs -p .../lock kill`, `-n` and `pkill -f quickshell/lock` can never reach a preview and a real
// lock at the same time. On 2026-10-28 a preview shared the real lock's config, a `kill` meant for
// the preview took the real lock down and the session had to be hard-reset.
//
// Why a separate process from the bar: the lock is the only protection after autologin, so it
// must not fall with the bar; and importing Theme.qml would regenerate the app themes and apply
// the Hyprland borders, which only the bar may do. The palette comes from
// ~/.local/state/quickshell/theme.json, written by the bar on every theme change (a FileView
// follows it; without the file, Dracula).
//
// If this process dies while locked, Hyprland keeps the session locked (red screen) and
// misc:allow_session_lock_restore lets another lock take over: hypr/scripts/lock.sh runs
// hyprlock when `qs` exits with an error, and Super+Ctrl+Alt+L (works while locked) does the
// same by hand. Missing vs. hyprlock: a Caps Lock indicator (Quickshell has no keyboard state).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Services.Mpris

Scope {
    id: root

    property bool preview: false

    readonly property string home: Quickshell.env("HOME")
    readonly property string user: Quickshell.env("USER")
    readonly property int lockedAt: Math.floor(Date.now() / 1000)    // "notifications while away"
    readonly property string mainScreen: "HDMI-A-2"                    // primary.png; the others, secondary.png

    Component.onCompleted: {
        // The real lock must not reload itself when a file under lock/ is saved: a broken edit
        // would be applied to the screen that is protecting the session. Previews do reload.
        if (!root.preview) Quickshell.watchFiles = false
    }

    // ================= theme (the bar's theme.json) =================
    property var theme: ({
        flavor: "dracula", dark: true, font: "SF Pro Text", iconFont: "Symbols Nerd Font",
        colors: { crust: "#191a21", base: "#282a36", surface: "#44475a", overlay: "#6272a4", subtext: "#8b94c3",
                  text: "#f8f8f2", accent: "#bd93f9", green: "#50fa7b", yellow: "#f1fa8c", red: "#ff5555" }
    })
    FileView {
        path: root.home + "/.local/state/quickshell/theme.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const t = JSON.parse(text())
                if (t && t.colors && t.colors.text) root.theme = t
            } catch (e) { console.warn("lock: invalid theme.json:", e) }
        }
    }
    readonly property bool dark: theme.dark
    readonly property color fg: theme.colors.text
    readonly property color dim: Qt.alpha(fg, dark ? 0.65 : 0.72)
    readonly property color base: theme.colors.base
    readonly property color accent: theme.colors.accent
    readonly property color okColor: theme.colors.green
    readonly property color failColor: theme.colors.red
    readonly property color pill: Qt.alpha(base, dark ? 0.45 : 0.6)
    readonly property color outline: Qt.alpha(fg, 0.14)
    readonly property color shadow: dark ? Qt.rgba(0, 0, 0, 0.4) : Qt.rgba(0, 0, 0, 0.1)
    readonly property string font: "SF Pro Display"      // hyprlock used the Display face; the bar uses Text
    readonly property string iconFont: theme.iconFont

    // ================= password =================
    property string buffer: ""          // what was typed (shared between the monitors)
    property bool busy: false           // PAM is checking
    property int attempts: 0
    property string failText: ""
    property bool unlocking: false
    signal shake()

    PamContext {
        id: pam
        config: "hyprlock"              // /etc/pam.d/hyprlock: include login + gnome-keyring
        user: root.user
        onPamMessage: if (responseRequired) respond(root.buffer)
        onCompleted: result => {
            root.busy = false
            if (result === PamResult.Success) { root.unlock(); return }
            root.attempts++
            root.failText = result === PamResult.MaxTries ? "Too many attempts" : "Authentication failed"
            root.buffer = ""
            root.shake()
        }
        onError: error => {
            root.busy = false
            root.failText = "PAM: " + PamError.toString(error)
            root.buffer = ""
            root.shake()
        }
    }
    function submit() {
        if (root.busy || root.unlocking || root.buffer === "") return     // ignore empty input
        root.failText = ""
        root.busy = true
        if (!pam.start()) { root.busy = false; root.failText = "Could not start PAM" }
    }
    function unlock() {
        root.unlocking = true
        unlockTimer.start()             // fade-out time
    }
    Timer {
        id: unlockTimer
        interval: 350
        onTriggered: if (root.preview) Qt.quit(); else lockLoader.item.locked = false
    }

    // ================= extra data =================
    SystemClock { id: clock; precision: SystemClock.Minutes }
    readonly property date now: clock.date

    // current weather, written by the bar's weather widget: "<glyph>\t<temp>\t<description>"
    property string weatherGlyph: ""
    property string weatherText: ""
    FileView {
        path: (Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache") + "/quickshell/weather-now.txt"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const f = text().trim().split("\t")
            root.weatherGlyph = f.length >= 3 ? f[0] : ""
            root.weatherText = f.length >= 3 ? f[1] + "  " + f[2] : ""
        }
        onLoadFailed: { root.weatherGlyph = ""; root.weatherText = "" }
    }

    // music playing
    readonly property var player: Mpris.players.values.find(p => p.isPlaying) ?? null
    readonly property string mediaText: {
        if (!player) return ""
        const t = player.trackTitle || ""
        if (t === "") return ""
        return player.trackArtist ? player.trackArtist + " — " + t : t
    }

    // notifications that arrived since the screen locked (asked to the bar)
    property int awayCount: 0
    Process {
        id: awayProc
        // explicit -p: points at the bar even if this instance inherits QS_CONFIG_PATH
        command: ["qs", "-p", root.home + "/.config/quickshell/shell.qml", "ipc", "call", "notifs", "awayCount", String(root.lockedAt)]
        stdout: StdioCollector { onStreamFinished: root.awayCount = parseInt(text.replace(/\D/g, "")) || 0 }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: awayProc.running = true }

    // ================= session lock =================
    LazyLoader {
        id: lockLoader
        active: !root.preview
        WlSessionLock {
            id: lock
            locked: true
            // false again only after our own unlock (the compositor acknowledged it): leave
            onLockStateChanged: if (!locked) Qt.quit()

            WlSessionLockSurface {
                id: surface
                color: root.base
                // screen is assigned right after creation; "" until then (secondary wallpaper)
                LockScreen { anchors.fill: parent; ctl: root; screenName: surface.screen?.name ?? "" }
            }
        }
    }
    // Hyprland sends `locked` once every monitor has drawn a lock frame (5 s at most). If that
    // never happens (lock denied, no compositor support, nothing rendered) this process is not
    // protecting anything: leave with an error so lock.sh falls back to hyprlock.
    Timer {
        running: !root.preview
        interval: 15000
        onTriggered: if (!lockLoader.item || !lockLoader.item.locked) {
            console.error("lock: session lock not acquired after 15 s, exiting so hyprlock can take over")
            Qt.exit(1)
        }
    }

    // ================= preview =================
    LazyLoader {
        active: root.preview
        FloatingWindow {
            title: "BArch lock (preview)"
            implicitWidth: 1920; implicitHeight: 1080
            color: root.base
            LockScreen { anchors.fill: parent; ctl: root; screenName: root.mainScreen }
        }
    }
}
