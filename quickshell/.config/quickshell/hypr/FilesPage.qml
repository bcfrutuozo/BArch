import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// the config files, the errors, what this app saved
Item {
    id: page

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
                title: "Hyprland " + Store.version
                subtitle: "config: " + Store.hyprDir + "  ·  " + Store.options.length + " options known by this version  ·  " + Store.overrideCount + " saved by this app"
                headerItems: [
                    UiButton { label: "Reload Hyprland"; icon: "󰑐"; small: true; onClicked: Store.reload() },
                    UiButton { label: "Refresh"; icon: "󰑐"; small: true; onClicked: Store.refreshAll() }
                ]
                Text {
                    visible: Store.configErrors !== ""
                    Layout.fillWidth: true
                    text: "config errors:\n" + Store.configErrors
                    color: Ui.red; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                }
                Text {
                    visible: Store.applyErrors !== ""
                    Layout.fillWidth: true
                    text: "settings.json could not be applied in full:\n" + Store.applyErrors
                    color: Ui.yellow; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap
                }
                Text {
                    visible: Store.configErrors === "" && Store.applyErrors === ""
                    text: "no config errors"
                    color: Ui.green; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1
                }
            }

            Card {
                Layout.margins: 12; Layout.topMargin: 0; Layout.bottomMargin: 0
                title: "Lua files"
                subtitle: "hand-written config (symlinks into ~/BArch/hypr). Open: foot + $EDITOR"
                Repeater {
                    model: Store.fileNames
                    RowLayout {
                        id: fr
                        required property var modelData
                        spacing: 8
                        Text { Layout.preferredWidth: 260; text: Store.shortPath(fr.modelData); color: Ui.text; font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 1; elide: Text.ElideMiddle }
                        Text { Layout.fillWidth: true; text: (Store.files[fr.modelData] || "").split("\n").length + " lines"; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize - 2 }
                        UiButton { icon: "󰏫"; small: true; tooltip: "open"; onClicked: Store.openFile(fr.modelData) }
                    }
                }
            }

            Card {
                Layout.margins: 12; Layout.topMargin: 0
                title: "settings.json"
                subtitle: Store.settingsPath + "  ·  applied by conf/settings.lua on top of the files; saved with the repo"
                headerItems: [
                    UiButton { icon: "󰏫"; small: true; tooltip: "open"; onClicked: Store.openFile(Store.settingsPath) },
                    UiButton { label: "Reset everything"; small: true; danger: true; enabledBtn: Object.keys(Store.settings).length > 0; tooltip: "forget every change made in this app (the files stay)"; onClicked: confirmReset.open() }
                ]
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Math.min(500, jsonText.implicitHeight + 16)
                    radius: Ui.radius
                    color: Ui.sunken
                    border.width: 1; border.color: Ui.surface
                    Flickable {
                        anchors.fill: parent; anchors.margins: 8
                        contentHeight: jsonText.implicitHeight
                        clip: true
                        TextEdit {
                            id: jsonText
                            width: parent.width
                            readOnly: true
                            selectByMouse: true
                            text: JSON.stringify(Store.settings, null, 2)
                            color: Ui.text; selectionColor: Ui.accent; selectedTextColor: Ui.crust
                            font.family: Ui.monoFont; font.pixelSize: Ui.fontSize - 2
                            wrapMode: TextEdit.Wrap
                        }
                    }
                }
            }
            Item { height: 12 }
        }
    }

    Popup {
        id: confirmReset
        anchors.centerIn: parent
        modal: true
        padding: 20
        background: Rectangle { color: Ui.raised; border.width: 1; border.color: Ui.surface; radius: Ui.cardRadius }
        contentItem: ColumnLayout {
            spacing: 14
            Text { text: "Forget everything saved by this app?"; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize + 1; font.bold: true }
            Text { text: "settings.json becomes empty and Hyprland reloads with the files alone."; color: Ui.subtext; font.family: Ui.font; font.pixelSize: Ui.fontSize }
            RowLayout {
                Item { Layout.fillWidth: true }
                UiButton { label: "Cancel"; onClicked: confirmReset.close() }
                UiButton { label: "Reset"; danger: true; onClicked: { Store.settings = {}; Store.save(); Store.reload(); confirmReset.close() } }
            }
        }
    }
}
