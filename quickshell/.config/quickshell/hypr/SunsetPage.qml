import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "hypr.js" as H

// hyprsunset.conf: the night light schedule (profiles by time of day)
Item {
    id: page

    readonly property var items: Store.sunsetItems
    readonly property var profiles: H.blocksOf(items, "profile")
    readonly property var maxGamma: { for (const it of items) if (it.kind === "kv" && it.key === "max-gamma") return it.value; return "" }

    function edited() { return H.clone(items) }
    function setProfile(index, key, value) {
        const it = edited()
        const p = H.blocksOf(it, "profile")[index]
        H.blockSet(p, key, value)
        Store.saveSunset(it)
    }
    function setMode(index, mode) {
        const it = edited()
        const p = H.blocksOf(it, "profile")[index]
        H.blockSet(p, "identity", ""); H.blockSet(p, "temperature", ""); H.blockSet(p, "gamma", "")
        if (mode === "identity") H.blockSet(p, "identity", "true")
        else if (mode === "temperature") H.blockSet(p, "temperature", "4500")
        else H.blockSet(p, "gamma", "80")
        Store.saveSunset(it)
    }
    function modeOf(p) { return H.blockGet(p, "identity") === "true" ? "identity" : H.blockGet(p, "gamma") !== undefined && H.blockGet(p, "temperature") === undefined ? "gamma" : "temperature" }
    function addProfile() {
        const it = edited()
        it.push({ kind: "blank" }, { kind: "comment", text: "# New profile" }, { kind: "block", name: "profile", items: [{ kind: "kv", key: "time", value: "20:00" }, { kind: "kv", key: "temperature", value: "4500" }] })
        Store.saveSunset(it)
    }
    function removeProfile(index) {
        const it = edited()
        const p = H.blocksOf(it, "profile")[index]
        let i = it.indexOf(p)
        it.splice(i, 1)
        while (i > 0 && it[i - 1] && (it[i - 1].kind === "comment" || it[i - 1].kind === "blank")) { if (it[i - 1].kind === "blank" && (i - 2 < 0 || it[i - 2].kind !== "comment")) { it.splice(i - 1, 1); break } it.splice(i - 1, 1); i-- }
        Store.saveSunset(it)
    }
    function setMaxGamma(v) {
        const it = edited()
        for (let i = 0; i < it.length; i++) if (it[i].kind === "kv" && it[i].key === "max-gamma") { if (v === "") it.splice(i, 1); else it[i].value = v; Store.saveSunset(it); return }
        if (v !== "") { it.unshift({ kind: "kv", key: "max-gamma", value: v }, { kind: "blank" }); Store.saveSunset(it) }
    }
    function tempColor(k) {
        k = Math.max(1000, Math.min(20000, Number(k) || 6500)) / 100
        let r, g, b
        if (k <= 66) { r = 255; g = 99.47 * Math.log(k) - 161.12; b = k <= 19 ? 0 : 138.52 * Math.log(k - 10) - 305.04 }
        else { r = 329.7 * Math.pow(k - 60, -0.1332); g = 288.12 * Math.pow(k - 60, -0.0755); b = 255 }
        const c = x => Math.max(0, Math.min(255, x)) / 255
        return Qt.rgba(c(r), c(g), c(b), 1)
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: parent.width
            spacing: 12
            Text {
                Layout.margins: 12; Layout.bottomMargin: 0; Layout.fillWidth: true
                text: "hyprsunset.conf: each profile starts at its time and lasts until the next one. identity = no filter; temperature in kelvin (6500 neutral, lower is warmer); gamma in percent. Every change restarts hyprsunset. The Night Light tile of the bar toggles the filter on top of this schedule."
                color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
            }
            Card {
                Layout.margins: 12
                title: "Profiles"
                headerItems: [
                    Text { text: "max-gamma"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 },
                    UiField { Layout.preferredWidth: 70; mono: true; text: page.maxGamma; placeholderText: "100"; onCommitted: v => page.setMaxGamma(v.trim()) },
                    UiButton { label: "Add profile"; icon: "󰐕"; small: true; onClicked: page.addProfile() },
                    UiButton { icon: "󰏫"; small: true; tooltip: "open the file"; onClicked: Store.openFile(Store.sunsetPath) }
                ]
                Repeater {
                    model: page.profiles
                    Rectangle {
                        id: pc
                        required property int index
                        required property var modelData
                        readonly property var p: modelData
                        readonly property string mode: page.modeOf(p)
                        Layout.fillWidth: true
                        implicitHeight: row.implicitHeight + 20
                        radius: Ui.radius
                        color: Ui.sunken
                        border.width: 1; border.color: Ui.surface
                        RowLayout {
                            id: row
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 10 }
                            spacing: 10
                            Rectangle {
                                width: 28; height: 28; radius: 14
                                color: pc.mode === "temperature" ? page.tempColor(H.blockGet(pc.p, "temperature")) : pc.mode === "gamma" ? Qt.rgba(1, 1, 1, Math.max(0.1, Number(H.blockGet(pc.p, "gamma") || 100) / 100)) : "#ffffff"
                                border.width: 1; border.color: Ui.surface
                            }
                            Text { text: "at"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                            UiField { Layout.preferredWidth: 80; mono: true; text: H.blockGet(pc.p, "time") || ""; placeholderText: "HH:MM"; bad: !/^\d{1,2}:\d{2}$/.test(text); onCommitted: v => { if (/^\d{1,2}:\d{2}$/.test(v)) page.setProfile(pc.index, "time", v) } }
                            UiCombo {
                                Layout.preferredWidth: 150
                                entries: [{ label: "no filter", value: "identity" }, { label: "temperature", value: "temperature" }, { label: "gamma", value: "gamma" }]
                                value: pc.mode
                                onPicked: v => { if (v !== pc.mode) page.setMode(pc.index, v) }
                            }
                            UiNumber {
                                visible: pc.mode === "temperature"
                                value: Number(H.blockGet(pc.p, "temperature") || 6500); min: 1000; max: 20000; step: 100
                                onChanged: v => page.setProfile(pc.index, "temperature", String(v))
                            }
                            Text { visible: pc.mode === "temperature"; text: "K"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                            UiNumber {
                                visible: pc.mode === "gamma"
                                value: Number(H.blockGet(pc.p, "gamma") || 100); min: 10; max: 200
                                onChanged: v => page.setProfile(pc.index, "gamma", String(v))
                            }
                            Text { visible: pc.mode === "gamma"; text: "%"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                            Item { Layout.fillWidth: true }
                            UiButton { icon: "󰆴"; small: true; danger: true; tooltip: "remove"; onClicked: page.removeProfile(pc.index) }
                        }
                    }
                }
                Text { visible: page.profiles.length === 0; text: "no profiles: hyprsunset applies nothing by schedule"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
            }
        }
    }
}
