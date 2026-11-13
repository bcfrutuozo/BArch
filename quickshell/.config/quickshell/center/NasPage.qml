pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the NAS as agent/nas.py sees it (Unraid's API, read only): what `barch --json nas status` answers,
// asked every minute while the window is open, and the nas.* metrics barch-events keeps
Item {
    id: page
    readonly property var s: Store.nas
    readonly property bool configured: s.configured !== false
    readonly property bool up: s.reachable === true
    readonly property var problems: s.problems || []
    readonly property var disks: s.disks || []
    readonly property var c: s.containers || ({ total: 0, running: 0, down: [], updates: [] })
    readonly property var certs: s.certs || []
    readonly property var alerts: s.alerts || []
    readonly property var arr: s.array || ({})
    readonly property var par: s.parity || ({})
    readonly property var badDisks: disks.filter(d => !d.ok)
    readonly property var pools: disks.filter(d => d.kind === "pool")
    readonly property var nextCert: certs.filter(x => x.days !== null).sort((a, b) => a.days - b.days)[0] || null
    readonly property var refused: certs.filter(x => x.error && x.error !== "unreachable")

    property string range: "24h"
    readonly property var ranges: ["24h", "7d", "30d"]
    function spanOf(r) { return parseInt(r) * (r.slice(-1) === "d" ? 86400 : 3600) }
    readonly property var seriesColors: [Ui.accent, Ui.green, Ui.yellow]

    function tb(gb) { return gb === undefined || gb === null ? "—" : (gb / 1000).toFixed(1) + " TB" }
    function pctTint(p) { return p === null || p === undefined ? Ui.subtext : p > 85 ? Ui.red : p > 70 ? Ui.yellow : Ui.green }
    function certTint(x) { return x.error && x.error !== "unreachable" ? Ui.red : x.days === null ? Ui.subtext : x.days < 3 ? Ui.red : x.days < 10 ? Ui.yellow : Ui.green }
    function problemWord(p) { return p === "crashed" ? Ui.red : Ui.yellow }

    component Tile: Rectangle {
        property string label: ""
        property string value: ""
        property string sub: ""
        property color tint: Ui.text
        width: 196; height: 72; radius: Ui.radius
        color: Ui.sunken; border.width: 1; border.color: Ui.surface
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 10; spacing: 1
            Text { text: parent.parent.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            Text { text: parent.parent.value; color: parent.parent.tint; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
            Text { text: parent.parent.sub; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight; Layout.fillWidth: true }
        }
    }

    // a card with a chart of some nas.* metrics in the page's range (as the History page draws them)
    component NasChart: Card {
        id: mc
        property var metrics: []
        property var labels: []
        property string unit: ""
        property real fixedMin: NaN
        property real fixedMax: NaN
        property var series: []
        property int pending: 0
        property real axisFrom: NaN
        property real axisTo: NaN
        property int generation: 0
        Layout.alignment: Qt.AlignTop
        function load() {
            const mine = ++generation
            const out = new Array(metrics.length)
            const to = Date.now() / 1000, from = to - page.spanOf(page.range)
            let left = metrics.length
            pending = left
            metrics.forEach((m, i) => Store.series(m, page.range, d => {
                if (mine !== generation) return
                out[i] = { label: labels[i] || m, color: page.seriesColors[i % page.seriesColors.length], points: d.points || [] }
                pending = --left
                if (left === 0) { axisFrom = from; axisTo = to; series = out }
            }))
        }
        Component.onCompleted: load()
        Connections { target: page; function onRangeChanged() { mc.load() } }
        Connections { target: Store; function onNasChanged() { if (mc.pending === 0) mc.load() } }
        Chart { Layout.fillWidth: true; series: mc.series; unit: mc.unit; fixedMin: mc.fixedMin; fixedMax: mc.fixedMax; from: mc.axisFrom; to: mc.axisTo }
        RowLayout {
            spacing: 14
            visible: mc.series.length > 1
            Repeater {
                model: mc.series
                RowLayout {
                    required property var modelData
                    spacing: 5
                    Rectangle { width: 10; height: 3; radius: 1; color: parent.modelData.color }
                    Text { text: parent.modelData.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
                }
            }
        }
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12

            // ---------- at a glance ----------
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: !page.configured ? "NAS  ·  not set up"
                     : !page.up ? "NAS  ·  " + (Store.nasAt ? "not answering" : "asking…")
                     : (page.s.host || "NAS") + "  ·  " + (page.problems.length === 0 ? "ok" : page.problems.length + " problem" + (page.problems.length === 1 ? "" : "s"))
                subtitle: !page.configured ? "run `barch nas setup`: it writes ~/.config/barch/nas.json with the URL and API key of Homepage's Unraid widget"
                        : !page.up ? String(page.s.error || "")
                        : "Unraid " + page.s.version + "  ·  up since " + String(page.s.up_since || "").slice(0, 10) + "  ·  asked " + Store.ago(Store.nasAt)
                          + (Store.nasBusy ? "  ·  asking…" : "")
                headerItems: [ UiButton { label: "Refresh"; icon: "󰑐"; small: true; tooltip: "ask Unraid again, certificates included"; onClicked: Store.refreshNas(true) } ]
                Flow {
                    Layout.fillWidth: true
                    spacing: 10
                    visible: page.up
                    Tile {
                        label: "Array"
                        value: page.arr.state === "STARTED" ? page.arr.pct + "% used" : String(page.arr.state || "—")
                        sub: page.tb(page.arr.free_gb) + " free of " + page.tb(page.arr.total_gb)
                        tint: page.arr.state !== "STARTED" ? Ui.red : page.pctTint(page.arr.pct)
                    }
                    Tile {
                        label: "Parity check"
                        value: page.par.running ? "running  " + page.par.progress + "%" : String(page.par.status || "—").toLowerCase()
                        sub: String(page.par.date || "").slice(0, 10) + "  ·  " + (page.par.errors || 0) + " errors"
                        tint: page.par.errors > 0 || page.par.status === "FAILED" ? Ui.red : Ui.green
                    }
                    Tile {
                        label: "Disks"
                        value: page.badDisks.length ? page.badDisks.length + " with a problem" : page.disks.length + " ok"
                        sub: page.s.disk_temp !== null && page.s.disk_temp !== undefined ? "hottest " + page.s.disk_temp + " °C" : "all spun down"
                        tint: page.badDisks.length ? Ui.red : page.s.disk_temp > 50 ? Ui.yellow : Ui.green
                    }
                    Tile {
                        label: "Pools"
                        value: page.s.pool_pct !== null && page.s.pool_pct !== undefined ? "fullest " + page.s.pool_pct + "%" : "—"
                        sub: page.pools.map(d => d.name + " " + d.pct + "%").join("  ·  ")
                        tint: page.pctTint(page.s.pool_pct)
                    }
                    Tile {
                        label: "Containers"
                        value: page.c.running + " of " + page.c.total + " running"
                        sub: page.c.down.length ? page.c.down.length + " down" : page.c.updates.length ? page.c.updates.length + " with an update" : "none down"
                        tint: page.c.down.length ? Ui.red : Ui.green
                    }
                    Tile {
                        label: "Unraid notifications"
                        value: page.alerts.length ? page.alerts.length + " unread" : "none unread"
                        sub: page.alerts.length ? String(page.alerts[0].subject || page.alerts[0].title) : "warnings and alerts"
                        tint: page.alerts.some(a => a.importance === "ALERT") ? Ui.red : page.alerts.length ? Ui.yellow : Ui.green
                    }
                    Tile {
                        label: "Certificates"
                        value: page.refused.length ? page.refused.length + " refused" : page.nextCert ? "next in " + Math.floor(page.nextCert.days) + " d" : "—"
                        sub: page.nextCert ? String(page.nextCert.host).replace(/:443$/, "") : "checked on Refresh"
                        tint: page.refused.length ? Ui.red : page.nextCert ? page.certTint(page.nextCert) : Ui.subtext
                    }
                    Tile {
                        label: "Load"
                        value: "cpu " + Math.round(page.s.cpu_pct || 0) + "%"
                        sub: "ram " + Math.round(page.s.ram_pct || 0) + "%"
                    }
                }
                Repeater {
                    model: page.problems
                    Text { required property var modelData; Layout.fillWidth: true; text: "•  " + modelData; color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize; wrapMode: Text.Wrap }
                }
            }

            // ---------- disks ----------
            Card {
                visible: page.up
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Disks"
                subtitle: "parity, array and pools as Unraid reports them; a disk that is spun down has no temperature"
                Repeater {
                    model: page.disks
                    RowLayout {
                        id: dr
                        required property var modelData
                        spacing: 10
                        Rectangle { width: 8; height: 8; radius: 4; color: dr.modelData.ok ? Ui.green : Ui.red }
                        Text { Layout.preferredWidth: 130; text: dr.modelData.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.preferredWidth: 56; text: dr.modelData.kind; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.preferredWidth: 50; text: dr.modelData.device; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        Text {
                            Layout.preferredWidth: 110
                            text: String(dr.modelData.status).replace(/^DISK_/, "") + (dr.modelData.errors ? "  ·  " + dr.modelData.errors + " errors" : "")
                            color: dr.modelData.ok ? Ui.subtext : Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                        }
                        Text {
                            Layout.preferredWidth: 56
                            text: dr.modelData.temp === null || dr.modelData.temp === undefined ? "—" : dr.modelData.temp + " °C"
                            color: dr.modelData.temp > 50 ? Ui.red : dr.modelData.temp > 45 ? Ui.yellow : Ui.text
                            font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; horizontalAlignment: Text.AlignRight
                        }
                        Rectangle {
                            Layout.fillWidth: true; Layout.maximumWidth: 320
                            implicitHeight: 6; radius: 3; color: Ui.sunken
                            opacity: dr.modelData.pct === null ? 0 : 1
                            Rectangle { width: parent.width * Math.min(100, dr.modelData.pct || 0) / 100; height: parent.height; radius: 3; color: page.pctTint(dr.modelData.pct) === Ui.green ? Ui.accent : page.pctTint(dr.modelData.pct) }
                        }
                        Text { Layout.preferredWidth: 60; text: dr.modelData.pct === null ? "" : dr.modelData.pct + "%"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; horizontalAlignment: Text.AlignRight }
                        Item { Layout.fillWidth: true }
                    }
                }
            }

            // ---------- containers ----------
            Card {
                visible: page.up
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Containers"
                subtitle: page.c.down.length === 0 ? "all " + page.c.running + " running"
                        : "down: the ones Unraid starts by itself that are not running, any that exited with an error, restarts in a loop or reports unhealthy"
                Repeater {
                    model: page.c.down
                    RowLayout {
                        id: cr
                        required property var modelData
                        spacing: 10
                        Rectangle { width: 8; height: 8; radius: 4; color: page.problemWord(cr.modelData.problem) }
                        Text { Layout.preferredWidth: 240; text: cr.modelData.name; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Badge { text: cr.modelData.problem; tint: page.problemWord(cr.modelData.problem) }
                        Text { Layout.fillWidth: true; text: cr.modelData.status; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                    }
                }
                Text {
                    visible: page.c.updates.length > 0
                    Layout.fillWidth: true
                    text: "update available: " + page.c.updates.join(", ")
                    color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                }
            }

            // ---------- Unraid's own notifications ----------
            Card {
                visible: page.up && page.alerts.length > 0
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Unraid notifications"
                subtitle: "unread warnings and alerts; they clear when read or archived in Unraid"
                Repeater {
                    model: page.alerts
                    RowLayout {
                        id: ar
                        required property var modelData
                        spacing: 10
                        Badge { text: String(ar.modelData.importance).toLowerCase(); tint: ar.modelData.importance === "ALERT" ? Ui.red : Ui.yellow }
                        Text { Layout.fillWidth: true; text: (ar.modelData.subject || ar.modelData.title) + (ar.modelData.description ? "  ·  " + ar.modelData.description : ""); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; wrapMode: Text.Wrap }
                        Text { text: String(ar.modelData.timestamp || "").slice(0, 16).replace("T", " "); color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3 }
                    }
                }
            }

            // ---------- certificates ----------
            Card {
                visible: page.configured && page.certs.length > 0
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Certificates"
                subtitle: "days left on what each endpoint serves (the list is `certs` in ~/.config/barch/nas.json); a notification comes under 10 days"
                Repeater {
                    model: page.certs
                    RowLayout {
                        id: xr
                        required property var modelData
                        spacing: 10
                        Rectangle { width: 8; height: 8; radius: 4; color: page.certTint(xr.modelData) }
                        Text { Layout.fillWidth: true; text: xr.modelData.host; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                        Text {
                            text: xr.modelData.days !== null ? Math.floor(xr.modelData.days) + " days" : xr.modelData.error
                            color: page.certTint(xr.modelData); font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                        }
                    }
                }
            }

            // ---------- over time ----------
            RowLayout {
                visible: page.configured
                Layout.leftMargin: 14; Layout.rightMargin: 12
                spacing: 6
                Text { Layout.fillWidth: true; text: "Over time"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true }
                Repeater {
                    model: page.ranges
                    UiButton { required property var modelData; label: modelData; small: true; primary: page.range === modelData; onClicked: page.range = modelData }
                }
            }
            GridLayout {
                visible: page.configured
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                columns: width > 900 ? 2 : 1
                columnSpacing: 12; rowSpacing: 12
                NasChart { title: "Array and fullest pool"; metrics: ["nas.array.pct", "nas.pool.pct"]; labels: ["array", "pool"]; unit: "%"; fixedMin: 0; fixedMax: 100 }
                NasChart { title: "Hottest disk"; metrics: ["nas.disk.temp"]; unit: "°C" }
                NasChart { title: "Load"; metrics: ["nas.cpu.pct", "nas.ram.pct"]; labels: ["cpu", "ram"]; unit: "%"; fixedMin: 0; fixedMax: 100 }
                NasChart { title: "Containers down and Unraid notifications"; metrics: ["nas.containers.down", "nas.alerts"]; labels: ["containers down", "unread notifications"] }
            }
            Item { height: 12 }
        }
    }
}
