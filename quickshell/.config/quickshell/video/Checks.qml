pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// the checklist of a file (video.py checklist): original-language audio, PT-BR audio, English and
// PT-BR subtitles, and no audio in any other language (shown only when there is some: red "+deu").
// Green = there, red = missing, dim = unknown (no file, or no original language).
RowLayout {
    id: row
    property var check: null
    property bool compact: false
    spacing: 4
    readonly property var items: [
        { key: "native", label: "orig", short: "orig", tip: "audio in the original language" },
        { key: "por_audio", label: "PT-BR", short: "PT-BR", tip: "Brazilian Portuguese audio (the dub)" },
        { key: "eng_sub", label: "EN sub", short: "ENs", tip: "English subtitle" },
        { key: "por_sub", label: "PT sub", short: "PTs", tip: "Brazilian Portuguese subtitle" }
    ]
    Repeater {
        model: row.items
        Badge {
            required property var modelData
            readonly property var v: row.check ? row.check[modelData.key] : null
            text: row.compact ? modelData.short : modelData.label
            tint: v === true ? Ui.green : v === false ? Ui.red : Ui.overlay
            tip: modelData.tip + (v === true ? ": yes" : v === false ? ": missing" : ": unknown")
        }
    }
    Badge {
        // audio in a language beyond the original and PT-BR: the pipeline's trim removes it (and the
        // release would score -10000 today); a season shows it when any of its episodes has it
        visible: !!row.check && row.check.no_foreign === false
        text: "+" + ((row.check && row.check.extra) || []).join(",") || "+other"
        tint: Ui.red
        tip: "audio in another language" + (row.check && row.check.extra && row.check.extra.length ? ": " + row.check.extra.join(", ") : "") + " (the pipeline trims it; such releases are refused since 2026-11-08)"
    }
}
