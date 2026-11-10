-- Atalhos
-- https://wiki.hypr.land/Configuring/Basics/Binds/
--
-- A "description" de cada atalho aparece na folha de atalhos (Super + /), no formato
-- "Grupo|Descrição". Atalho sem description aparece em "Other". Números no fim
-- ("Go to Workspace 1", "… 2"…) viram uma linha só na folha.

-- Programas
local terminal    = "foot"
local fileManager = "thunar"
--local menu        = "hyprlauncher"

local mainMod = "SUPER"

-- Apps e janelas
hl.bind(mainMod .. " + T", hl.dsp.exec_cmd(terminal), { description = "Apps|Terminal" })
hl.bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd(terminal .. " -T Unraid ssh nas"), { description = "Apps|Unraid Terminal (ssh nas)" })
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), { description = "Apps|File Manager" })
hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd("qs ipc call launcher toggle"), { release = true, description = "Apps|Launcher" })
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("qs ipc call launcher openWith 'c '"), { description = "Apps|Clipboard History" })
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("qs ipc call notes toggle"), { description = "Apps|Quick Notes" })
hl.bind(mainMod .. " + period", hl.dsp.exec_cmd("qs ipc call launcher openWith ': '"), { description = "Apps|Emoji" })
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd("qs ipc call launcher openWith 'a '"), { description = "Apps|Ask Claude" })

local closeWindowBind = hl.bind(mainMod .. " + C", hl.dsp.window.close(), { description = "Windows|Close" })
-- closeWindowBind:set_enabled(false)
hl.bind(mainMod .. " + F", hl.dsp.window.float({ action = "toggle" }), { description = "Windows|Float / Tile" })
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }), { description = "Windows|Fullscreen" })
-- Ocupa a área toda, mas a barra, as bordas e os gaps ficam
hl.bind(mainMod .. " + ALT + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }), { description = "Windows|Maximize" })
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo(), { description = "Windows|Pseudotile" })
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"), { description = "Windows|Toggle Split" })    -- só dwindle
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("qs ipc call minimize window"), { description = "Windows|Minimize" })
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exec_cmd("qs ipc call minimize restoreLast"), { description = "Windows|Restore Last Minimized" })
hl.bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd("qs ipc call pin toggle"), { description = "Windows|Always on Top" })
-- Mata na hora (SIGKILL): o cursor vira uma mira e o clique escolhe a janela; Esc cancela.
-- Super+C só pede para fechar, o que um app travado ignora
hl.bind(mainMod .. " + CTRL + ALT + Delete", hl.dsp.exec_cmd("hyprctl kill"), { description = "Windows|Kill (click a window)" })

-- Grupos: janelas empilhadas com abas. Super+G cria o grupo com a janela em foco (ou desfaz o
-- grupo dela); as janelas abertas depois e as arrastadas para a barra de abas entram nele
hl.bind(mainMod .. " + G", hl.dsp.group.toggle(), { description = "Groups|Group / Ungroup" })
hl.bind(mainMod .. " + ALT + Tab", hl.dsp.group.next(), { description = "Groups|Next Tab" })
hl.bind(mainMod .. " + ALT + SHIFT + Tab", hl.dsp.group.prev(), { description = "Groups|Previous Tab" })
for i = 1, 9 do
    hl.bind(mainMod .. " + ALT + " .. i, hl.dsp.group.active({ index = i }), { description = "Groups|Go to Tab " .. i })
end

-- Every wheel step on a mod+scroll bind is the bind's: with the default delay (300 ms) Hyprland
-- hands the steps that follow one that fired straight to the window, so a fast Super+Ctrl+scroll
-- zoomed the screen once and then the browser (Ctrl+scroll), and Super+scroll leaked too.
hl.config({ binds = { scroll_event_delay = 0 } })

-- Zoom em volta do cursor (cursor:zoom_factor), passos de 25 %
hl.bind(mainMod .. " + CTRL + mouse_up", hl.dsp.exec_cmd("~/.config/hypr/scripts/zoom.sh in"), { description = "Zoom|Zoom In" })
hl.bind(mainMod .. " + CTRL + mouse_down", hl.dsp.exec_cmd("~/.config/hypr/scripts/zoom.sh out"), { description = "Zoom|Zoom Out" })
hl.bind(mainMod .. " + CTRL + 0", hl.dsp.exec_cmd("~/.config/hypr/scripts/zoom.sh reset"), { description = "Zoom|Reset Zoom" })

-- Trocar de janela (Alt+Tab com prévia) e visão geral dos workspaces.
-- Passam por scripts/passthrough.sh: se a janela em foco é um app X11 segurando o teclado
-- (Parsec em modo imersivo), o atalho vai pra ela em vez de agir no Hyprland.
local function passthrough(mods, key, cmd)
    return hl.dsp.exec_cmd("~/.config/hypr/scripts/passthrough.sh '" .. mods .. "' " .. key .. " -- " .. cmd)
end
hl.bind("ALT + Tab",         passthrough("ALT", "Tab", "qs ipc call switcher next"), { description = "Windows|Switch Windows" })
hl.bind("ALT + SHIFT + Tab", passthrough("ALT SHIFT", "Tab", "qs ipc call switcher prev"), { description = "Windows|Switch Windows Backwards" })
-- soltar o Alt confirma a escolha (só age com o seletor aberto)
hl.bind("ALT + Alt_L",         hl.dsp.exec_cmd("qs ipc call switcher commit"), { release = true, description = "Hidden|Switcher commit" })
hl.bind("ALT + SHIFT + Alt_L", hl.dsp.exec_cmd("qs ipc call switcher commit"), { release = true, description = "Hidden|Switcher commit" })
hl.bind(mainMod .. " + Tab", passthrough(mainMod, "Tab", "qs ipc call overview toggle"), { description = "Workspaces|Overview" })

-- Foco com mainMod + setas
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }),  { description = "Windows|Focus Left" })
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }), { description = "Windows|Focus Right" })
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }),    { description = "Windows|Focus Up" })
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }),  { description = "Windows|Focus Down" })

-- Trocar de lugar com a vizinha (mainMod + SHIFT + setas) e redimensionar (mainMod + CTRL + setas)
--
-- Hyprland 0.57.2 bug: swapping a group across monitors (no neighbour on this workspace, so the
-- swap goes to the window on the next monitor) moves the group's layout node into the other
-- workspace's tree but leaves its windows on the old workspace: they are laid out on one monitor
-- and drawn as part of the other, so the group vanishes. It hits whichever side of the swap is the
-- group (a plain window swapped onto a monitor whose workspace holds one too). So when the swap
-- would cross monitors (nothing that way on its own workspace) and a group is on either side, the
-- window is moved to the active workspace of that monitor instead, which moves groups correctly;
-- everything else is the plain swap.
-- Logical box of a monitor (size / scale, sides swapped when rotated 90/270)
local function monitorBox(m)
    local w, h = m.width / m.scale, m.height / m.scale
    if m.transform % 2 == 1 then w, h = h, w end
    return m.x, m.y, w, h
end
-- The nearest monitor wholly on that side of `cur` and overlapping it on the other axis, as the
-- swap itself finds it (a point probe misses it: the AW is shorter than the portrait monitor)
local function monitorToward(cur, dir)
    local cx, cy, cw, ch = monitorBox(cur)
    local best, bestDist
    for _, m in ipairs(hl.get_monitors()) do
        if m.name ~= cur.name and m.enabled ~= false then
            local x, y, w, h = monitorBox(m)
            local vert = y < cy + ch and y + h > cy
            local horiz = x < cx + cw and x + w > cx
            local dist
            if dir == "left" and vert and x + w <= cx then dist = cx - (x + w)
            elseif dir == "right" and vert and x >= cx + cw then dist = x - (cx + cw)
            elseif dir == "up" and horiz and y + h <= cy then dist = cy - (y + h)
            elseif dir == "down" and horiz and y >= cy + ch then dist = y - (cy + ch) end
            if dist and (not bestDist or dist < bestDist) then best, bestDist = m, dist end
        end
    end
    return best
end
local function swapWindow(dir)
    local plain = hl.dsp.window.swap({ direction = dir })
    return function()
        local w = hl.get_active_window()
        if not (w and not w.floating and w.workspace) then
            return hl.dispatch(plain)
        end
        local ax, ay, aw, ah = w.at.x, w.at.y, w.size.x, w.size.y
        for _, o in ipairs(hl.get_windows({ workspace = w.workspace.id })) do
            if o.address ~= w.address and not o.floating and not o.hidden and o.mapped then
                local ox, oy, ow, oh = o.at.x, o.at.y, o.size.x, o.size.y
                local vert = oy < ay + ah and oy + oh > ay
                local horiz = ox < ax + aw and ox + ow > ax
                if (dir == "left" and vert and ox + ow <= ax + 1)
                    or (dir == "right" and vert and ox >= ax + aw - 1)
                    or (dir == "up" and horiz and oy + oh <= ay + 1)
                    or (dir == "down" and horiz and oy >= ay + ah - 1) then
                    return hl.dispatch(plain)
                end
            end
        end
        -- Crossing monitors: the bug hits whichever side of the swap is a group
        local m = w.monitor and monitorToward(w.monitor, dir)
        local ws = m and m.active_workspace
        if ws then
            local grouped = w.group ~= nil
            for _, o in ipairs(hl.get_windows({ workspace = ws.id })) do
                if o.group and not o.floating then grouped = true end
            end
            if grouped then
                return hl.dispatch(hl.dsp.window.move({ workspace = ws.id }))
            end
        end
        return hl.dispatch(plain)
    end
end
hl.bind(mainMod .. " + SHIFT + left",  swapWindow("left"),  { description = "Windows|Swap Left" })
hl.bind(mainMod .. " + SHIFT + right", swapWindow("right"), { description = "Windows|Swap Right" })
hl.bind(mainMod .. " + SHIFT + up",    swapWindow("up"),    { description = "Windows|Swap Up" })
hl.bind(mainMod .. " + SHIFT + down",  swapWindow("down"),  { description = "Windows|Swap Down" })
hl.bind(mainMod .. " + CTRL + left",  hl.dsp.window.resize({ x = -60, y = 0, relative = true }), { repeating = true, description = "Windows|Narrower" })
hl.bind(mainMod .. " + CTRL + right", hl.dsp.window.resize({ x = 60, y = 0, relative = true }),  { repeating = true, description = "Windows|Wider" })
hl.bind(mainMod .. " + CTRL + up",    hl.dsp.window.resize({ x = 0, y = -60, relative = true }), { repeating = true, description = "Windows|Shorter" })
hl.bind(mainMod .. " + CTRL + down",  hl.dsp.window.resize({ x = 0, y = 60, relative = true }),  { repeating = true, description = "Windows|Taller" })

-- Mover/redimensionar com mainMod + botão esquerdo/direito
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, description = "Windows|Move" })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, description = "Windows|Resize" })

-- Workspaces: mainMod + [0-9] troca, mainMod + SHIFT + [0-9] move a janela
for i = 1, 10 do
    local key = i % 10 -- 10 vira a tecla 0
    hl.bind(mainMod .. " + " .. key,             hl.dsp.focus({ workspace = i }),       { description = "Workspaces|Go to Workspace " .. i })
    hl.bind(mainMod .. " + SHIFT + " .. key,     hl.dsp.window.move({ workspace = i }), { description = "Workspaces|Move Window to Workspace " .. i })
end

-- Workspace especial (scratchpad)
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"),            { description = "Workspaces|Scratchpad" })
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }), { description = "Workspaces|Move Window to Scratchpad" })

-- Rolar entre workspaces com mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { description = "Workspaces|Next Workspace" })
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }), { description = "Workspaces|Previous Workspace" })

-- Sistema
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("loginctl lock-session"), { description = "System|Lock Screen" })
-- Works while locked: if the lock shows nothing (red/black screen) or froze, kills it and starts a fresh one
hl.bind(mainMod .. " + CTRL + ALT + L", hl.dsp.exec_cmd("~/.config/hypr/scripts/lock.sh --relaunch"), { locked = true, description = "System|Lock Screen: Relaunch (if stuck)" })
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("qs ipc call keys toggle"), { description = "System|Keyboard Shortcuts" })
hl.bind(mainMod .. " + ALT + F4", hl.dsp.exec_cmd("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"), { description = "System|Log Out" })

-- Teclas multimídia: volume
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true, description = "Media|Volume Up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true, description = "Media|Volume Down" })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true, description = "Media|Mute" })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true, description = "Media|Mute Microphone" })

-- Mídia (requer playerctl)
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true, description = "Media|Next Track" })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Media|Play / Pause" })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true, description = "Media|Play / Pause" })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true, description = "Media|Previous Track" })

-- Capturas de tela (requer grim, slurp, satty, wl-clipboard)
hl.bind("Print", hl.dsp.exec_cmd([[grim -g "$(slurp)" - | wl-copy]]), { description = "Screenshots|Region to Clipboard" })
hl.bind(mainMod .. " + Print", hl.dsp.exec_cmd([[grim -g "$(slurp)" - | satty --filename - --copy-command wl-copy --early-exit]]), { description = "Screenshots|Region in Editor" })
hl.bind("SHIFT + Print", hl.dsp.exec_cmd([[grim ~/Pictures/Screenshots/$(date +%F_%H-%M-%S).png]]), { description = "Screenshots|Full Screen to File" })

-- Replay (estilo ShadowPlay)
hl.bind("ALT + F10", hl.dsp.exec_cmd("qs ipc call replay save || systemctl --user kill --kill-whom=main -s SIGUSR1 gsr-replay"), { description = "Replay|Save Last 30 Seconds" })
hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd("qs ipc call replay toggle"), { description = "Replay|Turn Replay On / Off" })
