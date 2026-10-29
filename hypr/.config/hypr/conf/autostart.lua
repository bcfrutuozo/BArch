-- Autostart
-- https://wiki.hypr.land/Configuring/Basics/Autostart/

hl.on("hyprland.start", function ()
    -- Screen lock (Quickshell, hyprlock as fallback) and idle
    hl.exec_cmd("~/.config/hypr/scripts/lock.sh")
    hl.exec_cmd("hypridle")

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

end)
