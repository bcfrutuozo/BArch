-- Monitors
-- https://wiki.hypr.land/Configuring/Basics/Monitors/
--
-- Os valores ficam em BArch.monitors para a barra poder mudar só um item (HDR, brilho
-- do SDR) pelo Control Center: ela chama BArch.set_monitor("HDMI-A-2", { cm = "srgb" })
-- via "hyprctl eval", que reenvia o monitor completo com a mudança por cima.
-- Edite os valores normalmente aqui; o que a barra mudar é reaplicado após cada reload.

BArch = BArch or {}

BArch.monitors = {
    -- Main: Alienware AW3225QF (4K QD-OLED, HDR)
    ["HDMI-A-2"] = {
        output   = "HDMI-A-2",
        mode     = "3840x2160@240",
        position = "auto",
        bitdepth = 10,
        scale    = "2",
        cm = "hdr",
        supports_hdr = 1,
        supports_wide_color = 1,
        vrr = 3,

        -- SDR within HDR
        sdr_min_luminance = 0.005,
        sdr_max_luminance = 250,
        sdrbrightness = 1.0,
        sdrsaturation = 1.0,

        -- 400 True Black panel limit
        min_luminance = 0.0002,
        max_luminance = 426,
        --max_avg_luminance = 250,
    },

    -- Secundário: vertical, à esquerda
    ["HDMI-A-1"] = {
        output = "HDMI-A-1",
        mode = "3840x2160@60",
        position = "auto-left",
        transform = 1,
        scale = "2",
        bitdepth = 8,
        cm = "srgb",
    },
}

-- mudanças feitas pela barra (a barra manda de novo depois de cada reload)
BArch.monitor_overrides = BArch.monitor_overrides or {}

function BArch.apply_monitor(name)
    local t = {}
    for k, v in pairs(BArch.monitors[name] or {}) do t[k] = v end
    t.disabled = false   -- re-enables an output turned off by hl.monitor({ disabled = true }); an override wins
    -- what the settings app saved for this output (settings.json), then the bar's live changes
    for k, v in pairs((BArch.settings and BArch.settings.monitor(name)) or {}) do t[k] = v end
    for k, v in pairs(BArch.monitor_overrides[name] or {}) do t[k] = v end
    hl.monitor(t)
end

function BArch.set_monitor(name, changes)
    BArch.monitor_overrides[name] = BArch.monitor_overrides[name] or {}
    for k, v in pairs(changes) do BArch.monitor_overrides[name][k] = v end
    BArch.apply_monitor(name)
end

for name in pairs(BArch.monitors) do BArch.apply_monitor(name) end

hl.config({
	render = {
		cm_sdr_eotf = 2,
		cm_auto_hdr = 0,
		direct_scanout = 0,
	},

	xwayland = {
		force_zero_scaling = true
	},
})
