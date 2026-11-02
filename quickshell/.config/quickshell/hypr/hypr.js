// hypr.js — pure helpers of the Hyprland settings app: option typing (from `hyprctl descriptions`
// and the Lua stubs Hyprland ships), value conversions between what hyprctl prints and what
// hl.config takes, and a tolerant reader of the hand-written conf/*.lua files (display only).
.pragma library

// ---------- sections ----------
var SECTIONS = [
    { id: "general",       label: "General",        icon: "3" },
    { id: "decoration",    label: "Decoration",     icon: "b" },
    { id: "animations",    label: "Animations",     icon: "4" },
    { id: "input",         label: "Input",          icon: "c" },
    { id: "gestures",      label: "Gestures",       icon: "b" },
    { id: "group",         label: "Groups",         icon: "1" },
    { id: "misc",          label: "Misc",           icon: "d" },
    { id: "binds",         label: "Binds",          icon: "c" },
    { id: "cursor",        label: "Cursor",         icon: "3" },
    { id: "render",        label: "Render",         icon: "0" },
    { id: "layout",        label: "Layout",         icon: "a" },
    { id: "dwindle",       label: "Dwindle",        icon: "a" },
    { id: "master",        label: "Master",         icon: "a" },
    { id: "scrolling",     label: "Scrolling",      icon: "a" },
    { id: "layers",        label: "Layers",         icon: "a" },
    { id: "xwayland",      label: "XWayland",       icon: "f" },
    { id: "opengl",        label: "OpenGL",         icon: "0" },
    { id: "ecosystem",     label: "Ecosystem",      icon: "f" },
    { id: "input-capture", label: "Input capture",  icon: "c" },
    { id: "experimental",  label: "Experimental",   icon: "0" },
    { id: "quirks",        label: "Quirks",         icon: "0" },
    { id: "debug",         label: "Debug",          icon: "0" }
]

function sectionLabel(id) {
    for (var i = 0; i < SECTIONS.length; i++) if (SECTIONS[i].id === id) return SECTIONS[i].label
    return id.charAt(0).toUpperCase() + id.slice(1)
}

// options the bar applies from the theme (theme/Theme.qml, hyprLua): editing them here would be
// undone at the next palette change or reload
var THEMED = {
    "general:col.active_border": true, "general:col.inactive_border": true,
    "group:col.border_active": true, "group:col.border_inactive": true,
    "group:groupbar:col.active": true, "group:groupbar:col.inactive": true,
    "decoration:rounding": true, "misc:background_color": true
}

// ---------- types ----------
// "general:col.active_border" -> "general.col.active_border" (the key of the Lua stubs)
function stubKey(name) { return name.replace(/-/g, "_").replace(/:/g, ".") }

// the ConfigValueTypes block of /usr/share/hypr/stubs/hl.meta.lua: exact type of every option
function parseStubTypes(text) {
    var out = {}
    var re = /---@field \['([^']+)'\] ([A-Za-z0-9_.|]+)/g
    var m
    while ((m = re.exec(text)) !== null) {
        var t = m[2]
        var kind = t === "boolean" ? "bool"
                 : t === "integer|boolean" ? "int"
                 : t === "number|boolean" ? "float"
                 : t === "string|HL.Gradient" ? "gradient"
                 : t === "HL.Vec2Like" ? "vec2"
                 : t === "integer|HL.CssGap" ? "gaps"
                 : "string"
        out[m[1]] = kind
    }
    return out
}

var HEX8 = /^[0-9a-fA-F]{8}$/
var GRADIENT = /^([0-9a-fA-F]{8}\s+)+\d+deg$/

// o = an entry of `hyprctl descriptions`; stub = kind from the stubs (may be undefined)
function kindOf(o, stub) {
    var d = o["default"], c = o.current
    if (stub === "string") {
        var v = typeof c === "string" ? c : ""
        var dv = typeof d === "string" ? d : ""
        if (HEX8.test(dv) || (HEX8.test(v) && /col|color|tint/.test(o.name))) return "color"
        if (/col|color|tint/.test(o.name) && (dv === "-1" || v === "-1")) return "color"
        return "string"
    }
    if (stub) return stub
    if (typeof d === "boolean") return "bool"
    if (typeof d === "number") {
        var ints = [d, c, o.min, o.max].every(function (x) { return x === undefined || Number.isInteger(x) })
        return ints ? "int" : "float"
    }
    if (Array.isArray(d)) return "vec2"
    if (typeof d === "string") {
        if (GRADIENT.test(d)) return "gradient"
        if (HEX8.test(d)) return "color"
        if (/^\d+ \d+ \d+ \d+$/.test(d)) return "gaps"
    }
    return "string"
}

// "[dwindle/master/scrolling]" in a description -> choices for a string option
function choicesOf(desc) {
    var m = /\[([^\]]*\/[^\]]*)\]/.exec(desc || "")
    if (!m) return []
    return m[1].split("/").map(function (s) { return s.trim() }).filter(function (s) { return s !== "" })
}

// labels of an enum (descriptions give [{label: value}, ...])
function mapEntries(map) {
    var out = []
    for (var i = 0; i < (map || []).length; i++) {
        var k = Object.keys(map[i])[0]
        out.push({ label: k, value: map[i][k] })
    }
    out.sort(function (a, b) { return a.value - b.value })
    return out
}

function isEmptyString(v) { return v === "" || v === "[[EMPTY]]" }
function displayString(v) { return isEmptyString(v) ? "" : (v === "[[Auto]]" ? "" : String(v)) }

// ---------- colors ----------
// hyprctl prints colors as aarrggbb, which is also Qt's "#AARRGGBB"
function argbToQt(s) { return "#" + s.toLowerCase() }
function qtToArgb(q) { return String(q).replace("#", "").toLowerCase() }
// hl.config takes "rgba(rrggbbaa)"
function argbToRgba(argb) { argb = argb.toLowerCase(); return "rgba(" + argb.slice(2) + argb.slice(0, 2) + ")" }
function qtToRgba(q) { return argbToRgba(qtToArgb(q)) }
function rgbaToArgb(s) {
    var m = /rgba\(([0-9a-fA-F]{8})\)/.exec(s)
    if (m) return (m[1].slice(6) + m[1].slice(0, 6)).toLowerCase()
    m = /rgb\(([0-9a-fA-F]{6})\)/.exec(s)
    if (m) return "ff" + m[1].toLowerCase()
    return "ffffffff"
}
function parseGradient(s) {
    var parts = String(s).trim().split(/\s+/)
    var colors = [], angle = 0
    for (var i = 0; i < parts.length; i++) {
        if (/deg$/.test(parts[i])) angle = parseInt(parts[i], 10) || 0
        else if (HEX8.test(parts[i])) colors.push(argbToQt(parts[i]))
    }
    if (colors.length === 0) colors.push("#ffffffff")
    return { colors: colors, angle: angle }
}
// what goes into settings.json for a gradient option
function gradientValue(g) {
    return { colors: g.colors.map(qtToRgba), angle: g.angle }
}

// ---------- gaps ("top right bottom left") ----------
function parseGaps(s) {
    var p = String(s).trim().split(/\s+/).map(function (x) { return parseInt(x, 10) || 0 })
    while (p.length < 4) p.push(p[p.length - 1] || 0)
    return p.slice(0, 4)
}
function gapsValue(p) {
    if (p[0] === p[1] && p[1] === p[2] && p[2] === p[3]) return p[0]
    return { top: p[0], right: p[1], bottom: p[2], left: p[3] }
}

// ---------- values as text (status lines, the file page) ----------
function valueText(kind, v) {
    if (v === undefined || v === null) return ""
    if (kind === "vec2") return Array.isArray(v) ? v.join(" × ") : String(v)
    if (kind === "string") return displayString(v)
    return String(v)
}

// ---------- key binds ----------
var MODS = [["SUPER", 64], ["CTRL", 4], ["ALT", 8], ["SHIFT", 1], ["CAPS", 2], ["MOD2", 16], ["MOD3", 32], ["MOD5", 128]]
function modNames(mask) {
    var out = []
    for (var i = 0; i < MODS.length; i++) if (mask & MODS[i][1]) out.push(MODS[i][0])
    return out
}
function bindKeys(b) {
    var mods = modNames(b.modmask)
    var key = b.key !== "" ? b.key : (b.keycode ? "code:" + b.keycode : "")
    return mods.concat(key ? [key] : []).join(" + ")
}
function dispatcherName(b) {
    var m = /HL\.Dispatcher\((.*)\)/.exec(b.dispatcher || "")
    return m ? m[1] : (b.dispatcher || "")
}
var BIND_FLAGS = [
    { id: "repeating", label: "repeat", hint: "repeats while held" },
    { id: "locked", label: "locked", hint: "works while the screen is locked" },
    { id: "release", label: "release", hint: "fires on release" },
    { id: "mouse", label: "mouse", hint: "mouse bind (mouse:272 ...)" },
    { id: "non_consuming", label: "non-consuming", hint: "the key also reaches the window" },
    { id: "transparent", label: "transparent", hint: "cannot be shadowed by other binds" },
    { id: "ignore_mods", label: "ignore mods", hint: "ignores other modifiers" },
    { id: "long_press", label: "long press", hint: "fires on a long press" },
    { id: "dont_inhibit", label: "no inhibit", hint: "even with shortcuts inhibited" },
    { id: "click", label: "click", hint: "mouse click (0.57)" },
    { id: "drag", label: "drag", hint: "mouse drag (0.57)" },
    { id: "submap_universal", label: "universal", hint: "in every submap" },
    { id: "allow_input_capture", label: "input capture", hint: "also while input is captured" }
]

// ---------- monitors ----------
var TRANSFORMS = ["normal", "90°", "180°", "270°", "flipped", "flipped 90°", "flipped 180°", "flipped 270°"]
var CM_PRESETS = ["auto", "srgb", "wide", "edid", "hdr", "hdredid", "dcip3", "dp3", "adobe"]
var VRR_MODES = [{ label: "off", value: 0 }, { label: "on", value: 1 }, { label: "fullscreen only", value: 2 }, { label: "fullscreen video / games", value: 3 }]
var POSITIONS = ["auto", "auto-left", "auto-right", "auto-up", "auto-down", "auto-center-left", "auto-center-right", "auto-center-up", "auto-center-down"]
var MONITOR_FIELDS = [
    { id: "mode",                kind: "mode",   label: "Mode",                 hint: "WxH@Hz, preferred, highres, highrr" },
    { id: "position",            kind: "pos",    label: "Position",             hint: "auto, auto-left… or x y" },
    { id: "scale",               kind: "float",  label: "Scale",                min: 0.25, max: 4, step: 0.05 },
    { id: "transform",           kind: "enum",   label: "Transform",            values: TRANSFORMS.map(function (l, i) { return { label: l, value: i } }) },
    { id: "bitdepth",            kind: "enum",   label: "Bit depth",            values: [{ label: "8", value: 8 }, { label: "10", value: 10 }] },
    { id: "cm",                  kind: "choice", label: "Color management",     choices: CM_PRESETS },
    { id: "vrr",                 kind: "enum",   label: "VRR",                  values: VRR_MODES },
    { id: "sdrbrightness",       kind: "float",  label: "SDR brightness",       min: 0, max: 2, step: 0.05, hint: "SDR content inside HDR" },
    { id: "sdrsaturation",       kind: "float",  label: "SDR saturation",       min: 0, max: 2, step: 0.05 },
    { id: "sdr_min_luminance",   kind: "float",  label: "SDR min luminance",    min: 0, max: 1, step: 0.001 },
    { id: "sdr_max_luminance",   kind: "int",    label: "SDR max luminance",    min: 0, max: 10000 },
    { id: "min_luminance",       kind: "float",  label: "Panel min luminance",  min: 0, max: 1, step: 0.0001 },
    { id: "max_luminance",       kind: "int",    label: "Panel max luminance",  min: 0, max: 10000 },
    { id: "max_avg_luminance",   kind: "int",    label: "Panel max avg lum.",   min: 0, max: 10000 },
    { id: "supports_hdr",        kind: "enum",   label: "Supports HDR",         values: [{ label: "as reported", value: 0 }, { label: "force yes", value: 1 }] },
    { id: "supports_wide_color", kind: "enum",   label: "Supports wide color",  values: [{ label: "as reported", value: 0 }, { label: "force yes", value: 1 }] },
    { id: "sdr_eotf",            kind: "string", label: "SDR EOTF",             hint: "default, 1 (sRGB), 2 (gamma 2.2)…" },
    { id: "icc",                 kind: "string", label: "ICC profile",          hint: "path" },
    { id: "mirror",              kind: "string", label: "Mirror of",            hint: "another output's name" },
    { id: "reserved",            kind: "string", label: "Reserved area",        hint: "top right bottom left" },
    { id: "disabled",            kind: "bool",   label: "Disabled" }
]
// what `hyprctl monitors` says, in the fields above
function monitorLive(m) {
    var hz = m.refreshRate ? Number(m.refreshRate).toFixed(2).replace(/\.?0+$/, "") : ""
    return {
        mode: m.width + "x" + m.height + (hz ? "@" + hz : ""),
        position: m.x + " " + m.y,
        scale: m.scale,
        transform: m.transform,
        bitdepth: /2101010|XRGB2101010|ABGR2101010|XBGR2101010|ARGB2101010/.test(m.currentFormat || "") ? 10 : 8,
        cm: m.colorManagementPreset || "",
        vrr: m.vrr ? 1 : 0,
        sdrbrightness: m.sdrBrightness,
        sdrsaturation: m.sdrSaturation,
        sdr_min_luminance: m.sdrMinLuminance,
        sdr_max_luminance: m.sdrMaxLuminance,
        mirror: m.mirrorOf === "none" ? "" : m.mirrorOf,
        reserved: (m.reserved || []).join(" "),
        disabled: !!m.disabled
    }
}
function uniqueModes(list) {
    var seen = {}, out = []
    for (var i = 0; i < (list || []).length; i++) {
        var s = String(list[i]).replace(/\.00Hz$/, "").replace(/Hz$/, "")
        if (!seen[s]) { seen[s] = true; out.push(s) }
    }
    return out
}

// ---------- devices (HL.DeviceSpec of the stubs) ----------
var DEVICE_FIELDS = [
    { id: "enabled", kind: "bool" }, { id: "sensitivity", kind: "float", min: -1, max: 1, step: 0.05 },
    { id: "accel_profile", kind: "choice", choices: ["", "adaptive", "flat", "custom"] },
    { id: "natural_scroll", kind: "bool" }, { id: "left_handed", kind: "bool" }, { id: "scroll_factor", kind: "float", min: 0, max: 10, step: 0.1 },
    { id: "scroll_method", kind: "choice", choices: ["", "2fg", "edge", "on_button_down", "no_scroll"] },
    { id: "scroll_button", kind: "int", min: 0, max: 400 }, { id: "scroll_button_lock", kind: "bool" }, { id: "scroll_points", kind: "string" },
    { id: "middle_button_emulation", kind: "bool" }, { id: "tap_to_click", kind: "bool" }, { id: "tap_and_drag", kind: "bool" },
    { id: "drag_lock", kind: "int", min: 0, max: 2 }, { id: "drag_3fg", kind: "int", min: 0, max: 2 }, { id: "clickfinger_behavior", kind: "bool" },
    { id: "tap_button_map", kind: "choice", choices: ["", "lrm", "lmr"] }, { id: "disable_while_typing", kind: "bool" },
    { id: "kb_layout", kind: "string" }, { id: "kb_variant", kind: "string" }, { id: "kb_model", kind: "string" }, { id: "kb_options", kind: "string" },
    { id: "kb_rules", kind: "string" }, { id: "kb_file", kind: "string" }, { id: "numlock_by_default", kind: "bool" }, { id: "resolve_binds_by_sym", kind: "bool" },
    { id: "repeat_rate", kind: "int", min: 0, max: 200 }, { id: "repeat_delay", kind: "int", min: 0, max: 5000 }, { id: "keybinds", kind: "bool" },
    { id: "share_states", kind: "int", min: 0, max: 2 }, { id: "release_pressed_on_close", kind: "bool" },
    { id: "output", kind: "string" }, { id: "transform", kind: "int", min: 0, max: 7 }, { id: "rotation", kind: "int", min: 0, max: 359 },
    { id: "flip_x", kind: "bool" }, { id: "flip_y", kind: "bool" }, { id: "relative_input", kind: "bool" }, { id: "absolute_region_position", kind: "bool" },
    { id: "region_position", kind: "string" }, { id: "region_size", kind: "string" }, { id: "active_area_position", kind: "string" }, { id: "active_area_size", kind: "string" },
    { id: "tags", kind: "string" }
]

// ---------- rules (keys suggested in the editors; anything else can be typed) ----------
var WINDOW_MATCH_KEYS = ["class", "title", "initial_class", "initial_title", "tag", "xwayland", "float", "fullscreen", "pin", "focus", "workspace", "fullscreen_state", "content", "xdg_tag", "on_workspace", "group"]
var WINDOW_RULE_KEYS = ["float", "tile", "fullscreen", "maximize", "fullscreen_state", "move", "size", "center", "pseudo", "monitor", "workspace", "pin", "no_focus", "no_initial_focus", "stay_focused", "focus_on_activate", "allows_input", "opacity", "opaque", "dim_around", "animation", "border_color", "border_size", "rounding", "rounding_power", "no_anim", "no_blur", "no_border", "no_dim", "no_rounding", "no_shadow", "no_shortcuts_inhibit", "no_screen_share", "no_follow_mouse", "no_max_size", "no_vfr", "no_closefor", "max_size", "min_size", "keep_aspect_ratio", "idle_inhibit", "immediate", "render_unfocused", "scroll_mouse", "scroll_touchpad", "suppress_event", "syncfullscreen", "xray", "tag", "group", "persistent_size", "prop", "content", "enabled"]
var LAYER_MATCH_KEYS = ["namespace", "address"]
var LAYER_RULE_KEYS = ["blur", "blur_popups", "ignore_alpha", "dim_around", "xray", "no_anim", "animation", "order", "above_lock", "no_screen_share", "enabled"]
var WORKSPACE_RULE_KEYS = ["workspace", "monitor", "default", "default_name", "persistent", "gaps_in", "gaps_out", "float_gaps", "border_size", "decorate", "no_border", "no_rounding", "no_shadow", "layout", "layout_opts", "on_created_empty", "animation", "enabled"]
var GESTURE_DIRECTIONS = ["horizontal", "vertical", "left", "right", "up", "down", "swipe", "pinch", "pinchin", "pinchout"]
var GESTURE_ACTIONS = ["workspace", "fullscreen", "move", "resize", "special", "close", "float", "dispatcher", "scale", "unset"]

// ---------- Lua files (tolerant reading, for display) ----------
// every `fn(` call in a file with its argument text and line: hl.window_rule({ ... })
function findCalls(text, fn) {
    var out = []
    var needle = fn + "("
    var i = 0
    while ((i = text.indexOf(needle, i)) !== -1) {
        // skip a commented call
        var ls = text.lastIndexOf("\n", i) + 1
        var prefix = text.slice(ls, i)
        if (prefix.indexOf("--") !== -1) { i += needle.length; continue }
        var start = i + needle.length
        var depth = 1, j = start, inStr = null
        while (j < text.length && depth > 0) {
            var c = text[j]
            if (inStr) {
                if (c === "\\" ) j++
                else if (inStr === "]]" ? text.substr(j, 2) === "]]" : c === inStr) { if (inStr === "]]") j++; inStr = null }
            } else if (c === '"' || c === "'") inStr = c
            else if (text.substr(j, 2) === "[[") { inStr = "]]"; j++ }
            else if (text.substr(j, 2) === "--") { var nl = text.indexOf("\n", j); j = nl === -1 ? text.length : nl; continue }
            else if (c === "(" || c === "{") depth++
            else if (c === ")" || c === "}") depth--
            j++
        }
        var line = text.slice(0, i).split("\n").length
        out.push({ line: line, args: text.slice(start, j - 1).trim() })
        i = j
    }
    return out
}

// a Lua table literal -> JS (strings, numbers, booleans, nested tables; anything else as text)
function parseLuaTable(src) {
    var pos = 0
    function skip() {
        for (;;) {
            while (pos < src.length && /\s/.test(src[pos])) pos++
            if (src.substr(pos, 2) === "--") { var nl = src.indexOf("\n", pos); pos = nl === -1 ? src.length : nl } else break
        }
    }
    function value() {
        skip()
        var c = src[pos]
        if (c === "{") return table()
        if (c === '"' || c === "'") {
            var q = c, s = "", k = pos + 1
            while (k < src.length && src[k] !== q) { if (src[k] === "\\") { s += src[k + 1]; k += 2 } else { s += src[k]; k++ } }
            pos = k + 1
            return s
        }
        if (src.substr(pos, 2) === "[[") { var e = src.indexOf("]]", pos + 2); var r = src.slice(pos + 2, e); pos = e + 2; return r }
        var m = /^-?(0x[0-9a-fA-F]+|\d+\.?\d*(e-?\d+)?)/.exec(src.slice(pos))
        if (m) { pos += m[0].length; return m[0].indexOf("0x") !== -1 ? parseInt(m[0], 16) : Number(m[0]) }
        if (src.substr(pos, 4) === "true" && !/[\w]/.test(src[pos + 4] || "")) { pos += 4; return true }
        if (src.substr(pos, 5) === "false" && !/[\w]/.test(src[pos + 5] || "")) { pos += 5; return false }
        // an expression: up to the next , or } at depth 0
        var depth = 0, k2 = pos
        while (k2 < src.length) {
            var ch = src[k2]
            if (ch === "(" || ch === "{") depth++
            else if (ch === ")" || ch === "}") { if (depth === 0) break; depth-- }
            else if (ch === "," && depth === 0) break
            k2++
        }
        var expr = src.slice(pos, k2).trim()
        pos = k2
        return expr
    }
    function table() {
        var t = {}, arr = [], isArr = true
        pos++ // {
        for (;;) {
            skip()
            if (pos >= src.length) break
            if (src[pos] === "}") { pos++; break }
            var m = /^([A-Za-z_][\w]*)\s*=(?!=)/.exec(src.slice(pos))
            var m2 = /^\[\s*"([^"]+)"\s*\]\s*=/.exec(src.slice(pos))
            if (m2) { pos += m2[0].length; t[m2[1]] = value(); isArr = false }
            else if (m) { pos += m[0].length; t[m[1]] = value(); isArr = false }
            else arr.push(value())
            skip()
            if (src[pos] === "," || src[pos] === ";") pos++
        }
        return isArr && arr.length > 0 ? arr : (arr.length > 0 ? Object.assign({ __list: arr }, t) : t)
    }
    try { return value() } catch (e) { return {} }
}

function parseEnv(text) {
    var out = [], re = /hl\.env\(\s*"([^"]+)"\s*,\s*"([^"]*)"\s*\)/g, m
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
        if (/^\s*--/.test(lines[i])) continue
        re.lastIndex = 0
        while ((m = re.exec(lines[i])) !== null) out.push({ name: m[1], value: m[2], line: i + 1 })
    }
    return out
}
function parseExec(text) {
    var out = [], lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
        if (/^\s*--/.test(lines[i])) continue
        var m = /hl\.exec_cmd\(\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|\[\[(.*?)\]\])/.exec(lines[i])
        if (m) out.push({ command: m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : m[3]), line: i + 1 })
    }
    return out
}
function parseCurveNames(text) {
    var out = [], re = /hl\.curve\(\s*"([^"]+)"/g, m
    while ((m = re.exec(text)) !== null) out.push(m[1])
    return out
}

// where a plain `key = value` of an option lives in the files ("conf/look.lua:9"), best effort
function findOptionSource(files, name) {
    var key = name.split(/[:.]/).pop()
    var re = new RegExp("^\\s*" + key + "\\s*=")
    var hits = []
    for (var path in files) {
        var lines = files[path].split("\n")
        for (var i = 0; i < lines.length; i++) if (re.test(lines[i])) hits.push(path.replace(/^.*\/\.config\/hypr\//, "") + ":" + (i + 1))
    }
    return hits
}

function clone(v) { return JSON.parse(JSON.stringify(v)) }
function fmt(n, step) {
    if (step && step < 1) { var d = Math.max(0, Math.ceil(-Math.log10(step))); return Number(n).toFixed(d).replace(/\.?0+$/, "") }
    return String(n)
}

// ---------- hyprlang files (hypridle.conf, hyprsunset.conf): read, edit, write back ----------
// items: { kind: "comment"|"blank", text } | { kind: "kv", key, value } | { kind: "block", name, items }
function parseHyprlang(text) {
    var root = [], stack = [root]
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i], t = line.trim(), cur = stack[stack.length - 1]
        if (t === "") { cur.push({ kind: "blank" }); continue }
        if (t[0] === "#") { cur.push({ kind: "comment", text: t }); continue }
        var mb = /^([A-Za-z0-9_:\-]+)\s*\{$/.exec(t)
        if (mb) { var b = { kind: "block", name: mb[1], items: [] }; cur.push(b); stack.push(b.items); continue }
        if (t === "}") { if (stack.length > 1) stack.pop(); continue }
        var eq = t.indexOf("=")
        if (eq > 0) { cur.push({ kind: "kv", key: t.slice(0, eq).trim(), value: t.slice(eq + 1).trim() }); continue }
        cur.push({ kind: "comment", text: "# " + t })      // something we do not understand: kept, disabled
    }
    // drop trailing blanks
    while (root.length && root[root.length - 1].kind === "blank") root.pop()
    return root
}
function writeHyprlang(items, indent) {
    indent = indent || ""
    var out = []
    for (var i = 0; i < items.length; i++) {
        var it = items[i]
        if (it.kind === "blank") out.push("")
        else if (it.kind === "comment") out.push(indent + it.text)
        else if (it.kind === "kv") out.push(indent + it.key + " = " + it.value)
        else if (it.kind === "block") { out.push(indent + it.name + " {"); out.push(writeHyprlang(it.items, indent + "    ")); out.push(indent + "}") }
    }
    return out.join("\n")
}
function blockGet(block, key) { for (var i = 0; i < block.items.length; i++) if (block.items[i].kind === "kv" && block.items[i].key === key) return block.items[i].value; return undefined }
function blockSet(block, key, value) {
    for (var i = 0; i < block.items.length; i++) if (block.items[i].kind === "kv" && block.items[i].key === key) {
        if (value === undefined || value === "") block.items.splice(i, 1); else block.items[i].value = value
        return
    }
    if (value !== undefined && value !== "") block.items.push({ kind: "kv", key: key, value: value })
}
function blocksOf(items, name) { return items.filter(function (x) { return x.kind === "block" && x.name === name }) }
function humanSeconds(s) {
    s = Number(s) || 0
    if (s % 3600 === 0 && s > 0) return (s / 3600) + " h"
    if (s % 60 === 0 && s > 0) return (s / 60) + " min"
    if (s > 60) return Math.floor(s / 60) + " min " + (s % 60) + " s"
    return s + " s"
}

// hypridle general keys (hypridle 0.1.x)
var IDLE_GENERAL = [
    { key: "lock_cmd", hint: "command that locks the screen (loginctl lock-session runs it)" },
    { key: "unlock_cmd", hint: "command that unlocks (loginctl unlock-session)" },
    { key: "before_sleep_cmd", hint: "run before the machine suspends" },
    { key: "after_sleep_cmd", hint: "run after resume" },
    { key: "on_lock_cmd", hint: "run when the session locks" },
    { key: "on_unlock_cmd", hint: "run when the session unlocks" },
    { key: "ignore_dbus_inhibit", hint: "true: idle even when an app asks not to (D-Bus)", bool: true },
    { key: "ignore_systemd_inhibit", hint: "true: ignore systemd idle inhibitors", bool: true },
    { key: "ignore_wayland_inhibit", hint: "true: ignore Wayland idle inhibitors", bool: true },
    { key: "inhibit_sleep", hint: "0 none · 1 always · 2 while locked, 3 until locked (lock_cmd)" }
]
var IDLE_PRESETS = [
    { label: "Lock the session", timeout: 300, on: "loginctl lock-session", resume: "" },
    { label: "Screen off", timeout: 330, on: "hyprctl dispatch 'hl.dsp.dpms({action = \"off\"})'", resume: "hyprctl dispatch 'hl.dsp.dpms({action = \"on\"})'" },
    { label: "Suspend", timeout: 1800, on: "systemctl suspend", resume: "" },
    { label: "Dim the keyboard light", timeout: 150, on: "brightnessctl -sd rgb:kbd_backlight set 0", resume: "brightnessctl -rd rgb:kbd_backlight" }
]
