-- Monitors
-- https://wiki.hypr.land/Configuring/Basics/Monitors/

-- Main: Alienware AW3225QF (4K QD-OLED, HDR)
hl.monitor({
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
})

-- Secundário: vertical, à esquerda
hl.monitor({
    output = "HDMI-A-1",
    mode = "3840x2160@60",
    position = "auto-left",
    transform = 1,
    scale = "2",
    bitdepth = 8,
    cm = "srgb"
})

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
