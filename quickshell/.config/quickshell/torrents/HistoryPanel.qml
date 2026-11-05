import QtQuick
import QtQuick.Layouts

// the history of one source or one torrent (Store.history's shape: { kind, buckets: [{ t, up, down,
// ratio }] }): its lifetime ratio as a line, then what it uploaded and downloaded per bucket
ColumnLayout {
    id: panel
    property var history: null
    readonly property var buckets: history ? history.buckets : []
    readonly property string per: history ? "per " + Store.bucketWord[history.kind] : ""
    spacing: 6

    component Heading: RowLayout {
        property string title: ""
        property string value: ""
        Layout.fillWidth: true
        Layout.topMargin: 6
        Text { Layout.fillWidth: true; text: parent.title; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize; font.bold: true; elide: Text.ElideRight }
        Text { text: parent.value; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
    }

    Heading {
        title: "Ratio"
        value: panel.buckets.length ? "lifetime, now " + Store.ratio(panel.buckets[panel.buckets.length - 1].ratio) : ""
    }
    Chart {
        Layout.fillWidth: true
        implicitHeight: 150
        series: panel.history ? [{ label: "", color: Ui.accent, points: panel.buckets.filter(b => b.ratio !== null).map(b => ({ t: b.t, v: b.ratio })) }] : []
        format: v => Store.ratio(v)
        padL: 58
    }
    Heading { title: "Uploaded " + panel.per; value: panel.history ? Store.bytes(panel.history.up) + " " + Store.rangeLabel : "" }
    Bars {
        Layout.fillWidth: true
        implicitHeight: 150
        points: panel.buckets.map(b => ({ t: b.t, v: b.up }))
        kind: panel.history ? panel.history.kind : "day"
        tint: Ui.accent
        format: v => Store.bytes(v)
        emptyText: "nothing uploaded " + Store.rangeLabel
    }
    Heading { title: "Downloaded " + panel.per; value: panel.history ? Store.bytes(panel.history.down) + " " + Store.rangeLabel : "" }
    Bars {
        Layout.fillWidth: true
        implicitHeight: 150
        points: panel.buckets.map(b => ({ t: b.t, v: b.down }))
        kind: panel.history ? panel.history.kind : "day"
        tint: Ui.subtext
        format: v => Store.bytes(v)
        emptyText: "nothing downloaded " + Store.rangeLabel
    }
}
