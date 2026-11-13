import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the pfSense firewalls as agent/pfsense.py sees them (their REST API, read only): what
// `barch --json fw status` answers, asked every minute while the window is open, one card per site
// (omni, chaos) with gateways, interfaces, the IPsec tunnel, the DNSBL check, the DHCP clients by
// network and what the firewall blocked, plus the fw.<site>.* metrics barch-events keeps
Item {
    id: page
    readonly property var fw: Store.fw
    readonly property bool configured: fw.configured !== false
    readonly property var siteNames: Object.keys(fw.sites || {})
    readonly property var sites: siteNames.map(n => fw.sites[n])
    readonly property int problemCount: sites.reduce((n, s) => n + (s.problems || []).length, 0)

    property string range: "24h"
    readonly property var ranges: ["24h", "7d", "30d"]
    function spanOf(r) { return parseInt(r) * (r.slice(-1) === "d" ? 86400 : 3600) }
    readonly property var seriesColors: [Ui.accent, Ui.green, Ui.yellow, Ui.red]

    function key(name) { return String(name).toLowerCase().replace(/[^a-z0-9]+/g, "_") }
    function rttTint(ms, loss) { return loss > 0 ? Ui.red : ms > 60 ? Ui.yellow : Ui.green }
    function ifSort(a, b) { return a.localeCompare(b) }
    function ipSort(a, b) {
        const x = String(a.ip).split(".").map(Number), y = String(b.ip).split(".").map(Number)
        for (let i = 0; i < 4; i++) if (x[i] !== y[i]) return (x[i] || 0) - (y[i] || 0)
        return 0
    }

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

    // a card with a chart of some fw.* metrics in the page's range (as the NAS page draws them)
    component FwChart: Card {
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
            if (left === 0) return
            metrics.forEach((m, i) => Store.series(m, page.range, d => {
                if (mine !== generation) return
                out[i] = { label: labels[i] || m, color: page.seriesColors[i % page.seriesColors.length], points: d.points || [] }
                pending = --left
                if (left === 0) { axisFrom = from; axisTo = to; series = out }
            }))
        }
        Component.onCompleted: load()
        Connections { target: page; function onRangeChanged() { mc.load() } }
        Connections { target: Store; function onFwChanged() { if (mc.pending === 0) mc.load() } }
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

    // one site: the glance tiles, then its problems
    component SiteCard: Card {
        id: sc
        property var s: ({})
        readonly property bool up: s.reachable === true
        readonly property var gws: (s.gateways || []).filter(g => g.monitor && g.monitor !== "none")
        readonly property var wan: gws.filter(g => !/6$/.test(g.name))[0] || gws[0] || null
        readonly property var ifaces: s.interfaces || []
        readonly property var tunnels: s.ipsec || []
        readonly property var blocked: s.blocked || ({})
        readonly property int blockedTotal: Object.values(blocked).reduce((n, v) => n + v, 0)
        readonly property var blockedLocal: Object.keys(blocked).filter(k => k !== "WAN").sort((a, b) => blocked[b] - blocked[a])
        readonly property var problems: s.problems || []
        Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
        title: sc.s.site + "  ·  " + (!sc.up ? (sc.s.auth === false ? "key refused" : "not answering")
                                     : sc.problems.length === 0 ? "ok" : sc.problems.length + " problem" + (sc.problems.length === 1 ? "" : "s"))
        subtitle: !sc.up ? String(sc.s.error || "")
                : "pfSense " + sc.s.version + "  ·  up " + String(sc.s.uptime || "").replace(/ \d+ Seconds?$/, "")
                  + "  ·  cpu " + Math.round(sc.s.cpu_pct || 0) + "%  ram " + Math.round(sc.s.ram_pct || 0) + "%"
                  + (sc.s.temp !== null && sc.s.temp !== undefined ? "  ·  " + sc.s.temp + " °C" : "")
        Flow {
            Layout.fillWidth: true
            spacing: 10
            visible: sc.up
            Tile {
                label: "WAN"
                value: sc.wan ? (sc.wan.ok ? sc.wan.rtt.toFixed(0) + " ms" : String(sc.wan.status)) : "—"
                sub: sc.wan ? sc.wan.name + "  ·  " + sc.wan.loss.toFixed(0) + "% loss" + (sc.gws.length > 1 ? "  ·  " + sc.gws.filter(g => g !== sc.wan).map(g => g.name.replace(/^WAN_/, "") + " " + (g.ok ? g.rtt.toFixed(0) + " ms" : g.status)).join(", ") : "") : "no monitored gateway"
                tint: !sc.wan ? Ui.subtext : !sc.wan.ok ? Ui.red : page.rttTint(sc.wan.rtt, sc.wan.loss)
            }
            Tile {
                label: "Interfaces"
                value: sc.ifaces.filter(i => i.up).length + " of " + sc.ifaces.length + " up"
                sub: sc.ifaces.map(i => i.descr + (i.up ? "" : " ↓")).join("  ·  ")
                tint: sc.ifaces.some(i => !i.up) ? Ui.red : Ui.green
            }
            Tile {
                label: "IPsec"
                value: sc.tunnels.length ? (sc.tunnels.every(t => t.up) ? "up" : "DOWN") : (sc.s.errors && sc.s.errors.sas ? "not readable" : "no tunnel")
                sub: sc.tunnels.length ? sc.tunnels.map(t => t.name + (t.up ? "  " + (t.local || []).join(",") + " ↔ " + (t.remote || []).join(",") : "")).join("  ·  ")
                   : sc.s.errors && sc.s.errors.sas ? String(sc.s.errors.sas) : "the other site answering says the tunnel is up"
                tint: sc.tunnels.length ? (sc.tunnels.every(t => t.up) ? Ui.green : Ui.red) : Ui.subtext
            }
            Tile {
                label: "DNSBL"
                value: sc.s.dnsbl === true ? "blocking" : sc.s.dnsbl === false ? "NOT blocking" : "no answer"
                sub: "pfBlockerNG, asked with a real query"
                tint: sc.s.dnsbl === true ? Ui.green : sc.s.dnsbl === false ? Ui.red : Ui.yellow
            }
            Tile {
                label: "Clients"
                value: (sc.s.clients_online || 0) + " online"
                sub: (sc.s.clients || []).length + " leases"
            }
            Tile {
                label: "Blocked"
                value: sc.blockedTotal + " in " + (sc.s.log_lines || 0) + " lines"
                sub: sc.blockedLocal.length ? sc.blockedLocal.map(k => k + " " + sc.blocked[k]).join("  ·  ") + (sc.blocked.WAN ? "  ·  WAN " + sc.blocked.WAN : "") : (sc.blocked.WAN ? "all on the WAN (internet noise)" : "nothing in the log read")
                tint: sc.blockedLocal.some(k => sc.blocked[k] > 100) ? Ui.yellow : Ui.text
            }
        }
        Repeater {
            model: sc.problems
            Text { required property var modelData; Layout.fillWidth: true; text: "•  " + modelData; color: Ui.red; font.family: Ui.font; font.pixelSize: Ui.fontSize; wrapMode: Text.Wrap }
        }
        Text {
            visible: sc.up && sc.s.errors && Object.keys(sc.s.errors).length > 0
            Layout.fillWidth: true
            text: "not readable with this key: " + Object.keys(sc.s.errors || {}).map(k => k + " (" + sc.s.errors[k] + ")").join(", ")
            color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
        }
    }

    // one site's DHCP leases, grouped by network, online first
    component ClientsCard: Card {
        id: cc
        property var s: ({})
        readonly property var clients: s.clients || []
        readonly property var nets: Array.from(new Set(clients.map(c => c.ifdescr))).sort(page.ifSort)
        property string filter: ""
        Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
        visible: s.reachable === true
        title: cc.s.site + "  ·  clients"
        subtitle: "the DHCP leases, by network; a device never seen before is notified by the fw-new-client rule"
        headerItems: [ UiField { placeholderText: "filter"; implicitWidth: 180; onTextChanged: cc.filter = text.toLowerCase() } ]
        Repeater {
            model: cc.nets
            ColumnLayout {
                id: net
                required property var modelData
                readonly property var rows: cc.clients.filter(c => c.ifdescr === net.modelData && (!cc.filter || (c.ip + " " + c.mac + " " + c.hostname).toLowerCase().includes(cc.filter)))
                                                     .sort((a, b) => (b.online - a.online) || page.ipSort(a, b))
                Layout.fillWidth: true
                spacing: 2
                visible: rows.length > 0
                RowLayout {
                    spacing: 8
                    Badge { text: net.modelData; tint: net.modelData === "LAN" ? Ui.green : /CAM/i.test(net.modelData) ? Ui.yellow : Ui.accent }
                    Text { text: net.rows.filter(c => c.online).length + " online of " + net.rows.length; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                }
                Repeater {
                    model: net.rows
                    RowLayout {
                        id: cr
                        required property var modelData
                        spacing: 10
                        Rectangle { width: 8; height: 8; radius: 4; color: cr.modelData.online ? Ui.green : Ui.overlay }
                        Text { Layout.preferredWidth: 120; text: cr.modelData.ip; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Text { Layout.preferredWidth: 150; text: cr.modelData.mac; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        Text { Layout.fillWidth: true; text: cr.modelData.hostname || "—"; color: cr.modelData.hostname ? Ui.text : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideRight }
                        Badge { visible: cr.modelData.static; text: "static"; tint: Ui.subtext }
                    }
                }
                Item { height: 6 }
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

            // ---------- not set up / header ----------
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: !page.configured ? "Firewalls  ·  not set up"
                     : page.siteNames.length === 0 ? "Firewalls  ·  " + (Store.fwAt ? "no answer" : "asking…")
                     : "Firewalls  ·  " + page.siteNames.join(", ") + "  ·  " + (page.problemCount === 0 ? "ok" : page.problemCount + " problem" + (page.problemCount === 1 ? "" : "s"))
                subtitle: !page.configured ? "run `barch fw setup`: it says how to make a read-only API user and key on each pfSense and what ~/.config/barch/pfsense.json holds"
                        : String(page.fw.error || "") || ("pfSense REST API, read only  ·  asked " + Store.ago(Store.fwAt) + (Store.fwBusy ? "  ·  asking…" : ""))
                headerItems: [ UiButton { label: "Refresh"; icon: "󰑐"; small: true; tooltip: "ask both firewalls again"; onClicked: Store.refreshFw() } ]
            }

            Repeater {
                model: page.sites
                SiteCard { required property var modelData; s: modelData }
            }

            Repeater {
                model: page.sites
                ClientsCard { required property var modelData; s: modelData }
            }

            // ---------- over time ----------
            RowLayout {
                visible: page.configured && page.siteNames.length > 0
                Layout.leftMargin: 14; Layout.rightMargin: 12
                spacing: 6
                Text { Layout.fillWidth: true; text: "Over time"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true }
                Repeater {
                    model: page.ranges
                    UiButton { required property var modelData; label: modelData; small: true; primary: page.range === modelData; onClicked: page.range = modelData }
                }
            }
            GridLayout {
                visible: page.configured && page.siteNames.length > 0
                Layout.fillWidth: true
                Layout.leftMargin: 12; Layout.rightMargin: 12
                columns: width > 900 ? 2 : 1
                columnSpacing: 12; rowSpacing: 12
                FwChart {
                    title: "WAN latency"
                    metrics: page.siteNames.map(n => "fw." + page.key(n) + ".gw.wan_dhcp.rtt")
                    labels: page.siteNames
                    unit: "ms"; fixedMin: 0
                }
                FwChart {
                    title: "Blocked connections per sample"
                    metrics: page.siteNames.map(n => "fw." + page.key(n) + ".blocked")
                    labels: page.siteNames
                    fixedMin: 0
                }
                FwChart {
                    title: "Clients online"
                    metrics: page.siteNames.map(n => "fw." + page.key(n) + ".clients")
                    labels: page.siteNames
                    fixedMin: 0
                }
                FwChart {
                    title: "Temperature"
                    metrics: page.siteNames.map(n => "fw." + page.key(n) + ".temp")
                    labels: page.siteNames
                    unit: "°C"
                }
            }
            Item { height: 12 }
        }
    }
}
