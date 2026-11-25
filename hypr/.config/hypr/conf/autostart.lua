-- Autostart
-- https://wiki.hypr.land/Configuring/Basics/Autostart/

hl.on("hyprland.start", function ()
    -- Screen lock (Quickshell, resident; lock.sh starts it, locks, and restarts it if it dies) and idle.
    -- Both stay under session.slice, out of systemd-oomd's reach (it watches app.slice only): lock.sh
    -- in Hyprland's own unit, hypridle in session-graphical.slice ("-s s"), because its lock_cmd runs
    -- lock.sh, which restarts the resident lock inside whatever unit called it
    hl.exec_cmd("~/.config/hypr/scripts/lock.sh")
    hl.exec_cmd("uwsm app -s s -- hypridle")

    -- Automatic light/dark mode
    hl.exec_cmd("theme-auto")

    -- Clipboard
    hl.exec_cmd("uwsm app -- wl-paste --type text --watch cliphist store")
    hl.exec_cmd("uwsm app -- wl-paste --type image --watch cliphist store")
    hl.exec_cmd("uwsm app -- wl-clip-persist --clipboard regular")

    -- Shell (Quickshell)
    hl.exec_cmd("uwsm app -- qs")

    -- X11 apps that reads Xft DPI
    hl.exec_cmd('echo "Xft.dpi: 192" | xrdb -merge')

    -- Alienware (HDMI-A-2) como monitor primário no XWayland/Wine (senão o de retrato vira o primário)
    hl.exec_cmd("~/.config/hypr/scripts/xwayland-primary.sh")

end)
