// shell.qml — the real lock screen, one RESIDENT Quickshell process per session:
//
//   ~/.config/hypr/scripts/lock.sh            lock now (hypridle, Super+L, autostart); starts and
//                                             supervises the process if it is not running
//   qs -p ~/.config/quickshell/lock ipc call lock lock     what lock.sh sends to it
//   qs -p ~/.config/quickshell/lock -n        the process itself (-n: never two); idle until asked
//
// NEVER kill or (re)start this config from a script or an agent session: it may be the lock that
// is protecting the session right now. Test with preview.sh / preview.qml, which have their own
// Shell ID. Everything lives in Lock.qml.

import Quickshell

ShellRoot {
    Lock {}
}
