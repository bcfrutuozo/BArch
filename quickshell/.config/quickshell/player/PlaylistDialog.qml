pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// a new playlist, or the name and rules of one: hand-made (tracks added from the lists, dragged into
// order) or smart (rules on artist, album, genre, title, year, likes, plays and when it was played,
// evaluated every time it is opened)
Popup {
    id: dlg
    parent: Overlay.overlay
    modal: true
    focus: true
    x: Math.round((parent.width - width) / 2); y: Math.round((parent.height - height) / 2)
    width: 560
    padding: 18
    background: Rectangle { color: Ui.raised; border.width: 1; border.color: Ui.surface; radius: Ui.cardRadius }

    property string editId: ""           // "" = new
    property var withKeys: []            // tracks a new hand-made playlist starts with
    property bool smart: false
    property var rules: ({})
    function create(keys) { editId = ""; withKeys = keys || []; smart = false; rules = {}; name.text = ""; open(); name.forceActiveFocus() }
    function createSmart() { editId = ""; withKeys = []; smart = true; rules = { sort: "artist" }; name.text = ""; open(); name.forceActiveFocus() }
    function edit(id) {
        const p = Store.playlist(id)
        if (!p) return
        editId = id; withKeys = []; smart = !!p.smart; rules = Object.assign({}, p.smart || {}); name.text = p.name
        open(); name.forceActiveFocus()
    }
    function num(v) { const n = parseInt(v); return isNaN(n) ? 0 : n }
    function save() {
        const n = name.text.trim() || (smart ? "Smart playlist" : "New playlist")
        const r = smart ? rules : null
        if (editId) Store.updatePlaylist(editId, p => { p.name = n; p.smart = r })
        else { const id = Store.newPlaylist(n, r); if (!smart && withKeys.length) Store.addToPlaylist(id, withKeys); Store.goPlaylist(id) }
        close()
    }
    function setRule(k, v) { const r = Object.assign({}, rules); if (v === "" || v === 0 || v === false || v === null) delete r[k]; else r[k] = v; rules = r }

    component Lbl: Text { color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; Layout.preferredWidth: 120 }

    contentItem: ColumnLayout {
        spacing: 12
        Text { text: dlg.editId ? (dlg.smart ? "Smart playlist rules" : "Rename playlist") : (dlg.smart ? "New smart playlist" : "New playlist"); color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 4; font.bold: true }
        RowLayout {
            Lbl { text: "Name" }
            UiField { id: name; Layout.fillWidth: true; placeholderText: dlg.smart ? "Smart playlist" : "New playlist"; onAccepted: dlg.save() }
        }
        RowLayout {
            visible: !dlg.editId
            Lbl { text: "Smart" }
            UiSwitch { checked: dlg.smart; onToggled: v => { dlg.smart = v; if (v && !dlg.rules.sort) dlg.rules = { sort: "artist" } } }
            Text { Layout.fillWidth: true; text: dlg.smart ? "tracks picked by rules, always up to date" : (dlg.withKeys.length ? "starts with " + dlg.withKeys.length + " tracks" : "tracks you add, in the order you drag them"); color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
        }
        ColumnLayout {
            visible: dlg.smart
            spacing: 8
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Ui.surface }
            Text { text: "Every rule left empty is ignored; text rules match a part of the name."; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
            GridLayout {
                columns: 4
                columnSpacing: 10; rowSpacing: 8
                Lbl { text: "Artist contains" }   UiField { Layout.fillWidth: true; text: dlg.rules.artist || ""; onTextChanged: dlg.setRule("artist", text) }
                Lbl { text: "Album contains" }    UiField { Layout.fillWidth: true; text: dlg.rules.album || ""; onTextChanged: dlg.setRule("album", text) }
                Lbl { text: "Genre contains" }    UiField { Layout.fillWidth: true; text: dlg.rules.genre || ""; onTextChanged: dlg.setRule("genre", text) }
                Lbl { text: "Title contains" }    UiField { Layout.fillWidth: true; text: dlg.rules.title || ""; onTextChanged: dlg.setRule("title", text) }
                Lbl { text: "Year from" }         UiField { Layout.fillWidth: true; mono: true; text: dlg.rules.yearFrom || ""; onTextChanged: dlg.setRule("yearFrom", dlg.num(text)) }
                Lbl { text: "to" }                UiField { Layout.fillWidth: true; mono: true; text: dlg.rules.yearTo || ""; onTextChanged: dlg.setRule("yearTo", dlg.num(text)) }
                Lbl { text: "Plays at least" }    UiField { Layout.fillWidth: true; mono: true; text: dlg.rules.minPlays || ""; onTextChanged: dlg.setRule("minPlays", dlg.num(text)) }
                Lbl { text: "at most" }           UiField { Layout.fillWidth: true; mono: true; text: dlg.rules.maxPlays === undefined ? "" : dlg.rules.maxPlays; onTextChanged: dlg.setRule("maxPlays", text.trim() === "" ? "" : dlg.num(text)) }
                Lbl { text: "Played in the last" } RowLayout { UiField { Layout.preferredWidth: 70; mono: true; text: dlg.rules.playedDays || ""; onTextChanged: dlg.setRule("playedDays", dlg.num(text)) } Text { text: "days"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 } }
                Lbl { text: "Not played for" }    RowLayout { UiField { Layout.preferredWidth: 70; mono: true; text: dlg.rules.notPlayedDays || ""; onTextChanged: dlg.setRule("notPlayedDays", dlg.num(text)) } Text { text: "days"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 } }
                Lbl { text: "Only liked" }        UiSwitch { checked: !!dlg.rules.liked; onToggled: v => dlg.setRule("liked", v) }
                Lbl { text: "Limit" }             UiField { Layout.fillWidth: true; mono: true; placeholderText: "no limit"; text: dlg.rules.limit || ""; onTextChanged: dlg.setRule("limit", dlg.num(text)) }
                Lbl { text: "Sort by" }
                UiCombo {
                    Layout.columnSpan: 3
                    entries: [{ label: "Artist, album, track", value: "artist" }, { label: "Title", value: "title" }, { label: "Album", value: "album" }, { label: "Year, newest first", value: "year" }, { label: "Most played", value: "plays" }, { label: "Recently played", value: "recent" }, { label: "Recently added", value: "added" }, { label: "Random (each time)", value: "random" }]
                    value: dlg.rules.sort || "artist"
                    onPicked: v => dlg.setRule("sort", v)
                }
            }
            Text { text: Store.smartTracks(dlg.rules).length + " tracks fit now"; color: Ui.accent; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
        }
        RowLayout {
            Layout.topMargin: 6
            Item { Layout.fillWidth: true }
            UiButton { label: "Cancel"; onClicked: dlg.close() }
            UiButton { primary: true; label: dlg.editId ? "Save" : "Create"; onClicked: dlg.save() }
        }
    }
}
