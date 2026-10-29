// Lock.qml — the lock screen controller: session lock (ext-session-lock-v1), PAM, theme and the
// extra data (weather, music, notifications while away). One instance per Quickshell process.
//
//   shell.qml    Lock {}                 the real lock, resident: `qs -p ~/.config/quickshell/lock -n`
//   preview.qml  Lock { preview: true }  the same screen in a normal window, no session lock
//
// The real lock is a RESIDENT process: hypr/scripts/lock.sh starts it at login and keeps it
// alive; it sits idle (no surfaces, nothing drawn) until `ipc call lock lock`, which is what
// `lock.sh` sends for Super+L, hypridle and the login lock. Locking then only creates the two
// lock surfaces: no Quickshell startup, PAM, Mpris or QML loading in the way, so the screen is
// up in the time it takes to draw one frame per monitor. After the unlock it goes idle again
// (it does not exit). Quickshell.watchFiles is off here: an edit under lock/ applies at the next
// `lock.sh --relaunch`, which is safe to run while unlocked.
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
// misc:allow_session_lock_restore lets a new lock take over: lock.sh starts this config again
// whenever `qs` exits with an error and locks it again if the session is still locked;
// Super+Ctrl+Alt+L (works while locked) forces that by hand. There is no other locker (hyprlock
// was retired on 2026-10-29).
// Known gap: no Caps Lock indicator (Quickshell has no keyboard state).

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
    property int lockedAt: Math.floor(Date.now() / 1000)            // "notifications while away"
    readonly property string mainScreen: "HDMI-A-2"                    // primary-lock.png; the others, secondary-lock.png

    Component.onCompleted: {
        // The real lock must not reload itself when a file under lock/ is saved: a broken edit
        // would be applied to the screen that is protecting the session. Previews do reload.
        if (!root.preview) Quickshell.watchFiles = false
        else awayFirst.start()
        // BARCH_LOCK_RELOCK=1: lock.sh --daemon started this instance in place of one that died
        // while the session was locked. Lock right away, without waiting for its `ipc call`
        // (the daemon still sends one, which is then a no-op): every ms is red screen.
        if (!root.preview && Quickshell.env("BARCH_LOCK_RELOCK") === "1") Qt.callLater(root.lock)
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
    readonly property string font: "SF Pro Display"      // the Display face; the bar uses Text
    readonly property string iconFont: theme.iconFont

    // ================= password =================
    property string buffer: ""          // what was typed (shared between the monitors)
    property bool busy: false           // PAM is checking
    property int attempts: 0
    property string failText: ""
    property bool unlocking: false
    signal shake()

    // /etc/pam.d/barch-lock (system/files: the login stack + gnome-keyring). Until that file is
    // installed the plain login stack is used, so the screen can always be unlocked.
    property string pamConfig: "login"
    FileView { path: "/etc/pam.d/barch-lock"; printErrors: false; onLoaded: root.pamConfig = "barch-lock" }
    PamContext {
        id: pam
        config: root.pamConfig
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
        onTriggered: {
            if (root.preview) { Qt.quit(); return }
            lockLoader.item.locked = false   // the compositor confirms through secureStateChanged -> checkLock
            unlockFallback.start()
        }
    }
    // if the compositor never reports the unlock, go idle anyway (the surfaces are gone either way)
    Timer { id: unlockFallback; interval: 2000; onTriggered: if (root.unlocking) root.finishUnlock() }

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

    // notifications that arrived since the screen locked (asked to the bar, only while locked).
    // The first question waits 1.5 s: spawning a `qs ipc` process while the surfaces are coming
    // up competed with them for the CPU.
    property int awayCount: 0
    Process {
        id: awayProc
        // explicit -p: points at the bar even if this instance inherits QS_CONFIG_PATH
        command: ["qs", "-p", root.home + "/.config/quickshell/shell.qml", "ipc", "call", "notifs", "awayCount", String(root.lockedAt)]
        stdout: StdioCollector { onStreamFinished: root.awayCount = parseInt(text.replace(/\D/g, "")) || 0 }
    }
    Timer { id: awayFirst; interval: 1500; onTriggered: awayProc.running = true }
    Timer { interval: 5000; running: root.wantLocked || root.preview; repeat: true; onTriggered: awayProc.running = true }

    // ================= session lock =================
    property bool wantLocked: false     // lock() was asked and the unlock has not finished
    property bool relockPending: false  // lock() arrived during the unlock fade: lock again after it

    // $XDG_RUNTIME_DIR/barch-lock/locked exists while this process wants the session locked. If it
    // dies (or is relaunched) in that state, lock.sh --daemon finds the marker and locks the new
    // instance at once. Hyprland's own report (solitaryBlockedBy LOCK) is not reliable right after
    // the lock client died, which left the red screen up until a later retry (2026-10-28).
    readonly property string lockedMarker: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/barch-lock/locked"
    Process { id: markerSet; command: ["sh", "-c", 'mkdir -p "${1%/*}" && touch "$1"', "sh", root.lockedMarker] }
    Process { id: markerClear; command: ["rm", "-f", root.lockedMarker] }

    LazyLoader {
        id: lockLoader
        active: !root.preview
        WlSessionLock {
            id: lock
            locked: false                   // idle until root.lock(); the surfaces exist only while locked
            // Both signals go through checkLock on the next event loop turn: Quickshell 0.3.2
            // never emits lockStateChanged on unlock (fixed upstream), and when
            // secureStateChanged fires `locked` still reads true for a moment.
            onSecureStateChanged: Qt.callLater(root.checkLock)
            onLockStateChanged: Qt.callLater(root.checkLock)

            WlSessionLockSurface {
                id: surface
                color: root.base
                // screen is assigned right after creation; "" until then (secondary wallpaper)
                LockScreen { anchors.fill: parent; ctl: root; screenName: surface.screen?.name ?? "" }
            }
        }
    }
    // `ipc call lock lock`: lock the session (no-op when already locked)
    function lock() {
        if (root.preview) return
        const l = lockLoader.item
        if (!l) { console.error("lock: no session lock object"); return }
        if (root.unlocking) { root.relockPending = true; return }
        if (root.wantLocked && l.locked) return
        root.lockedAt = Math.floor(Date.now() / 1000)
        root.buffer = ""; root.failText = ""; root.attempts = 0; root.busy = false
        root.awayCount = 0
        root.wantLocked = true
        markerSet.running = true
        l.locked = true
        acquireTimer.restart()
        awayFirst.restart()
    }
    function finishUnlock() {
        root.unlocking = false
        root.wantLocked = false
        markerClear.running = true
        root.buffer = ""
        if (root.relockPending) { root.relockPending = false; root.lock() }
    }
    function checkLock() {
        const l = lockLoader.item
        if (!l || l.locked || l.secure) return         // still locking, or locked
        if (root.unlocking) { root.finishUnlock(); return }   // our own unlock: done, stay resident
        if (!root.wantLocked) return                    // idle
        console.error("lock: the compositor ended the session lock before the unlock; exiting so lock.sh starts a new one")
        Qt.exit(1)
    }
    // Hyprland sends `locked` (-> secure) once every monitor has drawn a lock frame (5 s at
    // most). If that never happens (lock denied, no compositor support, nothing rendered) this
    // process is not protecting anything: leave with an error so lock.sh starts a new one.
    Timer {
        id: acquireTimer
        interval: 15000
        onTriggered: if (root.wantLocked && !root.unlocking && (!lockLoader.item || !lockLoader.item.secure)) {
            console.error("lock: session lock not acquired after 15 s, exiting so lock.sh starts a new one")
            Qt.exit(1)
        }
    }

    // `qs -p ~/.config/quickshell/lock ipc call lock lock`   -> lock now, answers the state
    // `qs -p ~/.config/quickshell/lock ipc call lock state`  -> {"locked":..,"secure":..,"unlocking":..}
    // lock.sh uses `lock` for every lock request and `state` to see whether an instance answers.
    IpcHandler {
        target: "lock"
        function lock(): string { root.lock(); return state() }
        function state(): string {
            const l = lockLoader.item
            return JSON.stringify({ locked: !!(l && l.locked), secure: !!(l && l.secure), wanted: root.wantLocked,
                                    unlocking: root.unlocking, preview: root.preview, pam: root.pamConfig })
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
