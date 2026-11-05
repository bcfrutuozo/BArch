import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// qBittorrent over time: the client's all-time ratio and how far it moved in the range, what was
// uploaded and downloaded per hour/day/week/month, speeds, how many torrents and how much data.
// Upload is always the accent color, download the neutral one.
Item {
    id: page
    readonly property var o: Store.overview
    readonly property var now: o.now || ({})
    readonly property var then: o.then || null
    readonly property var live: o.live || ({})
    readonly property var h: Store.history
    readonly property string per: "per " + Store.bucketWord[h.kind || "day"]
    function win(name) { return o[name] || ({ up: 0, down: 0, ratio: null }) }
    function signed(v, digits) { return (v >= 0 ? "+" : "−") + Math.abs(v).toFixed(digits) }

    component Tile: Rectangle {
        property string label: ""
        property string value: ""
        property string sub: ""
        property color tint: Ui.text
        width: 212; height: 72; radius: Ui.radius
        color: Ui.sunken; border.width: 1; border.color: Ui.surface
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 10; spacing: 1
            Text { text: parent.parent.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            Text { text: parent.parent.value; color: parent.parent.tint; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
            Text { text: parent.parent.sub; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3; elide: Text.ElideRight; Layout.fillWidth: true }
        }
    }
    component Legend: RowLayout {
        property var items: []       // [{ label, color }]
        spacing: 14
        Repeater {
            model: parent.items
            RowLayout {
                required property var modelData
                spacing: 5
                Rectangle { width: 10; height: 3; radius: 1; color: parent.modelData.color }
                Text { text: parent.modelData.label; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 3 }
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

            Card {
                Layout.margins: 12; Layout.bottomMargin: 0
                title: "At a glance"
                subtitle: !Store.status.samples ? "no sample yet"
                          : Store.status.samples + " samples since " + Store.day(Store.status.start) + ", one every " + Math.round((Store.status.poll_s || 300) / 60) + " min  ·  qBittorrent " + (Store.status.qbittorrent || "")
                Flow {
                    Layout.fillWidth: true
                    spacing: 10
                    Tile {
                        label: "Ratio (all time)"
                        value: Store.ratio(page.now.ratio)
                        sub: page.then && page.then.ratio !== null && page.now.ratio !== null
                             ? page.signed(page.now.ratio - page.then.ratio, 4) + " " + Store.rangeLabel : "as qBittorrent counts it"
                        tint: Store.ratioTint(page.now.ratio)
                    }
                    Tile {
                        label: "Uploaded (all time)"
                        value: Store.bytes(page.now.alltime_ul)
                        sub: page.then ? "+" + Store.bytes(page.then.up) + " " + Store.rangeLabel : ""
                    }
                    Tile {
                        label: "Downloaded (all time)"
                        value: Store.bytes(page.now.alltime_dl)
                        sub: page.then ? "+" + Store.bytes(page.then.down) + " " + Store.rangeLabel : ""
                    }
                    Tile {
                        label: "Ratio " + Store.rangeLabel
                        value: Store.ratio(page.win("range").ratio)
                        sub: "↑ " + Store.bytes(page.win("range").up) + "  ↓ " + Store.bytes(page.win("range").down)
                        tint: Store.ratioTint(page.win("range").ratio)
                    }
                    Tile {
                        label: "Last 24 h"
                        value: "↑ " + Store.bytes(page.win("day").up)
                        sub: "↓ " + Store.bytes(page.win("day").down) + "  ·  ratio " + Store.ratio(page.win("day").ratio)
                    }
                    Tile {
                        label: "Last 7 days"
                        value: "↑ " + Store.bytes(page.win("week").up)
                        sub: "↓ " + Store.bytes(page.win("week").down) + "  ·  ratio " + Store.ratio(page.win("week").ratio)
                    }
                    Tile {
                        label: "Torrents"
                        value: (page.now.torrents || 0) + "  ·  " + Store.bytes(page.now.size)
                        sub: (page.now.seeding || 0) + " seeding  ·  " + (page.now.downloading || 0) + " downloading  ·  " + ((page.o.tracked || {}).removed || 0) + " removed"
                    }
                    Tile {
                        label: "Seeding goal (ratio " + (page.o.goal || 0) + ")"
                        value: (page.live.at_goal || 0) + " of " + (page.live.done || 0) + " there"
                        sub: (page.live.below_1 || 0) + " still below 1  ·  together " + Store.ratio(page.live.ratio)
                    }
                    Tile {
                        label: "Right now"
                        value: "↑ " + Store.rate(page.now.up_speed)
                        sub: "↓ " + Store.rate(page.now.dl_speed) + "  ·  " + (page.now.peers || 0) + " peers  ·  " + Store.bytes(page.now.free_space) + " free"
                    }
                }
            }

            GridLayout {
                Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 12
                columns: width > 900 ? 2 : 1
                columnSpacing: 12; rowSpacing: 12

                Card {
                    Layout.fillHeight: true
                    title: "Ratio"
                    subtitle: "all-time upload ÷ download, as qBittorrent counts it"
                    Chart {
                        Layout.fillWidth: true
                        from: Store.axisFrom; to: Store.axisTo
                        markT: Store.began; markLabel: Store.beganLabel
                        series: [{ label: "", color: Ui.accent, points: Store.samples.filter(s => s.ratio !== null).map(s => ({ t: s.t, v: s.ratio })) }]
                        format: v => v.toFixed(4)
                        padL: 62
                    }
                }
                Card {
                    Layout.fillHeight: true
                    title: "Speed"
                    subtitle: "average between samples"
                    Chart {
                        Layout.fillWidth: true
                        from: Store.axisFrom; to: Store.axisTo
                        markT: Store.began; markLabel: Store.beganLabel
                        series: [
                            { label: "upload", color: Ui.accent, points: Store.samples.map(s => ({ t: s.t, v: s.up_speed })) },
                            { label: "download", color: Ui.subtext, points: Store.samples.map(s => ({ t: s.t, v: s.dl_speed })) }
                        ]
                        format: v => Store.rate(v)
                        padL: 62
                    }
                    Legend { items: [{ label: "upload", color: Ui.accent }, { label: "download", color: Ui.subtext }] }
                }
                Card {
                    Layout.fillHeight: true
                    title: "Uploaded " + page.per
                    subtitle: Store.bytes(page.h.up || 0) + " " + Store.rangeLabel
                    Bars {
                        Layout.fillWidth: true
                        markT: Store.began; markLabel: Store.beganLabel
                        points: (page.h.buckets || []).map(b => ({ t: b.t, v: b.up }))
                        kind: page.h.kind || "day"
                        tint: Ui.accent
                        format: v => Store.bytes(v)
                        emptyText: "nothing uploaded " + Store.rangeLabel
                    }
                }
                Card {
                    Layout.fillHeight: true
                    title: "Downloaded " + page.per
                    subtitle: Store.bytes(page.h.down || 0) + " " + Store.rangeLabel
                    Bars {
                        Layout.fillWidth: true
                        markT: Store.began; markLabel: Store.beganLabel
                        points: (page.h.buckets || []).map(b => ({ t: b.t, v: b.down }))
                        kind: page.h.kind || "day"
                        tint: Ui.subtext
                        format: v => Store.bytes(v)
                        emptyText: "nothing downloaded " + Store.rangeLabel
                    }
                }
                Card {
                    Layout.fillHeight: true
                    title: "Torrents"
                    subtitle: "in the client, and how many of them are seeding"
                    Chart {
                        Layout.fillWidth: true
                        from: Store.axisFrom; to: Store.axisTo
                        markT: Store.began; markLabel: Store.beganLabel
                        series: [
                            { label: "seeding", color: Ui.accent, points: Store.samples.map(s => ({ t: s.t, v: s.seeding })) },
                            { label: "all", color: Ui.subtext, points: Store.samples.map(s => ({ t: s.t, v: s.torrents })) }
                        ]
                        format: v => String(Math.round(v))
                        padL: 62
                    }
                    Legend { items: [{ label: "seeding", color: Ui.accent }, { label: "all", color: Ui.subtext }] }
                }
                Card {
                    Layout.fillHeight: true
                    title: "Data in the client"
                    subtitle: "the size of every torrent it holds"
                    Chart {
                        Layout.fillWidth: true
                        from: Store.axisFrom; to: Store.axisTo
                        markT: Store.began; markLabel: Store.beganLabel
                        series: [{ label: "", color: Ui.accent, points: Store.samples.map(s => ({ t: s.t, v: s.size })) }]
                        format: v => Store.bytes(v)
                        padL: 62
                    }
                }
            }
        }
    }
}
