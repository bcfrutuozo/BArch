-- Entrada: teclado, mouse, touchpad, gestos

hl.config({
    input = {
        kb_layout  = "br",
        kb_variant = "abnt2",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        follow_mouse = 1,

        sensitivity = 0, -- -1.0 a 1.0; 0 = sem modificação

        touchpad = {
            natural_scroll = false,
        },

	numlock_by_default = true,
    },

    cursor = {
	no_hardware_cursors = 1,
    }
})

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace"
})

-- Config por dispositivo (exemplo do padrão; troque pelo nome real em `hyprctl devices`)
-- https://wiki.hypr.land/Configuring/Advanced-and-Cool/Devices/
hl.device({
    name        = "epic-mouse-v1",
    sensitivity = -0.5,
})
