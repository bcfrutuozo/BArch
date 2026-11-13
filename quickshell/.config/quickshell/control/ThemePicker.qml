// ThemePicker.qml — the palettes (Themes tile): dark and light, one of each pinned; the editor below them.
// Part of the Control Center's panel (ControlCenter.qml), shown while its tile is chosen.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import "../theme"

ColumnLayout {
    id: picker
    // the Control Center (control/ControlCenter.qml) whose state it shows and sets
    required property var center
    visible: picker.center.chooseTheme
    Layout.fillWidth: true
    spacing: 6
    Repeater {
        model: [
            { title: "Dark", mode: "dark", ids: Theme.darkFlavors },
            { title: "Light", mode: "light", ids: Theme.lightFlavors }
        ]
        ColumnLayout {
            id: group
            required property var modelData
            Layout.fillWidth: true
            spacing: 4
            Text {
                text: group.modelData.title
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: Theme.fontSize - 2
            }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: group.modelData.ids
                    Rectangle {
                        id: chip
                        required property string modelData
                        readonly property var info: Theme.flavorInfo(modelData)
                        readonly property bool selected: info.active
                        implicitWidth: chipRow.implicitWidth + 20
                        implicitHeight: 30
                        radius: 15
                        color: chipMouse.containsMouse ? Theme.hover : "transparent"
                        border.width: selected ? 1.5 : 1
                        border.color: selected ? Theme.accent : Theme.border
                        RowLayout {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: 7
                            // amostra: fundo da paleta com o destaque por cima
                            Rectangle {
                                implicitWidth: 16; implicitHeight: 16; radius: 8
                                color: chip.info.base
                                border.width: 1; border.color: chip.info.surface
                                Rectangle {
                                    anchors.right: parent.right; anchors.bottom: parent.bottom
                                    width: 9; height: 9; radius: 4.5
                                    color: chip.info.accent
                                }
                            }
                            Text {
                                text: chip.info.label
                                color: chip.selected ? Theme.accent : Theme.fg
                                font.family: Theme.font
                                font.pixelSize: Theme.fontSize - 2
                                font.bold: chip.selected
                            }
                        }
                        MouseArea {
                            id: chipMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Theme.setFlavor(group.modelData.mode, chip.modelData)
                        }
                    }
                }
            }
        }
    }
    // o editor (quickshell/palette): paletas novas, a partir de uma imagem, ajustes ao vivo
    Rectangle {
        implicitWidth: editRow.implicitWidth + 20
        implicitHeight: 30
        radius: 15
        color: editMouse.containsMouse ? Theme.hover : "transparent"
        border.width: 1
        border.color: Theme.border
        RowLayout {
            id: editRow
            anchors.centerIn: parent
            spacing: 7
            Text { text: picker.center.glyph(0xF03EB); color: Theme.accent; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize }   // md-pencil
            Text { text: "Edit palettes…"; color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 2 }
        }
        MouseArea {
            id: editMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { Quickshell.execDetached(["barch", "theme", "edit"]); picker.center.closePanel() }
        }
    }
}
