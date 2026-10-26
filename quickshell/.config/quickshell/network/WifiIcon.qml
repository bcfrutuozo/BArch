// WifiIcon.qml — ícone de Wi-Fi desenhado em traço fino, com nível de sinal.
// Os ícones de sinal da Nerd Font são leques preenchidos (ruins para OLED);
// aqui são três arcos finos e um ponto: os acesos mostram o nível, os apagados ficam escuros.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    property int level: 4           // 1 = só o ponto … 4 = ponto + 3 arcos
    property color on: "#cdd6f4"
    property color off: "#45475a"
    property real stroke: 1.5
    property real size: 16

    implicitWidth: size * 1.1
    implicitHeight: size

    readonly property real cx: width / 2
    readonly property real cy: height * 0.84
    readonly property real k: Math.SQRT1_2      // cos/sen de 45°

    // ponto central
    Rectangle {
        width: icon.stroke * 2.2
        height: width
        radius: width / 2
        x: icon.cx - width / 2
        y: icon.cy - height / 2
        color: icon.level >= 1 ? icon.on : icon.off
    }

    // três arcos de 90°, do menor para o maior
    Repeater {
        model: 3

        Shape {
            id: arc
            required property int index
            readonly property real r: icon.height * (0.27 + index * 0.24)

            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeWidth: icon.stroke
                strokeColor: icon.level >= arc.index + 2 ? icon.on : icon.off
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap

                startX: icon.cx - arc.r * icon.k
                startY: icon.cy - arc.r * icon.k

                PathArc {
                    x: icon.cx + arc.r * icon.k
                    y: icon.cy - arc.r * icon.k
                    radiusX: arc.r
                    radiusY: arc.r
                    direction: PathArc.Clockwise
                }
            }
        }
    }
}
