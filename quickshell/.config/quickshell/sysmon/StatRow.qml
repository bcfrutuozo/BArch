// StatRow.qml — linha do painel do SysMonitor: rótulo, valor e barra de progresso.

import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: row

    required property var widget      // o SysMonitor (cores e fontes)
    property string label: ""
    property string value: ""
    property real fraction: -1        // 0..1; negativo esconde a barra
    property int tone: 0              // 0 normal, 1 aviso, 2 crítico

    readonly property color toneColor: tone === 2 ? widget.crit : tone === 1 ? widget.warn : widget.accent

    Layout.fillWidth: true
    spacing: 4

    RowLayout {
        Layout.fillWidth: true
        Text {
            Layout.fillWidth: true
            text: row.label
            color: row.widget.dim
            font.family: row.widget.fontFamily
            font.pixelSize: row.widget.fontSize - 1
        }
        Text {
            text: row.value
            color: row.tone > 0 ? row.toneColor : row.widget.fg
            font.family: row.widget.fontFamily
            font.pixelSize: row.widget.fontSize
        }
    }

    Rectangle {
        visible: row.fraction >= 0
        Layout.fillWidth: true
        implicitHeight: 4
        radius: 2
        color: row.widget.track

        Rectangle {
            height: parent.height
            width: parent.width * Math.max(0, Math.min(1, row.fraction))
            radius: 2
            color: row.toneColor
            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 200 } }
        }
    }
}
