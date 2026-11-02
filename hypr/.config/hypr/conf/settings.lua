-- Settings written by the Hyprland settings app (quickshell/hypr, `barch hypr`).
--
-- The app does not edit the hand-written files: it keeps what you change in
-- ~/.config/hypr/settings.json and this module applies that on top of conf/*.lua. Removing an
-- entry from the file (reset in the app) brings the value of the files back at the next reload.
--
-- settings.json:
--   options    { "general:gaps_out": 10, "decoration:blur:enabled": false, ... }
--              values typed as hl.config expects: integers for int options, booleans, strings,
--              colors as "rgba(rrggbbaa)", gradients { colors = {...}, angle = N }, vec2 as
--              {x, y}, css gaps as {top, right, bottom, left}
--   monitors   { "HDMI-A-2": { vrr = 1, ... } }  merged over BArch.monitors (conf/monitors.lua)
--   binds      [ { keys, command | lua, description, flags... } ]   lua = a dispatcher expression
--   unbinds    [ "SUPER + T" ]                      binds of the files turned off
--   animations { leaf = { enabled, speed, bezier | spring, style } }
--   curves     { name = { type = "bezier", points = {{x,y},{x,y}} } | { type = "spring", ... } }
--   env        { NAME = "value" }                   (applied at the next Hyprland start)
--   exec       [ "command" ]                        run once at session start
--   devices    { name = { sensitivity = 0.5, ... } }
--   gestures   [ { fingers, direction, action, ... } ]
--   window_rules / layer_rules / workspace_rules   [ spec ]  as hl.window_rule etc. take them
--
-- Live changes: the app writes the file and runs `hyprctl eval 'BArch.settings.apply("options")'`
-- (or "monitors", "animations", "devices"); anything else needs `hyprctl reload`. Errors of the last apply
-- are kept in BArch.settings.errors (`BArch.settings.report()` prints them).
--
-- hyprland.lua requires this module first (conf/monitors.lua merges `monitors` into its own
-- values) and calls BArch.settings.apply("all") after every other file.

BArch = BArch or {}
local S = {}
BArch.settings = S

S.path = (os.getenv("HOME") or "") .. "/.config/hypr/settings.json"
S.data = {}
S.errors = {}
S.loaded = false

-- ---------- a small JSON decoder (objects and arrays become tables, integers stay integers) ----------
local function decode(str)
    local pos = 1
    local function err(msg) error(("settings.json: %s at byte %d"):format(msg, pos), 0) end
    local function skip() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end
    local value
    local function string_()
        local out, i = {}, pos + 1
        while true do
            local c = str:sub(i, i)
            if c == "" then pos = i; err("unterminated string") end
            if c == '"' then pos = i + 1; return table.concat(out) end
            if c == "\\" then
                local n = str:sub(i + 1, i + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[n] then out[#out + 1] = map[n]; i = i + 2
                elseif n == "u" then
                    local hex = str:sub(i + 2, i + 5)
                    out[#out + 1] = utf8.char(tonumber(hex, 16) or 0xFFFD); i = i + 6
                else pos = i; err("bad escape") end
            else out[#out + 1] = c; i = i + 1 end
        end
    end
    local function number()
        local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not s then err("bad number") end
        local text = str:sub(s, e)
        pos = e + 1
        if text:find("[%.eE]") then return tonumber(text) end
        return math.tointeger(tonumber(text)) or tonumber(text)
    end
    function value()
        skip()
        local c = str:sub(pos, pos)
        if c == "{" then
            local t = {}
            pos = pos + 1; skip()
            if str:sub(pos, pos) == "}" then pos = pos + 1; return t end
            while true do
                skip()
                if str:sub(pos, pos) ~= '"' then err("expected a key") end
                local k = string_()
                skip()
                if str:sub(pos, pos) ~= ":" then err("expected ':'") end
                pos = pos + 1
                t[k] = value()
                skip()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                if d ~= "," then err("expected ',' or '}'") end
            end
        elseif c == "[" then
            local t = {}
            pos = pos + 1; skip()
            if str:sub(pos, pos) == "]" then pos = pos + 1; return t end
            while true do
                t[#t + 1] = value()
                skip()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return t end
                if d ~= "," then err("expected ',' or ']'") end
            end
        elseif c == '"' then return string_()
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        elseif c:find("[-%d]") then return number()
        end
        err("unexpected '" .. c .. "'")
    end
    local v = value()
    skip()
    if pos <= #str then err("trailing data") end
    return v
end

local function fail(what, e) S.errors[#S.errors + 1] = what .. ": " .. tostring(e) end

-- ---------- load ----------
function S.load()
    S.errors = {}
    local f = io.open(S.path, "r")
    if not f then S.data = {}; S.loaded = true; return true end      -- nothing changed yet
    local text = f:read("a"); f:close()
    local ok, data = pcall(decode, text)
    if not ok then fail("load", data); S.loaded = true; return false end
    S.data = type(data) == "table" and data or {}
    S.loaded = true
    return true
end

-- ---------- options ----------
-- "general:col.active_border" -> { general = { col = { active_border = value } } }
local function nested(name, value)
    local path = {}
    for seg in name:gmatch("[^:%.]+") do path[#path + 1] = (seg:gsub("%-", "_")) end
    local root, cur = {}, nil
    cur = root
    for i = 1, #path - 1 do cur[path[i]] = {}; cur = cur[path[i]] end
    cur[path[#path]] = value
    return root
end

function S.apply_options(only)
    for name, v in pairs(S.data.options or {}) do
        if not only or only == name then
            local ok, e = pcall(hl.config, nested(name, v))
            if not ok then fail(name, e) end
        end
    end
end

-- ---------- monitors ----------
-- conf/monitors.lua merges S.monitor(name) between its base values and the bar's live changes,
-- so a reload applies everything in one go. Outputs it does not know get hl.monitor directly.
function S.monitor(name) return (S.data.monitors or {})[name] end

function S.apply_monitors(only, skip_known)
    for name, spec in pairs(S.data.monitors or {}) do
        local known = BArch.monitors and BArch.monitors[name] and BArch.apply_monitor
        if (not only or only == name) and not (known and skip_known) then
            local ok, e
            if known then
                ok, e = pcall(BArch.apply_monitor, name)
            else
                local t = { output = name }
                for k, v in pairs(spec) do t[k] = v end
                ok, e = pcall(hl.monitor, t)
            end
            if not ok then fail("monitor " .. name, e) end
        end
    end
end

-- ---------- animations and curves ----------
function S.apply_animations()
    for name, c in pairs(S.data.curves or {}) do
        local ok, e = pcall(hl.curve, name, c)
        if not ok then fail("curve " .. name, e) end
    end
    for leaf, a in pairs(S.data.animations or {}) do
        local t = { leaf = leaf }
        for k, v in pairs(a) do t[k] = v end
        local ok, e = pcall(hl.animation, t)
        if not ok then fail("animation " .. leaf, e) end
    end
end

-- ---------- binds ----------
local bind_flags = { "repeating", "locked", "release", "non_consuming", "transparent", "ignore_mods",
                     "dont_inhibit", "long_press", "submap_universal", "click", "drag", "mouse", "allow_input_capture" }

local function dispatcher_of(b)
    if b.command and b.command ~= "" then return hl.dsp.exec_cmd(b.command) end
    if b.lua and b.lua ~= "" then
        local fn, e = load("return " .. b.lua, "bind " .. tostring(b.keys), "t", _ENV)
        if not fn then error(e, 0) end
        return fn()
    end
    error("no command or dispatcher", 0)
end

function S.apply_binds()
    for _, keys in ipairs(S.data.unbinds or {}) do
        local ok, e = pcall(hl.unbind, keys)
        if not ok then fail("unbind " .. keys, e) end
    end
    for _, b in ipairs(S.data.binds or {}) do
        if b.enabled ~= false then
            local ok, e = pcall(function()
                local opts = { description = b.description }
                for _, f in ipairs(bind_flags) do if b[f] then opts[f] = true end end
                hl.bind(b.keys, dispatcher_of(b), opts)
            end)
            if not ok then fail("bind " .. tostring(b.keys), e) end
        end
    end
end

-- ---------- the rest: once per (re)load ----------
function S.apply_rules()
    for _, r in ipairs(S.data.window_rules or {}) do
        local ok, e = pcall(hl.window_rule, r)
        if not ok then fail("window rule " .. tostring(r.name), e) end
    end
    for _, r in ipairs(S.data.layer_rules or {}) do
        local ok, e = pcall(hl.layer_rule, r)
        if not ok then fail("layer rule " .. tostring(r.name), e) end
    end
    for _, r in ipairs(S.data.workspace_rules or {}) do
        local ok, e = pcall(hl.workspace_rule, r)
        if not ok then fail("workspace rule " .. tostring(r.workspace), e) end
    end
end

function S.apply_devices()
    for name, spec in pairs(S.data.devices or {}) do
        local t = { name = name }
        for k, v in pairs(spec) do t[k] = v end
        local ok, e = pcall(hl.device, t)
        if not ok then fail("device " .. name, e) end
    end
end

function S.apply_gestures()
    for _, g in ipairs(S.data.gestures or {}) do
        local ok, e = pcall(hl.gesture, g)
        if not ok then fail("gesture", e) end
    end
end

function S.apply_env()
    for k, v in pairs(S.data.env or {}) do
        local ok, e = pcall(hl.env, k, tostring(v))
        if not ok then fail("env " .. k, e) end
    end
end

function S.apply(what, arg)
    S.load()
    what = what or "all"
    if what == "options" or what == "all" then S.apply_options(arg) end
    if what == "monitors" then S.apply_monitors(arg) end
    if what == "all" then S.apply_monitors(nil, true) end   -- conf/monitors.lua already merged the known ones
    if what == "animations" or what == "all" then S.apply_animations() end
    if what == "devices" or what == "all" then S.apply_devices() end
    if what == "all" then
        S.apply_env()
        S.apply_binds()
        S.apply_rules()
        S.apply_gestures()
    end
    return #S.errors == 0
end

-- what `hyprctl eval` can read back (it only prints errors, so the answer travels in one)
function S.report()
    error(("settings: %d option(s), %d error(s)%s"):format(
        (function() local n = 0 for _ in pairs(S.data.options or {}) do n = n + 1 end return n end)(),
        #S.errors, #S.errors > 0 and ("\n" .. table.concat(S.errors, "\n")) or ""), 0)
end

-- hyprland.lua requires this first (so conf/monitors.lua sees the data) and calls
-- BArch.settings.apply("all") after the other files.
S.load()

-- commands of the app's "Startup" page: once per session, like conf/autostart.lua
hl.on("hyprland.start", function()
    for _, cmd in ipairs(S.data.exec or {}) do hl.exec_cmd(cmd) end
end)
