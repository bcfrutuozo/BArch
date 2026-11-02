import QtQuick
import QtQuick.Controls

// a small tooltip (hover for 600 ms)
ToolTip {
    id: tip
    property bool when: false
    visible: when && text !== ""
    delay: 600
    contentItem: Text { text: tip.text; color: Ui.text; font.family: Ui.font; font.pixelSize: Ui.fontSize - 1; wrapMode: Text.Wrap; width: Math.min(implicitWidth, 420) }
    background: Rectangle { color: Ui.raised; border.width: 1; border.color: Ui.surface; radius: Ui.radius }
    padding: 8
}
