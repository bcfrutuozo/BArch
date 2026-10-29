// shell.qml — the real lock screen (replaces hyprlock), one Quickshell process per lock:
//
//   ~/.config/hypr/scripts/lock.sh            what hypridle and the autostart run (hyprlock fallback)
//   qs -p ~/.config/quickshell/lock -n        the same by hand (-n: never two)
//
// NEVER kill or (re)start this config from a script or an agent session: it may be the lock that
// is protecting the session right now. Test with preview.sh / preview.qml, which have their own
// Shell ID. Everything lives in Lock.qml.

import Quickshell

ShellRoot {
    Lock {}
}
