// preview.qml — the lock screen in a normal 1920x1080 window, with real PAM (the right password
// only closes the window). A config of its own, so it never collides with the real lock:
//
//   qs -p ~/.config/quickshell/lock/preview.qml      (or lock/preview.sh, which also screenshots)

import Quickshell

ShellRoot {
    Lock { preview: true }
}
