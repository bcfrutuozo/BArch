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
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo(), { description = "Windows|Pseudotile" })
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"), { description = "Windows|Toggle Split" })    -- só dwindle
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("qs ipc call minimize window"), { description = "Windows|Minimize" })
hl.bind(mainMod .. " + SHIFT + M", hl.dsp.exec_cmd("qs ipc call minimize restoreLast"), { description = "Windows|Restore Last Minimized" })
hl.bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd("qs ipc call pin toggle"), { description = "Windows|Always on Top" })

-- Trocar de janela (Alt+Tab com prévia) e visão geral dos workspaces
hl.bind("ALT + Tab",         hl.dsp.exec_cmd("qs ipc call switcher next"), { description = "Windows|Switch Windows" })
hl.bind("ALT + SHIFT + Tab", hl.dsp.exec_cmd("qs ipc call switcher prev"), { description = "Windows|Switch Windows Backwards" })
-- soltar o Alt confirma a escolha (só age com o seletor aberto)
hl.bind("ALT + Alt_L",         hl.dsp.exec_cmd("qs ipc call switcher commit"), { release = true, description = "Hidden|Switcher commit" })
hl.bind("ALT + SHIFT + Alt_L", hl.dsp.exec_cmd("qs ipc call switcher commit"), { release = true, description = "Hidden|Switcher commit" })
hl.bind(mainMod .. " + Tab", hl.dsp.exec_cmd("qs ipc call overview toggle"), { description = "Workspaces|Overview" })

-- Foco com mainMod + setas
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }),  { description = "Windows|Focus Left" })
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }), { description = "Windows|Focus Right" })
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }),    { description = "Windows|Focus Up" })
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }),  { description = "Windows|Focus Down" })

-- Trocar de lugar com a vizinha (mainMod + SHIFT + setas) e redimensionar (mainMod + CTRL + setas)
hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.swap({ direction = "left" }),  { description = "Windows|Swap Left" })
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.swap({ direction = "right" }), { description = "Windows|Swap Right" })
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.swap({ direction = "up" }),    { description = "Windows|Swap Up" })
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.swap({ direction = "down" }),  { description = "Windows|Swap Down" })
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
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("qs ipc call keys toggle"), { description = "System|Keyboard Shortcuts" })
hl.bind(mainMod .. " + ALT + F4", hl.dsp.exec_cmd("command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"), { description = "System|Log Out" })

-- Teclas multimídia: volume e brilho
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true, description = "Media|Volume Up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true, description = "Media|Volume Down" })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true, description = "Media|Mute" })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true, repeating = true, description = "Media|Mute Microphone" })
hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true, description = "Media|Brightness Up" })
hl.bind("XF86MonBrightnessDown",hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true, description = "Media|Brightness Down" })

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
hl.bind("ALT + F10", hl.dsp.exec_cmd("qs ipc call replay save || systemctl --user kill -s SIGUSR1 gsr-replay"), { description = "Replay|Save Last 30 Seconds" })
hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd("qs ipc call replay toggle"), { description = "Replay|Turn Replay On / Off" })
