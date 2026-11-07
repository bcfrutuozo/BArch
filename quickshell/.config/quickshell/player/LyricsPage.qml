import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the lyrics of the track playing: a .lrc next to the file or a LYRICS tag (through the pipeline's API),
// else LRCLIB (lrclib.net, synced when it has them); kept in ~/.cache/barch/player/lyrics. Synced lines
// follow the music and a click seeks there.
Item {
    id: page
    property var track: Player.current
    property var lines: []           // [{ t, text }] (t = -1 for plain text)
    property bool synced: false
    property string source: ""
    property bool busy: false
    property string error: ""
    property string loadedKey: ""
    readonly property int currentLine: {
        if (!synced) return -1
        let i = -1
        for (let k = 0; k < lines.length; k++) { if (lines[k].t <= Player.position + 0.3) i = k; else break }
        return i
    }
    onCurrentLineChanged: if (currentLine >= 0 && !view.moving) view.positionViewAtIndex(currentLine, ListView.Center)
    onTrackChanged: load(false)
    Component.onCompleted: load(false)

    function hash(s) { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0; return h.toString(16) }
    function parse(text, isSynced) {
        const out = []
        if (!isSynced) { for (const l of (text || "").split(/\r?\n/)) out.push({ t: -1, text: l }); return out }
        for (const l of (text || "").split(/\r?\n/)) {
            const stamps = [...l.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)]
            if (!stamps.length) continue
            const body = l.replace(/\[[^\]]*\]/g, "").trim()
            for (const s of stamps) out.push({ t: parseInt(s[1]) * 60 + parseFloat(s[2]), text: body })
        }
        out.sort((a, b) => a.t - b.t)
        return out
    }
    function load(force) {
        const t = track
        if (!t) { lines = []; synced = false; source = ""; error = ""; loadedKey = ""; return }
        if (t.key === loadedKey && !force) return
        loadedKey = t.key
        lines = []; synced = false; source = ""; error = ""; busy = true
        const cache = Store.cacheDir + "/lyrics/" + hash(t.key) + ".json"
        const api = Store.url + "/api/catalog/lyrics?folder=" + Store.enc(t.folder) + "&file=" + Store.enc(t.file)
        const script = 'f=$1; [ "$8" = 1 ] && rm -f "$f"; if [ -s "$f" ]; then cat "$f"; exit 0; fi; ' +
            'a=$(curl -sS --max-time 20 -H "X-Barch-Token: $T" "$2" 2>/dev/null); ' +
            'if printf %s "$a" | jq -e \'((.synced // "") != "") or ((.plain // "") != "")\' >/dev/null 2>&1; then printf %s "$a" > "$f"; cat "$f"; exit 0; fi; ' +
            'b=$(curl -sS --max-time 20 -G "https://lrclib.net/api/get" --data-urlencode "artist_name=$3" --data-urlencode "track_name=$4" --data-urlencode "album_name=$5" --data-urlencode "duration=$6" -A "$7") || { echo \'{"ok":false,"error":"lrclib not reachable"}\'; exit 0; }; ' +
            'printf %s "$b" | jq -c \'{ok: true, synced: (.syncedLyrics // ""), plain: (.plainLyrics // ""), source: (if (.syncedLyrics // .plainLyrics // "") != "" then "lrclib" else "" end)}\' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" && cat "$f" || echo \'{"ok":true,"synced":"","plain":"","source":""}\''
        const p = Store.run(["env", "T=" + Store.token, "sh", "-c", script, "sh", cache, api, t.artist, t.title, t.album, String(Math.round(t.length)), "BArch Player (github.com/bcfrutuozo/BArch)", force ? "1" : "0"], (out, err, code) => {
            if (page.loadedKey !== t.key) return
            page.busy = false
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (!d) { page.error = "no answer" + (err.trim() ? ": " + err.trim().split("\n").pop() : ""); return }
            if (d.ok === false) { page.error = d.error || "no lyrics"; return }
            if (d.synced) { page.synced = true; page.lines = page.parse(d.synced, true) }
            else if (d.plain) { page.synced = false; page.lines = page.parse(d.plain, false) }
            else page.error = "no lyrics found for this track"
            page.source = d.source || ""
        })
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 24; anchors.rightMargin: 24
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Cover { album: page.track ? Store.albumByKey[page.track.albumKey] : null; size: 64 }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: page.track ? page.track.title : "Nothing playing"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 4; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: page.track ? page.track.artist + " · " + page.track.album : ""; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize; elide: Text.ElideRight; Layout.fillWidth: true }
                Text {
                    text: page.busy ? "looking for the lyrics…" : page.error ? page.error : page.lines.length ? (page.synced ? "synced" : "plain text") + (page.source === "lrclib" ? " · lrclib.net" : page.source === "lrc" ? " · .lrc next to the file" : page.source === "tag" ? " · LYRICS tag" : "") : ""
                    color: page.error ? Ui.yellow : Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2
                }
            }
            UiButton { icon: "󰑐"; label: "Look again"; small: true; enabledBtn: !!page.track && !page.busy; tooltip: "forget the cached answer and search again"; onClicked: page.load(true) }
        }
        ListView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: page.lines
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            header: Item { height: view.height / 3 }
            footer: Item { height: view.height / 2 }
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: ListView.view.width
                height: Math.max(26, lt.implicitHeight + 10)
                readonly property bool now: page.synced && row.index === page.currentLine
                readonly property bool past: page.synced && row.index < page.currentLine
                Text {
                    id: lt
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 20 }
                    text: row.modelData.text === "" ? "♪" : row.modelData.text
                    color: row.now ? Ui.text : row.past ? Ui.overlay : Ui.subtext
                    font.family: Ui.font
                    font.pixelSize: page.synced ? Ui.fontSize + (row.now ? 10 : 6) : Ui.fontSize + 3
                    font.bold: row.now
                    wrapMode: Text.Wrap
                    opacity: row.modelData.text === "" ? 0.4 : 1
                    Behavior on font.pixelSize { NumberAnimation { duration: 160 } }
                    Behavior on color { ColorAnimation { duration: 160 } }
                }
                MouseArea { anchors.fill: parent; enabled: page.synced; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: Player.seek(row.modelData.t) }
            }
        }
    }
}
