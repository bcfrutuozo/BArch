pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// a release next to the files (the review's download, a library album), track by track, as the
// matcher pairs them: GET /api/jobs/<id>/compare or /api/library/compare (matcher.compare)
ColumnLayout {
    id: table
    property var cmp: null
    property string oursLabel: "your download"
    Layout.fillWidth: true
    spacing: 2
    function mmss(s) { if (s === null || s === undefined) return ""; s = Math.round(s); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0") }
    function diffColor(r) {
        if (r.seconds === null || r.mb_seconds === null) return Ui.red
        return r.diff === null ? Ui.overlay : r.diff > 7 ? Ui.red : r.diff > 3 ? Ui.yellow : Ui.green
    }
    function subtitle() {
        const c = cmp
        if (!c) return ""
        return "MusicBrainz " + c.media.map(m => m.tracks + " (" + m.format + ")").join(" + ") + "  vs  " + table.oursLabel + " " + c.ours.join(" + ") + " track(s)"
            + (c.split ? "  ·  one disc spread over MusicBrainz's discs, as the pipeline does" : "")
            + (c.worst !== null ? "  ·  lengths: worst " + c.worst + " s, mean " + c.mean + " s (the pipeline takes up to 7 s and 3 s)" : "")
    }
    component Label: Text { color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
    component Line: Text { Layout.fillWidth: true; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap }
    component Mono: Text { Layout.fillWidth: true; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2; wrapMode: Text.WrapAnywhere }
    // header
    RowLayout {
        Layout.fillWidth: true
        visible: !!table.cmp
        spacing: 8
        Label { Layout.preferredWidth: 40; text: "#"; font.bold: true }
        Label { Layout.fillWidth: true; Layout.preferredWidth: 1; text: "MusicBrainz"; font.bold: true }
        Label { Layout.preferredWidth: 46; text: "length"; horizontalAlignment: Text.AlignRight; font.bold: true }
        Label { Layout.preferredWidth: 40; text: "file"; font.bold: true }
        Label { Layout.fillWidth: true; Layout.preferredWidth: 1; text: table.oursLabel; font.bold: true }
        Label { Layout.preferredWidth: 46; text: "length"; horizontalAlignment: Text.AlignRight; font.bold: true }
        Label { Layout.preferredWidth: 50; text: "Δ"; horizontalAlignment: Text.AlignRight; font.bold: true }
    }
    Repeater {
        model: table.cmp ? table.cmp.rows : []
        Rectangle {
            id: crow
            required property var modelData
            required property int index
            readonly property var r: modelData
            readonly property bool off: r.seconds === null || r.mb_seconds === null || (r.diff !== null && r.diff > 7)
            readonly property bool titleOff: r.title_sim !== null && r.title_sim < 0.6
            readonly property bool newDisc: index > 0 && table.cmp.rows[index - 1].disc !== r.disc
            Layout.fillWidth: true
            Layout.topMargin: newDisc ? 6 : 0
            implicitHeight: crl.implicitHeight + 6
            radius: 4
            color: off ? Qt.rgba(Ui.red.r, Ui.red.g, Ui.red.b, 0.12) : index % 2 ? Ui.sunken : "transparent"
            RowLayout {
                id: crl
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 4; rightMargin: 4 }
                spacing: 8
                Mono { Layout.fillWidth: false; Layout.preferredWidth: 36; text: crow.r.disc + "." + String(crow.r.pos).padStart(2, "0"); color: Ui.subtext; wrapMode: Text.NoWrap }
                Line { Layout.preferredWidth: 1; text: crow.r.mb_title || "—"; color: crow.r.mb_title ? Ui.text : Ui.red; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                Mono { Layout.fillWidth: false; Layout.preferredWidth: 46; text: table.mmss(crow.r.mb_seconds); horizontalAlignment: Text.AlignRight; wrapMode: Text.NoWrap }
                Mono { Layout.fillWidth: false; Layout.preferredWidth: 40; text: crow.r.file; color: Ui.overlay; wrapMode: Text.NoWrap }
                Line {
                    Layout.preferredWidth: 1
                    text: crow.r.file ? (crow.r.title || "(no title)") : "—"
                    color: !crow.r.file ? Ui.red : crow.titleOff ? Ui.yellow : Ui.text
                    elide: Text.ElideRight; wrapMode: Text.NoWrap
                }
                Mono { Layout.fillWidth: false; Layout.preferredWidth: 46; text: table.mmss(crow.r.seconds); horizontalAlignment: Text.AlignRight; wrapMode: Text.NoWrap }
                Mono {
                    Layout.fillWidth: false; Layout.preferredWidth: 50; horizontalAlignment: Text.AlignRight; wrapMode: Text.NoWrap
                    text: crow.r.diff === null ? (crow.r.seconds === null || crow.r.mb_seconds === null ? "missing" : "?") : (crow.r.diff < 0.5 ? "0" : crow.r.diff.toFixed(1)) + " s"
                    color: table.diffColor(crow.r); font.bold: crow.off
                }
            }
        }
    }
}
