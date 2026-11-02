// Store.qml — what pacman knows: every installed package (pacman -Qi), the explicit ones, the
// foreign (AUR) ones, orphans, pending updates, .pacnew files, the pacman log, and the lists the
// repo keeps (packages/*.txt). Removing goes through pkexec (polkit asks the password) and then
// scripts/update-packages.sh, so the repo lists follow.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string home: Quickshell.env("HOME")
    property string repo: ""              // ~/BArch, resolved physically (the shell dir is reached through a symlink)
    readonly property string barch: home + "/.local/bin/barch"

    property var packages: ({})          // name -> { name, version, description, size, sizeText, date, reason, requiredBy, dependsOn, url, groups, foreign }
    property var explicitNames: []
    property var foreignNames: []
    property var orphans: []
    property var updates: []             // [{ name, from, to, aur }]
    property var pacnew: []
    property var history: []             // [{ time, action, name, version }]
    property var lists: ({ pacman: [], aur: [], ignore: [] })
    property string status: ""
    property bool statusBad: false
    property bool ready: false
    property bool checking: false
    property string detailName: ""
    property string detailText: ""
    property string detailFiles: ""

    readonly property var all: Object.keys(packages).sort().map(n => packages[n])
    readonly property var unsaved: {
        // explicit packages not in the repo lists yet, and listed ones no longer installed
        const inst = explicitNames.filter(n => foreignNames.indexOf(n) === -1), aur = explicitNames.filter(n => foreignNames.indexOf(n) !== -1)
        const ign = lists.ignore
        return {
            newRepo: inst.filter(n => lists.pacman.indexOf(n) === -1),
            goneRepo: lists.pacman.filter(n => inst.indexOf(n) === -1),
            newAur: aur.filter(n => lists.aur.indexOf(n) === -1 && ign.indexOf(n) === -1),
            goneAur: lists.aur.filter(n => aur.indexOf(n) === -1)
        }
    }
    readonly property int unsavedCount: unsaved.newRepo.length + unsaved.goneRepo.length + unsaved.newAur.length + unsaved.goneAur.length

    function say(msg, bad) { status = msg; statusBad = !!bad }
    function human(mib) { return mib >= 1024 ? (mib / 1024).toFixed(2) + " GiB" : mib >= 1 ? mib.toFixed(1) + " MiB" : (mib * 1024).toFixed(0) + " KiB" }

    Component {
        id: procComp
        Process {
            id: p
            property var cb: null
            property string out: ""
            property string err: ""
            stdout: StdioCollector { onStreamFinished: p.out = text }
            stderr: StdioCollector { onStreamFinished: p.err = text }
            onExited: (code, status) => { if (cb) cb(out, err, code); p.destroy() }
        }
    }
    function run(cmd, cb) { const p = procComp.createObject(store, { command: cmd, cb: cb }); p.running = true; return p }

    // ---------- pacman -Qi ----------
    function parseQi(text, foreign) {
        const out = {}
        for (const block of text.split("\n\n")) {
            const p = {}
            let lastKey = ""
            for (const line of block.split("\n")) {
                const m = /^([A-Za-z ]+?)\s*:\s?(.*)$/.exec(line)
                if (m && !/^\s/.test(line)) { lastKey = m[1]; p[lastKey] = m[2] }
                else if (lastKey && /^\s{2,}/.test(line)) p[lastKey] += "\n" + line.trim()
            }
            if (!p.Name) continue
            const sz = /([\d.]+)\s*(KiB|MiB|GiB|B)/.exec(p["Installed Size"] || "")
            const mib = sz ? Number(sz[1]) * (sz[2] === "GiB" ? 1024 : sz[2] === "MiB" ? 1 : sz[2] === "KiB" ? 1 / 1024 : 1 / 1048576) : 0
            const list = s => (s || "None").trim() === "None" ? [] : s.trim().split(/\s{2,}|\n/).filter(x => x)
            out[p.Name] = {
                name: p.Name, version: p.Version || "", description: p.Description || "", url: p.URL || "",
                size: mib, sizeText: p["Installed Size"] || "", date: p["Install Date"] || "",
                explicit: /Explicitly/.test(p["Install Reason"] || ""), requiredBy: list(p["Required By"]), dependsOn: list(p["Depends On"]),
                optionalFor: list(p["Optional For"]), groups: list(p.Groups), foreign: foreign.indexOf(p.Name) !== -1
            }
        }
        return out
    }
    function refreshPackages() {
        run(["sh", "-c", 'pacman -Qqm; printf "\\001"; pacman -Qqe; printf "\\001"; pacman -Qdtq; printf "\\001"; LC_ALL=C pacman -Qi'], out => {
            const parts = out.split("\u0001")
            const foreign = parts[0].split("\n").filter(x => x)
            foreignNames = foreign
            explicitNames = parts[1].split("\n").filter(x => x)
            orphans = parts[2].split("\n").filter(x => x)
            packages = parseQi(parts[3] || "", foreign)
            ready = true
        })
    }
    function refreshLists() {
        run(["sh", "-c", 'cd "$1" && cat packages/pacman.txt; printf "\\001"; cat packages/aur.txt; printf "\\001"; cat packages/aur-ignore.txt', "sh", repo], out => {
            const parts = out.split("\u0001")
            const ls = s => (s || "").split("\n").map(x => x.trim()).filter(x => x && !x.startsWith("#"))
            lists = { pacman: ls(parts[0]), aur: ls(parts[1]), ignore: ls(parts[2]) }
        })
    }
    function refreshUpdates() {
        checking = true
        run(["sh", "-c", 'checkupdates 2>/dev/null; printf "\\001"; paru -Qua 2>/dev/null; printf "\\001"; pacdiff -o 2>/dev/null'], out => {
            checking = false
            const parts = out.split("\u0001")
            const parse = (s, aur) => (s || "").split("\n").map(l => /^(\S+)\s+(\S+)\s+->\s+(\S+)/.exec(l)).filter(m => m).map(m => ({ name: m[1], from: m[2], to: m[3], aur: aur }))
            updates = parse(parts[0], false).concat(parse(parts[1], true))
            pacnew = (parts[2] || "").split("\n").filter(x => x.trim())
        })
    }
    function refreshHistory() {
        run(["sh", "-c", 'grep -E "\\[ALPM\\] (installed|upgraded|removed|reinstalled|downgraded) " /var/log/pacman.log | tail -n 3000'], out => {
            const list = []
            for (const line of out.split("\n")) {
                const m = /^\[([^\]]+)\] \[ALPM\] (\w+) (\S+) \((.*)\)$/.exec(line)
                if (m) list.push({ time: m[1].slice(0, 16).replace("T", " "), action: m[2], name: m[3], version: m[4] })
            }
            history = list.reverse()
        })
    }
    function refreshAll() { refreshPackages(); refreshLists(); refreshUpdates(); refreshHistory() }
    Component.onCompleted: run(["readlink", "-f", Quickshell.shellDir + "/../../../.."], out => { repo = out.trim(); refreshAll() })

    // ---------- details ----------
    function showDetails(name) {
        detailName = name; detailText = "loading…"; detailFiles = ""
        run(["sh", "-c", 'LC_ALL=C pacman -Qi "$1"; printf "\\001"; pacman -Qlq "$1" | head -n 400', "sh", name], out => {
            const parts = out.split("\u0001")
            detailText = (parts[0] || "").trim()
            detailFiles = (parts[1] || "").trim()
        })
    }

    // ---------- actions (root through polkit) ----------
    function removePlan(names, cb) {
        run(["pacman", "-Rsp", "--print-format", "%n %v"].concat(names), (out, err, code) => cb(code === 0 ? out.trim().split("\n").filter(x => x) : null, err.trim()))
    }
    function remove(names) {
        say("removing " + names.join(", ") + "…")
        run(["pkexec", "pacman", "-Rns", "--noconfirm"].concat(names), (out, err, code) => {
            if (code !== 0) { say("remove failed: " + (err.trim().split("\n").pop() || "exit " + code), true); refreshPackages(); return }
            say("removed " + names.join(", ") + "; updating the repo lists…")
            updateLists()
            refreshPackages(); refreshHistory()
        })
    }
    function markExplicit(name, explicit) {
        run(["pkexec", "pacman", "-D", explicit ? "--asexplicit" : "--asdeps", name], (out, err, code) => {
            say(code === 0 ? name + " marked as " + (explicit ? "explicitly installed" : "a dependency") : "failed: " + err.trim(), code !== 0)
            refreshPackages(); updateLists()
        })
    }
    function updateLists() {
        run(["bash", repo + "/scripts/update-packages.sh"], (out, err, code) => { refreshLists(); if (code !== 0) say("update-packages.sh failed: " + err.trim(), true); else say("packages/*.txt updated (save with sync.sh)") })
    }
    function terminal(title, cmd) {
        Quickshell.execDetached(["setsid", "-f", "foot", "-T", title, "-e", "sh", "-c", cmd + '; echo; printf "\\n[Enter to close] "; read -r _'])
    }
    function install(spec) { terminal("paru -S " + spec, "paru -S " + spec + " && " + barch + " --json health >/dev/null; bash " + repo + "/scripts/update-packages.sh") }
    function updateAll() {
        Quickshell.execDetached(["setsid", "-f", "foot", "-T", "Update All", "-e", "bash", home + "/.config/quickshell/updates/run-update.sh", "all", home + "/.local/bin/kernel-update", "0"])
        say("Update All running in a terminal (news, AUR review, paru -Syu)")
    }
    function pacdiff() { terminal("pacdiff", "sudo pacdiff") }
    function openUrl(u) { if (u) Quickshell.execDetached(["xdg-open", u]) }
}
