// Store.qml — everything the settings app knows and does.
//
// Reads: `hyprctl descriptions` (every option of the running version, with type, default and
// current value), monitors, binds, animations, devices, config errors, the Lua stubs Hyprland
// ships (exact type of each option), the hand-written conf/*.lua (display only) and
// ~/.config/hypr/settings.json (what this app saved).
// Writes: only settings.json. Live changes go through `hyprctl eval` into conf/settings.lua
// (BArch.settings.apply), the rest through `hyprctl reload`.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "hypr.js" as H

Singleton {
    id: store

    readonly property string home: Quickshell.env("HOME")
    readonly property string hyprDir: home + "/.config/hypr"
    readonly property string settingsPath: hyprDir + "/settings.json"
    readonly property string stubPath: "/usr/share/hypr/stubs/hl.meta.lua"

    // ---------- data ----------
    property var settings: ({})
    property var stubTypes: ({})
    property var descriptions: []
    property var options: []            // [{ name, section, group, key, desc, kind, def, min, max, map, choices, themed, index }]
    property var byName: ({})
    property var current: ({})          // name -> value as hyprctl prints it
    property var sections: []           // [{ id, label, count }]
    property var monitors: []
    property var binds: []
    property var animations: []
    property var curves: []
    property var devices: ({})
    property var files: ({})            // path -> text
    property string version: ""
    property string configErrors: ""
    property string applyErrors: ""
    property string status: ""
    property bool statusBad: false
    property bool busy: false
    property bool ready: false
    property bool restartNeeded: false  // env changed

    readonly property var overrides: settings.options || ({})
    readonly property int overrideCount: Object.keys(overrides).length
    readonly property var fileNames: Object.keys(files).sort()

    function say(msg, bad) { status = msg; statusBad = !!bad }
    function clone(v) { return JSON.parse(JSON.stringify(v)) }
    function shortPath(p) { return String(p).replace(hyprDir + "/", "") }

    // ---------- settings.json ----------
    property string lastWritten: ""
    FileView {
        id: settingsFile
        path: store.settingsPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: store.readSettings()
    }
    function readSettings() {
        let text = ""
        try { text = settingsFile.text() } catch (e) { return }
        if (text === lastWritten) return
        try { settings = text.trim() === "" ? {} : JSON.parse(text) } catch (e) { say("settings.json cannot be read: " + e, true) }
    }
    function save() {
        const text = JSON.stringify(settings, null, 2) + "\n"
        lastWritten = text
        settingsFile.setText(text)
    }
    function edit(fn) {
        const s = clone(settings)
        fn(s)
        settings = s
        save()
    }

    // ---------- hyprctl ----------
    component Cmd: Process {
        property var handler: null
        stdout: StdioCollector { onStreamFinished: if (handler) handler(text) }
    }
    Cmd {
        id: descProc
        command: ["hyprctl", "-j", "descriptions"]
        handler: t => { try { store.descriptions = JSON.parse(t); store.buildOptions() } catch (e) { store.say("hyprctl descriptions failed: " + e, true) } }
    }
    Cmd {
        id: monProc
        command: ["hyprctl", "-j", "monitors", "all"]
        handler: t => { try { store.monitors = JSON.parse(t) } catch (e) {} }
    }
    Cmd {
        id: bindsProc
        command: ["hyprctl", "-j", "binds"]
        handler: t => { try { store.binds = JSON.parse(t) } catch (e) {} }
    }
    Cmd {
        id: animProc
        command: ["hyprctl", "-j", "animations"]
        handler: t => { try { const a = JSON.parse(t); store.animations = a[0] || []; store.curves = a[1] || [] } catch (e) {} }
    }
    Cmd {
        id: devProc
        command: ["hyprctl", "-j", "devices"]
        handler: t => { try { store.devices = JSON.parse(t) } catch (e) {} }
    }
    Cmd {
        id: verProc
        command: ["hyprctl", "-j", "version"]
        handler: t => { try { const v = JSON.parse(t); store.version = v.tag || v.version || "" } catch (e) {} }
    }
    Cmd {
        id: errProc
        command: ["hyprctl", "configerrors"]
        handler: t => store.configErrors = t.trim()
    }
    Cmd {
        id: reportProc
        command: ["sh", "-c", "hyprctl eval 'BArch.settings.report()' 2>&1"]
        handler: t => {
            const m = /settings: (\d+) option\(s\), (\d+) error\(s\)\n?([\s\S]*)/.exec(t)
            store.applyErrors = m && Number(m[2]) > 0 ? m[3].trim() : (/attempt to index/.test(t) ? "conf/settings.lua is not loaded (hyprland.lua must require it)" : "")
        }
    }
    Cmd {
        id: stubProc
        command: ["cat", store.stubPath]
        handler: t => { store.stubTypes = H.parseStubTypes(t); if (store.descriptions.length) store.buildOptions() }
    }
    Cmd {
        id: filesProc
        command: ["sh", "-c", 'for f in $(find "$1/" -name "*.lua" -not -type l -not -path "*/.git/*" | sort); do printf "\\n\\001%s\\n" "$f"; cat "$f"; done', "sh", store.hyprDir]
        handler: t => {
            const out = {}
            const parts = t.split("\u0001")
            for (let i = 1; i < parts.length; i++) {
                const nl = parts[i].indexOf("\n")
                out[parts[i].slice(0, nl)] = parts[i].slice(nl + 1)
            }
            store.files = out
        }
    }

    function refreshValues() { descProc.running = true; animProc.running = true; monProc.running = true; reportProc.running = true }
    function refreshAll() {
        refreshValues()
        bindsProc.running = true; devProc.running = true; verProc.running = true; errProc.running = true
        filesProc.running = true
        settingsFile.reload()
    }
    Component.onCompleted: { stubProc.running = true; refreshAll() }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded") { store.busy = false; store.refreshAll(); store.say("reloaded") }
            else if (event.name === "monitoradded" || event.name === "monitorremoved") monProc.running = true
        }
    }

    // ---------- the option model ----------
    property string optionNames: ""
    function buildOptions() {
        const opts = [], names = {}, cur = {}, counts = {}
        for (let i = 0; i < descriptions.length; i++) {
            const o = descriptions[i]
            const kind = H.kindOf(o, stubTypes[H.stubKey(o.name)])
            const parts = o.name.split(":")
            const section = parts[0]
            opts.push({
                name: o.name, section: section, key: parts[parts.length - 1],
                group: parts.slice(1, -1).join(" › "),
                desc: o.description || "", kind: kind, def: o["default"],
                min: o.min, max: o.max, map: H.mapEntries(o.map), choices: kind === "string" ? H.choicesOf(o.description) : [],
                themed: !!H.THEMED[o.name], index: i
            })
            names[o.name] = opts[opts.length - 1]
            cur[o.name] = o.current
            counts[section] = (counts[section] || 0) + 1
        }
        const order = {}
        H.SECTIONS.forEach((s, i) => order[s.id] = i)
        const rank = s => s in order ? order[s] : 1000
        opts.sort((a, b) => {
            if (a.section !== b.section) return rank(a.section) - rank(b.section) || a.section.localeCompare(b.section)
            if (a.group !== b.group) return a.group === "" ? -1 : b.group === "" ? 1 : a.group.localeCompare(b.group)
            return a.index - b.index
        })
        const key = Object.keys(names).join("|") + "/" + Object.keys(stubTypes).length
        current = cur
        if (key !== optionNames) {
            optionNames = key
            options = opts
            byName = names
            const secs = []
            for (const s of H.SECTIONS) if (counts[s.id]) secs.push({ id: s.id, label: s.label, count: counts[s.id] })
            for (const id in counts) if (!H.SECTIONS.some(s => s.id === id)) secs.push({ id: id, label: H.sectionLabel(id), count: counts[id] })
            sections = secs
        }
        ready = true
    }
    function isDefault(name) {
        const o = byName[name]
        if (!o) return true
        return JSON.stringify(current[name]) === JSON.stringify(o.def)
    }

    // ---------- live apply (hyprctl eval, one at a time; the newest request wins while one runs) ----------
    property var evalQueue: ({})
    Process {
        id: evalProc
        property string key: ""
        stdout: StdioCollector { onStreamFinished: if (/^error/i.test(text.trim())) store.say(text.trim(), true) }
        stderr: StdioCollector { onStreamFinished: if (text.trim() !== "") store.say(text.trim(), true) }
        onExited: {
            store.refreshValues()
            store.pump()
        }
    }
    function pump() {
        if (evalProc.running) return
        const keys = Object.keys(evalQueue)
        if (keys.length === 0) return
        const code = evalQueue[keys[0]]
        const q = Object.assign({}, evalQueue); delete q[keys[0]]; evalQueue = q
        evalProc.command = ["hyprctl", "eval", code]
        evalProc.running = true
    }
    function evalLua(key, code) {
        const q = Object.assign({}, evalQueue); q[key] = code; evalQueue = q
        pump()
    }
    function applyLive(what, arg) {
        evalLua(what + ":" + (arg || ""), 'BArch.settings.apply("' + what + '"' + (arg ? ', "' + arg + '"' : "") + ')')
    }

    Process { id: reloadProc; command: ["hyprctl", "reload"] }
    function reload() { busy = true; say("reloading…"); reloadProc.running = true; reloadFallback.restart() }
    Timer { id: reloadFallback; interval: 2500; onTriggered: if (store.busy) { store.busy = false; store.refreshAll() } }

    // ---------- options ----------
    function setOption(name, value) {
        edit(s => { s.options = s.options || {}; s.options[name] = value })
        const o = byName[name]
        if (o && ["bool", "int", "float", "string"].indexOf(o.kind) !== -1) { const c = Object.assign({}, current); c[name] = value; current = c }
        applyLive("options", name)
        say(name + " = " + H.valueText(o ? o.kind : "string", value))
    }
    function resetOption(name) {
        if (!(name in overrides)) return
        edit(s => { delete s.options[name]; if (Object.keys(s.options).length === 0) delete s.options })
        say(name + ": back to the files")
        reload()
    }
    function resetAllOptions() {
        edit(s => { delete s.options })
        reload()
    }

    // ---------- monitors ----------
    function monitorSettings(name) { return (settings.monitors || {})[name] || {} }
    function setMonitor(name, field, value) {
        edit(s => { s.monitors = s.monitors || {}; s.monitors[name] = s.monitors[name] || {}; s.monitors[name][field] = value })
        applyLive("monitors", name)
        say(name + ": " + field + " = " + value)
    }
    function resetMonitorField(name, field) {
        edit(s => { if (s.monitors && s.monitors[name]) { delete s.monitors[name][field]; if (Object.keys(s.monitors[name]).length === 0) delete s.monitors[name] } })
        reload()
    }
    function resetMonitor(name) {
        edit(s => { if (s.monitors) delete s.monitors[name] })
        reload()
    }

    // ---------- animations ----------
    function animationSettings(leaf) { return (settings.animations || {})[leaf] }
    function setAnimation(leaf, obj) {
        edit(s => { s.animations = s.animations || {}; s.animations[leaf] = obj })
        applyLive("animations")
        say("animation " + leaf + " updated")
    }
    function resetAnimation(leaf) {
        edit(s => { if (s.animations) { delete s.animations[leaf]; if (Object.keys(s.animations).length === 0) delete s.animations } })
        reload()
    }
    function setCurve(name, obj) {
        edit(s => { s.curves = s.curves || {}; s.curves[name] = obj })
        applyLive("animations")
        say("curve " + name + " updated")
    }
    function removeCurve(name) {
        edit(s => { if (s.curves) { delete s.curves[name]; if (Object.keys(s.curves).length === 0) delete s.curves } })
        reload()
    }
    readonly property var curveNames: {
        const names = {}
        for (const c of curves) names[c.name] = true
        for (const p in files) for (const n of H.parseCurveNames(files[p])) names[n] = true
        for (const n in (settings.curves || {})) names[n] = true
        return Object.keys(names).sort()
    }

    // ---------- binds ----------
    readonly property var ownBinds: settings.binds || []
    readonly property var unbinds: settings.unbinds || []
    function setBinds(list) { edit(s => { if (list.length) s.binds = list; else delete s.binds }); reload() }
    function setUnbinds(list) { edit(s => { if (list.length) s.unbinds = list; else delete s.unbinds }); reload() }

    // ---------- rules, gestures, env, exec, devices ----------
    function setList(key, list) { edit(s => { if (list && list.length) s[key] = list; else delete s[key] }); reload() }
    function setEnv(map) {
        edit(s => { if (Object.keys(map).length) s.env = map; else delete s.env })
        restartNeeded = true
        say("environment saved: applies at the next Hyprland start")
    }
    function setExec(list) { edit(s => { if (list.length) s.exec = list; else delete s.exec }); say("startup commands saved: they run at the next session start") }
    function runNow(cmd) { Quickshell.execDetached(["sh", "-c", cmd]); say("ran: " + cmd) }
    function deviceSettings(name) { return (settings.devices || {})[name] || {} }
    function setDevice(name, field, value) {
        edit(s => { s.devices = s.devices || {}; s.devices[name] = s.devices[name] || {}; s.devices[name][field] = value })
        applyLive("devices")
        say(name + ": " + field + " = " + value)
    }
    function resetDeviceField(name, field) {
        edit(s => { if (s.devices && s.devices[name]) { delete s.devices[name][field]; if (Object.keys(s.devices[name]).length === 0) delete s.devices[name]; if (Object.keys(s.devices).length === 0) delete s.devices } })
        reload()
    }

    // ---------- hypridle.conf and hyprsunset.conf (hyprlang; edited in place, blocks and comments kept) ----------
    readonly property string idlePath: hyprDir + "/hypridle.conf"
    readonly property string sunsetPath: hyprDir + "/hyprsunset.conf"
    property var idleItems: []
    property var sunsetItems: []
    property string idleWritten: ""
    property string sunsetWritten: ""
    FileView {
        id: idleFile
        path: store.idlePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { const t = text(); if (t !== store.idleWritten) store.idleItems = H.parseHyprlang(t) }
    }
    FileView {
        id: sunsetFile
        path: store.sunsetPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { const t = text(); if (t !== store.sunsetWritten) store.sunsetItems = H.parseHyprlang(t) }
    }
    function saveIdle(items) {
        idleItems = items
        idleWritten = H.writeHyprlang(items) + "\n"
        idleFile.setText(idleWritten)
        restartIdle()
    }
    function saveSunset(items) {
        sunsetItems = items
        sunsetWritten = H.writeHyprlang(items) + "\n"
        sunsetFile.setText(sunsetWritten)
        restartSunset()
    }
    // hypridle is started by conf/autostart.lua (not a unit) and does not re-read its file
    function restartIdle() {
        Quickshell.execDetached(["sh", "-c", "pkill -x hypridle; sleep 0.3; exec uwsm app -- hypridle"])
        say("hypridle.conf saved; hypridle restarted")
    }
    function restartSunset() {
        Quickshell.execDetached(["systemctl", "--user", "restart", "hyprsunset.service"])
        say("hyprsunset.conf saved; hyprsunset restarted")
    }

    // ---------- files ----------
    function openFile(path) {
        Quickshell.execDetached(["sh", "-c", 'exec uwsm app -- foot -e "${EDITOR:-nvim}" "$1"', "sh", path])
    }
    function optionSource(name) { return H.findOptionSource(files, name) }
}
