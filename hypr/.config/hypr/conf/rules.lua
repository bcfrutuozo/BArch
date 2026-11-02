-- Regras de janela, layer e workspace
-- https://wiki.hypr.land/Configuring/Basics/Window-Rules/
-- https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

local suppressMaximizeRule = hl.window_rule({
    -- Ignora pedidos de maximizar vindos dos apps
    name  = "suppress-maximize-events",
    match = { class = ".*" },

    suppress_event = "maximize",
})
-- suppressMaximizeRule:set_enabled(false)

hl.window_rule({
    -- Corrige problemas de arrasto no XWayland
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },

    no_focus = true,
})

hl.window_rule({
    name  = "move-hyprland-run",
    match = { class = "hyprland-run" },

    move  = "20 monitor_h-120",
    float = true,
})

hl.window_rule({
    -- Não deixa o hypridle agir enquanto houver janela em tela cheia
    name  = "idle-inhibit-fullscreen",
    match = { class = ".*" },

    idle_inhibit = "fullscreen",
})

hl.window_rule({
    -- Battle.net (launcher e janelas dele, como login e avisos) sempre flutuante.
    -- O WoW tem outra class (wow.exe) e continua no tiling normal.
    name  = "battlenet-float",
    match = { class = "^battle\\.net\\.exe$" },

    float = true,
})

hl.window_rule({
    -- Janela principal do launcher: centralizada e num tamanho confortável
    name  = "battlenet-launcher-size",
    match = { class = "^battle\\.net\\.exe$", title = "^Battle\\.net$" },

    size   = "1280 800",
    center = true,
})

-- Picture-in-Picture (Brave/Chromium e Firefox): flutuando, por cima de tudo,
-- em todos os workspaces, no canto inferior direito.
hl.window_rule({
    name  = "pip",
    match = { title = "^Picture[- ]in[- ][Pp]icture$" },

    float             = true,
    pin               = true,          -- segue você em todos os workspaces
    keep_aspect_ratio = true,
    no_initial_focus  = true,          -- não rouba o foco ao abrir
    size  = "480 270",
    move  = "monitor_w-500 monitor_h-290",
})

-- Editor de paletas (quickshell/palette, `barch theme edit`): flutuando e centralizado.
hl.window_rule({
    name  = "palette-editor",
    match = { title = "^BArch palettes$" },
    float  = true,
    center = true,
    size   = "1120 720",
})

-- Hyprland Settings (quickshell/hypr, `barch hypr`): flutuando e centralizado.
hl.window_rule({
    name  = "hyprland-settings",
    match = { title = "^BArch Hyprland$" },
    float  = true,
    center = true,
    size   = "1280 820",
})

-- Diálogos de arquivo: flutuando e centralizados, num tamanho fixo.
hl.window_rule({
    name  = "file-dialogs",
    match = { title = "^(Open|Save|Open File|Save File|Save As|Open Files|Open Folder|Select Folder|Select File|Choose Files?|File Upload)$" },

    float  = true,
    center = true,
    size   = "1100 700",
})

-- Diálogos que passam pelo portal do GTK (alguns apps abrem o seletor por ele)
hl.window_rule({
    name  = "portal-dialogs",
    match = { class = "^xdg-desktop-portal-gtk$" },

    float  = true,
    center = true,
    size   = "1100 700",
})

-- Layer rules também retornam um handle
-- local overlayLayerRule = hl.layer_rule({
--     name  = "no-anim-overlay",
--     match = { namespace = "^my-overlay$" },
--     no_anim = true,
-- })
-- overlayLayerRule:set_enabled(false)

-- "Smart gaps" (sem gaps com uma janela só). Descomente tudo para usar.
-- hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 0, gaps_in = 0 })
-- hl.workspace_rule({ workspace = "f[1]",   gaps_out = 0, gaps_in = 0 })
-- hl.window_rule({
--     name  = "no-gaps-wtv1",
--     match = { float = false, workspace = "w[tv1]" },
--     border_size = 0,
--     rounding    = 0,
-- })
-- hl.window_rule({
--     name  = "no-gaps-f1",
--     match = { float = false, workspace = "f[1]" },
--     border_size = 0,
--     rounding    = 0,
-- })
