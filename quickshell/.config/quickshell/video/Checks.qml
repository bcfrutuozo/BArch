import QtQuick
import QtQuick.Layouts

// the checklist of a file (video.py checklist): original-language audio, PT-BR audio, English and
// PT-BR subtitles. Green = there, red = missing, dim = unknown (no file, or no original language).
RowLayout {
    id: row
    property var check: null
    property bool compact: false
    spacing: 4
    readonly property var items: [
        { key: "native", label: "orig", tip: "audio in the original language" },
        { key: "por_audio", label: "PT-BR", tip: "Brazilian Portuguese audio (the dub)" },
        { key: "eng_sub", label: "EN sub", tip: "English subtitle" },
        { key: "por_sub", label: "PT sub", tip: "Brazilian Portuguese subtitle" }
    ]
    Repeater {
        model: row.items
        Badge {
            required property var modelData
            readonly property var v: row.check ? row.check[modelData.key] : null
            text: row.compact ? modelData.label.replace(" sub", "s") : modelData.label
            tint: v === true ? Ui.green : v === false ? Ui.red : Ui.overlay
            tip: modelData.tip + (v === true ? ": yes" : v === false ? ": missing" : ": unknown")
        }
    }
}
