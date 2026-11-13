// RegionPicker.qml — the VPN region list (VPN Region tile): a filter and the regions by latency.
// Part of the Control Center's panel (ControlCenter.qml), shown while its tile is chosen.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../theme"
import "../vpn"

ColumnLayout {
    id: picker
    // the Control Center (control/ControlCenter.qml) whose state it shows and sets
    required property var center
    function focusField() { regionField.forceActiveFocus() }
    visible: picker.center.chooseRegion
    Layout.fillWidth: true
    spacing: 6

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 32
        radius: Theme.buttonRadius
        color: Theme.surface
        border.width: 1
        border.color: regionField.activeFocus ? Theme.accent : "transparent"
        RowLayout {
            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
            spacing: 8
            Text { text: picker.center.glyph(0xF0349); color: Theme.dim; font.family: Theme.iconFont; font.pixelSize: Theme.fontSize }   // magnify
            TextInput {
                id: regionField
                Layout.fillWidth: true
                color: Theme.fg; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                clip: true
                onTextChanged: picker.center.regionFilter = text
                Keys.onEscapePressed: { picker.center.chooseRegion = false; text = "" }
                Keys.onReturnPressed: if (picker.center.regionList.length > 0) picker.center.pickRegion(picker.center.regionList[0].id)
                Text {
                    anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                    visible: regionField.text === ""
                    text: "Filter regions (" + Vpn.regions.length + ")"
                    color: Theme.overlay; font.family: Theme.font; font.pixelSize: Theme.fontSize - 1
                }
            }
            Text {
                visible: Vpn.measuring
                text: "measuring…"
                color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
            }
        }
    }

    ListView {
        id: regionView
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(contentHeight, 240)
        clip: true
        model: picker.center.regionList
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
            id: regionRow
            required property var modelData
            readonly property bool selected: Vpn.preferred === modelData.id
            width: regionView.width
            implicitHeight: 32
            radius: Theme.buttonRadius
            color: regionMouse.containsMouse ? Theme.hover : "transparent"
            RowLayout {
                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                spacing: 8
                Text {
                    text: regionRow.modelData.name
                    color: regionRow.selected ? Theme.accent : Theme.fg
                    font.family: Theme.font; font.pixelSize: Theme.fontSize - 1; font.bold: regionRow.selected
                    elide: Text.ElideRight; Layout.fillWidth: true
                }
                Text {
                    visible: text !== ""
                    text: regionRow.modelData.sub !== undefined ? regionRow.modelData.sub
                        : regionRow.modelData.country + (regionRow.modelData.pf ? "  ·  pf" : "") + (regionRow.modelData.geo ? "  ·  geo" : "")
                    color: Theme.dim; font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                }
                Text {
                    Layout.preferredWidth: 48
                    horizontalAlignment: Text.AlignRight
                    text: Vpn.ms(regionRow.modelData.latency)
                    color: regionRow.modelData.latency !== null && regionRow.modelData.latency < 0.05 ? Theme.good : Theme.dim
                    font.family: Theme.font; font.pixelSize: Theme.fontSize - 3
                }
            }
            MouseArea {
                id: regionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: picker.center.pickRegion(regionRow.modelData.id)
            }
        }
    }
}
