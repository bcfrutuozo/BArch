import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the machine over time: what barch-events samples into metrics.db (temperatures, load, network,
// disks), boots, failures per week and what Claude cost — `barch metrics summary|series`
Item {
    id: page
    property string range: "24h"
    readonly property var ranges: ["1h", "6h", "24h", "7d", "30d"]
    // "24h" -> seconds: the charts span the whole range, the data sitting where it belongs in it
    function spanOf(r) { return parseInt(r) * (r.slice(-1) === "d" ? 86400 : 3600) }
    readonly property var s: Store.summary
    readonly property var now: s.now || ({})
    readonly property var palette: [Ui.accent, Ui.green, Ui.yellow, Ui.red, Ui.overlay]

    function n(v, d) { return v === null || v === undefined ? "—" : Number(v).toFixed(d === undefined ? 0 : d) }
    function usd(v) { return v === null || v === undefined ? "—" : "US$ " + Number(v).toFixed(2) }

    // a card with a chart of some metrics in the page's range
    component MetricChart: Card {
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
        Layout.alignment: Qt.AlignTop
        property int generation: 0
        // loads overlap (creation, a new range, every refresh of the summary): only the newest one may
        // publish, and only when all of its own answers are in, or a chart is left with a series missing
        function load() {
            if (!metrics.length) { series = []; return }
            const mine = ++generation
            const out = new Array(metrics.length)
            const to = Date.now() / 1000, from = to - page.spanOf(page.range)
            let left = metrics.length
            pending = left
            metrics.forEach((m, i) => Store.series(m, page.range, d => {
                if (mine !== generation) return
                out[i] = { label: labels[i] || m, color: page.palette[i % page.palette.length], points: d.points || [] }
                pending = --left
                if (left === 0) { axisFrom = from; axisTo = to; series = out }
            }))
        }
        Component.onCompleted: load()
        Connections { target: page; function onRangeChanged() { mc.load() } }
        Connections { target: Store; function onSummaryChanged() { if (mc.pending === 0) mc.load() } }
        onMetricsChanged: load()
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

            // ---------- tiles ----------
            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: "At a glance"
                subtitle: Store.eventsService === "active"
                          ? "barch-events sampling every 30 s  ·  " + (page.s.events_24h || 0) + " events in 24 h"
                          : "barch-events is not running: barch events on"
                headerItems: [ UiButton { icon: "󰑐"; small: true; tooltip: "refresh"; onClicked: Store.refreshAutomation() } ]
                Flow {
                    Layout.fillWidth: true
                    spacing: 10
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
                    Tile {
                        label: "Last boot"
                        value: page.s.boot && page.s.boot.seconds ? page.n(page.s.boot.seconds, 1) + " s" : "—"
                        sub: page.s.boot ? (page.s.boot.kernel || "") + (page.s.boot.avg_seconds ? "  ·  avg " + page.n(page.s.boot.avg_seconds, 1) + " s over " + page.s.boot.count_90d : "") : ""
                        tint: page.s.boot && page.s.boot.seconds > 60 ? Ui.yellow : Ui.text
                    }
                    Tile {
                        label: "Failures"
                        value: page.s.failures ? page.s.failures.week + " this week" : "—"
                        sub: page.s.failures ? page.s.failures.last_week + " last week  ·  " + page.s.failures.month + " in 30 days" : ""
                        tint: page.s.failures && page.s.failures.week > 0 ? Ui.yellow : Ui.green
                    }
                    Tile {
                        label: "Claude"
                        value: page.s.claude ? page.usd(page.s.claude.week) + " / 7 d" : "—"
                        sub: page.s.claude ? page.usd(page.s.claude.today) + " in 24 h  ·  " + page.usd(page.s.claude.month) + " in 30 d" : ""
                    }
                    Tile {
                        label: "VPN"
                        value: page.s.vpn ? (page.s.vpn.connected ? "on  ·  " + page.n(page.s.vpn.latency_ms, 0) + " ms" : "off") : "—"
                        sub: page.s.vpn ? page.s.vpn.drops_7d + " drops in 7 days" : ""
                        tint: page.s.vpn && page.s.vpn.connected ? Ui.green : Ui.text
                    }
                    Tile {
                        label: "Temperatures"
                        value: "CPU " + page.n(page.now["cpu.temp"]) + " °  ·  GPU " + page.n(page.now["gpu.temp"]) + " °"
                        sub: "load " + page.n(page.now["cpu.pct"]) + " %  ·  GPU " + page.n(page.now["gpu.util"]) + " %"
                        tint: Math.max(page.now["cpu.temp"] || 0, page.now["gpu.temp"] || 0) > 80 ? Ui.red : Ui.text
                    }
                    Tile {
                        label: "Memory and disk"
                        value: "RAM " + page.n(page.now["ram.pct"]) + " %  ·  disk " + page.n(page.now["disk.root.pct"]) + " %"
                        sub: "VRAM " + page.n(page.now["gpu.vram_pct"]) + " %  ·  ping " + page.n(page.now["net.latency_ms"], 1) + " ms"
                        tint: (page.now["disk.root.pct"] || 0) > 90 ? Ui.red : Ui.text
                    }
                    Tile {
                        label: "Rules fired"
                        value: page.s.rules ? page.s.rules.fired_24h + " in 24 h" : "—"
                        sub: page.s.rules ? page.s.rules.fired_7d + " in 7 days" : ""
                    }
                }
            }

            // ---------- range ----------
            RowLayout {
                Layout.leftMargin: 12; Layout.rightMargin: 12
                spacing: 6
                Text { text: "Range"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                Repeater {
                    model: page.ranges
                    UiButton { required property var modelData; label: modelData; small: true; primary: page.range === modelData; onClicked: page.range = modelData }
                }
                Item { Layout.fillWidth: true }
                Text { text: "raw samples for a week, hourly averages after that"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
            }

            // ---------- charts ----------
            GridLayout {
                Layout.leftMargin: 12; Layout.rightMargin: 12
                columns: width > 1100 ? 2 : 1
                columnSpacing: 12; rowSpacing: 12
                MetricChart { title: "Temperatures"; unit: "°C"; metrics: ["cpu.temp", "gpu.temp", "temp.nvme"]; labels: ["CPU", "GPU", "NVMe"] }
                MetricChart { title: "Load"; unit: "%"; fixedMin: 0; fixedMax: 100; metrics: ["cpu.pct", "gpu.util", "ram.pct", "gpu.vram_pct"]; labels: ["CPU", "GPU", "RAM", "VRAM"] }
                MetricChart { title: "GPU power"; unit: "W"; metrics: ["gpu.power"]; labels: ["GPU"] }
                MetricChart { title: "Network latency"; unit: "ms"; metrics: ["net.latency_ms", "vpn.latency_ms"]; labels: ["ping", "through the VPN"] }
                MetricChart { title: "Disk"; unit: "%"; fixedMin: 0; fixedMax: 100; metrics: ["disk.root.pct"]; labels: ["/"] }
                MetricChart {
                    id: anyChart
                    title: "Any metric"
                    property string metric: "cpu.load1"
                    headerItems: [ UiCombo { entries: Store.metricList.map(m => ({ value: m.metric, label: m.metric })); value: anyChart.metric; onPicked: v => { anyChart.metric = v; anyChart.metrics = [v] } } ]
                    metrics: [metric]; labels: [metric]
                }
            }

            // ---------- claude cost by source ----------
            Card {
                id: costCard
                Layout.margins: 12; Layout.topMargin: 0
                title: "What Claude cost in 30 days"
                subtitle: "agent tasks and the voice fallback (~/.local/state/barch/claude-cost.log); interactive sessions are not counted"
                readonly property var costRows: {
                    const by = (page.s.claude || {}).by_source_30d || {}
                    return Object.keys(by).map(k => ({ source: k, usd: by[k] })).sort((a, b) => b.usd - a.usd)
                }
                readonly property real costTop: costRows.length ? costRows[0].usd : 1
                Text { visible: costCard.costRows.length === 0; text: "nothing yet"; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                Repeater {
                    model: costCard.costRows
                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 10
                        Text { Layout.preferredWidth: 140; text: parent.modelData.source; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                        Rectangle {
                            Layout.fillWidth: true; height: 8; radius: 4; color: Ui.sunken
                            Rectangle { width: parent.width * Math.max(0.01, parent.parent.modelData.usd / costCard.costTop); height: parent.height; radius: 4; color: Ui.accent }
                        }
                        Text { Layout.preferredWidth: 80; horizontalAlignment: Text.AlignRight; text: page.usd(parent.modelData.usd); color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }
        }
    }
}
