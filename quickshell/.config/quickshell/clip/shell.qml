// shell.qml — BArch Clip: a video editor in the spirit of the iPhone's. Open a video (a button, a
// drop, `barch clip <file>`, "Open with" in Thunar), drag the corners to cut the borders away,
// turn or mirror it, trim the ends on the filmstrip, Preview (the edit encoded on the fly into
// mpv) and Save: a new file next to the original, or over it (the original goes to the trash).
// Own Shell ID; controls from ../ui; the ffmpeg side is clip.py, shared with `barch clip`.
//
//   qs -p ~/.config/quickshell/clip             barch clip [file]

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    function open(file) { if (file) Store.open(file); win.visible = true }
    Component.onCompleted: { const f = Quickshell.env("BARCH_CLIP_FILE"); if (f) Store.open(f); win.visible = true }

    IpcHandler {
        target: "app"
        function open(file: string): void { root.open(file) }
        function close(): void { Qt.quit() }
        // scripting: the same edits the mouse makes
        function crop(spec: string): string {     // "W:H:X:Y" in the frame as displayed, or "all"
            if (!Store.ready) return JSON.stringify({ ok: false, error: "no video" })
            if (spec === "all") Store.setCropRect(0, 0, Store.rotW, Store.rotH)
            else {
                const m = /^(\d+)[:x](\d+)[:+](\d+)[:+](\d+)$/.exec(spec)
                if (!m) return JSON.stringify({ ok: false, error: "crop is W:H:X:Y" })
                Store.aspect = "free"
                Store.setCropRect(Number(m[3]), Number(m[4]), Number(m[1]), Number(m[2]))
            }
            return JSON.stringify({ ok: true, crop: { w: Store.even(Store.cropW), h: Store.even(Store.cropH), x: Store.even(Store.cropX), y: Store.even(Store.cropY) } })
        }
        function rotate(deg: int): string { if (Store.ready) Store.rotateTo(((deg % 360) + 360) % 360); return JSON.stringify({ ok: Store.ready, rotate: Store.rotate }) }
        function trim(from: real, to: real): string { if (Store.ready) Store.setTrim(from, to); return JSON.stringify({ ok: Store.ready, from: Store.trimStart, to: Store.trimEnd }) }
        function seek(t: real): string { if (Store.ready) Store.seek(t); return JSON.stringify({ ok: Store.ready, playhead: Store.playhead }) }
        function aspect(a: string): string { if (Store.ready) Store.setAspect(a); return JSON.stringify({ ok: Store.ready, aspect: Store.aspect }) }
        function save(replace: bool): string { if (Store.ready && !Store.saving) Store.save(replace, ""); return JSON.stringify({ ok: Store.ready && Store.saving }) }
        function state(): string {
            return JSON.stringify({ file: Store.file, info: Store.info, rotate: Store.rotate, flipH: Store.flipH, flipV: Store.flipV,
                                    crop: Store.cropped ? { w: Store.even(Store.cropW), h: Store.even(Store.cropH), x: Store.even(Store.cropX), y: Store.even(Store.cropY) } : null,
                                    from: Store.trimStart, to: Store.trimEnd, saving: Store.saving, result: Store.result, command: Store.command })
        }
    }

    FloatingWindow {
        id: win
        title: "BArch Clip"
        implicitWidth: 1360
        implicitHeight: 900
        minimumSize: Qt.size(900, 600)
        color: Ui.base
        onVisibleChanged: if (!visible) Qt.quit()

        Item {
            anchors.fill: parent
            focus: true

            Shortcut { sequences: [StandardKey.Open]; onActivated: Store.pick() }
            Shortcut { sequences: [StandardKey.Save]; onActivated: if (Store.ready && !Store.saving) saveSheet.open() }
            Shortcut { sequences: ["Ctrl+W", "Ctrl+Q"]; onActivated: Qt.quit() }
            Shortcut { sequence: "Space"; onActivated: Store.preview() }
            Shortcut { sequence: "Left"; onActivated: Store.step(-1) }
            Shortcut { sequence: "Right"; onActivated: Store.step(1) }
            Shortcut { sequence: "Shift+Left"; onActivated: Store.seek(Store.playhead - 1) }
            Shortcut { sequence: "Shift+Right"; onActivated: Store.seek(Store.playhead + 1) }
            Shortcut { sequence: "Home"; onActivated: Store.seek(Store.trimStart) }
            Shortcut { sequence: "End"; onActivated: Store.seek(Store.trimEnd) }
            Shortcut { sequence: "I"; onActivated: Store.markStart() }
            Shortcut { sequence: "O"; onActivated: Store.markEnd() }
            Shortcut { sequence: "R"; onActivated: Store.rotateLeft() }
            Shortcut { sequence: "Shift+R"; onActivated: Store.rotateRight() }
            Shortcut { sequence: "H"; onActivated: Store.toggleFlipH() }
            Shortcut { sequence: "V"; onActivated: Store.toggleFlipV() }
            Shortcut { sequence: "0"; onActivated: Store.reset() }

            DropArea {
                anchors.fill: parent
                onDropped: drop => { if (drop.hasUrls && drop.urls.length) Store.open(drop.urls[0]) }
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                // ---------------- top bar: the file, Preview, Save
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 56
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        spacing: 10
                        Text { text: "󰕧"; color: Ui.accent; font.family: Ui.iconFont; font.pixelSize: 22 }
                        UiButton { label: "Open…"; icon: "󰝰"; tooltip: "Ctrl+O · or drop a video on the window"; onClicked: Store.pick() }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1
                            Text { Layout.fillWidth: true; text: Store.name || "Clip"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true; elide: Text.ElideMiddle }
                            Text { Layout.fillWidth: true; text: Store.loading ? "reading…" : Store.error ? Store.error : Store.infoLine || "crop, turn and trim a video, then save it"; color: Store.error ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                        }
                        Text {
                            visible: Store.ready && Store.edited
                            text: "→ " + Store.outW + "×" + Store.outH + " · " + Store.hms(Store.outLength)
                            color: Ui.accent; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1
                        }
                        UiButton { label: "Reset"; icon: "󰦛"; enabledBtn: Store.ready && Store.edited; tooltip: "Back to the whole video (0)"; onClicked: Store.reset() }
                        UiButton { label: "Preview"; icon: "󰐊"; enabledBtn: Store.ready; tooltip: "Play the edit in mpv, encoded on the fly (Space)"; onClicked: Store.preview() }
                        UiButton { label: Store.saving ? "Saving…" : "Save"; icon: "󰆓"; primary: true; enabledBtn: Store.ready && !Store.saving; tooltip: "Ctrl+S"; onClicked: saveSheet.open() }
                    }
                }

                // ---------------- the picture with the crop
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    CropView { anchors.fill: parent; visible: Store.ready }
                    // empty state
                    ColumnLayout {
                        anchors.centerIn: parent
                        visible: !Store.ready
                        spacing: 12
                        Text { Layout.alignment: Qt.AlignHCenter; text: "󰕧"; color: Ui.overlay; font.family: Ui.iconFont; font.pixelSize: 64 }
                        Text { Layout.alignment: Qt.AlignHCenter; text: Store.loading ? "Reading " + Store.name + "…" : Store.error ? Store.error : "Open a video, or drop one here"; color: Store.error ? Ui.red : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3 }
                        Text { Layout.alignment: Qt.AlignHCenter; visible: !Store.loading; text: "Drag the corners to cut the borders away, the ends of the filmstrip to trim, then Save."; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        UiButton { Layout.alignment: Qt.AlignHCenter; visible: !Store.loading; label: "Open a video…"; icon: "󰝰"; primary: true; onClicked: Store.pick() }
                    }
                }

                // ---------------- the tools: aspect, turn, mirror
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 48
                    color: Ui.raised
                    visible: Store.ready
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        spacing: 6
                        Text { text: "Aspect"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                        Repeater {
                            model: Store.aspects
                            Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool on: Store.aspect === modelData.id
                                implicitWidth: chipText.implicitWidth + 18
                                implicitHeight: 26
                                radius: 13
                                color: on ? Ui.accent : (chipMouse.containsMouse ? Ui.surface : "transparent")
                                border.width: on ? 0 : 1
                                border.color: Ui.surface
                                Text { id: chipText; anchors.centerIn: parent; text: chip.modelData.label; color: chip.on ? Ui.crust : Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; font.bold: chip.on }
                                MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Store.setAspect(chip.modelData.id) }
                            }
                        }
                        Rectangle { implicitWidth: 1; implicitHeight: 24; color: Ui.surface; Layout.leftMargin: 6; Layout.rightMargin: 6 }
                        UiButton { icon: "󰑤"; small: true; tooltip: "Turn left (R)"; onClicked: Store.rotateLeft() }
                        UiButton { icon: "󰑥"; small: true; tooltip: "Turn right (Shift+R)"; onClicked: Store.rotateRight() }
                        UiButton { icon: "󰯍"; small: true; primary: Store.flipH; tooltip: "Mirror left-right (H)"; onClicked: Store.toggleFlipH() }
                        UiButton { icon: "󰯎"; small: true; primary: Store.flipV; tooltip: "Mirror top-bottom (V)"; onClicked: Store.toggleFlipV() }
                        Text { visible: Store.rotate !== 0; text: Store.rotate + "°"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: "crop " + Store.even(Store.cropW) + "×" + Store.even(Store.cropH) + " at " + Store.even(Store.cropX) + "," + Store.even(Store.cropY)
                            color: Store.cropped ? Ui.text : Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                        }
                    }
                }

                // ---------------- the filmstrip and the times
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 14; Layout.rightMargin: 14
                    Layout.topMargin: 10; Layout.bottomMargin: 10
                    spacing: 6
                    visible: Store.ready
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: Store.hms(Store.trimStart); color: Store.trimmed ? Ui.accent : Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        UiButton { icon: "󰒭"; small: true; tooltip: "Start here (I)"; onClicked: Store.markStart() }
                        Item { Layout.fillWidth: true }
                        Text { text: "󰐌  " + Store.hms(Store.playhead); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize }
                        Text { text: "  ·  " + Store.hms(Store.outLength) + " kept"; color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                        Item { Layout.fillWidth: true }
                        UiButton { icon: "󰒮"; small: true; tooltip: "End here (O)"; onClicked: Store.markEnd() }
                        Text { text: Store.hms(Store.trimEnd); color: Store.trimmed ? Ui.accent : Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1 }
                    }
                    Filmstrip { Layout.fillWidth: true }
                }

                // ---------------- footer: status, the export's progress, the result
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    color: Ui.raised
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14
                        spacing: 10
                        Text { Layout.fillWidth: true; text: Store.status; color: Store.statusBad ? Ui.red : Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                        Rectangle {
                            visible: Store.saving
                            implicitWidth: 220; implicitHeight: 6; radius: 3
                            color: Ui.surface
                            Rectangle { width: parent.width * Store.progress; height: parent.height; radius: 3; color: Ui.accent; Behavior on width { NumberAnimation { duration: 150 } } }
                        }
                        Text { visible: Store.saving; text: Math.round(Store.progress * 100) + " %" + (Store.speed ? "  " + Store.speed : "") + (Store.encoder ? "  " + Store.encoder : ""); color: Ui.subtext; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2 }
                        UiButton { visible: Store.saving; label: "Cancel"; small: true; danger: true; onClicked: Store.cancelSave() }
                        UiButton { visible: !!Store.result && !Store.saving; label: "Play"; icon: "󰐊"; small: true; onClicked: Store.openResult() }
                        UiButton { visible: !!Store.result && !Store.saving; label: "Show in folder"; icon: "󰉋"; small: true; onClicked: Store.showResult() }
                        UiButton { visible: !!Store.result && !Store.saving && Store.result.file !== Store.file; label: "Open the result"; icon: "󰕧"; small: true; tooltip: "Edit the saved file further"; onClicked: Store.open(Store.result.file) }
                        Text { visible: Store.ready && !Store.saving; text: Store.fps > 0 ? Math.round(Store.fps * 100) / 100 + " fps" : ""; color: Ui.overlay; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                    }
                }
            }

            // ---------------- the save sheet: a new file, or over the original
            Popup {
                id: saveSheet
                property bool replace: false
                anchors.centerIn: parent
                width: 520
                modal: true
                focus: true
                padding: 18
                onOpened: replace = false
                background: Rectangle { color: Ui.raised; radius: Ui.cardRadius; border.width: 1; border.color: Ui.surface }
                contentItem: ColumnLayout {
                    spacing: 12
                    Text { text: "Save the video"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 3; font.bold: true }
                    Text {
                        Layout.fillWidth: true
                        text: Store.outW + "×" + Store.outH + " · " + Store.hms(Store.outLength) + (Store.info && Store.info.hdr ? " · HDR kept" : "")
                              + (Store.edited ? "" : " · nothing was changed, the video is re-encoded as it is")
                        color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 64; radius: Ui.radius
                        color: Ui.sunken; border.width: 1; border.color: Ui.surface
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 10
                            spacing: 10
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text { Layout.fillWidth: true; text: saveSheet.replace ? Store.name : Store.suggestedName; color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize; elide: Text.ElideMiddle }
                                Text { Layout.fillWidth: true; text: saveSheet.replace ? "over the original · the old file goes to the trash" : "a new file next to the original (-2, -3 if the name is taken)"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2; elide: Text.ElideRight }
                            }
                            Text { text: "Replace original"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1 }
                            UiSwitch { checked: saveSheet.replace; onToggled: v => saveSheet.replace = v }
                        }
                    }
                    Text { Layout.fillWidth: true; text: Store.command; color: Ui.overlay; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 3; wrapMode: Text.WrapAnywhere }
                    RowLayout {
                        Layout.fillWidth: true
                        Item { Layout.fillWidth: true }
                        UiButton { label: "Cancel"; onClicked: saveSheet.close() }
                        UiButton { label: saveSheet.replace ? "Replace" : "Save"; icon: "󰆓"; primary: !saveSheet.replace; danger: saveSheet.replace; onClicked: { saveSheet.close(); Store.save(saveSheet.replace, "") } }
                    }
                }
            }
        }
    }
}
