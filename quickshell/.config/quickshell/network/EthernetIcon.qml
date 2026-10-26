// EthernetIcon.qml — porta de rede (RJ45) desenhada em traço fino, no mesmo estilo do WifiIcon.
// Os ícones de cabo da Nerd Font são preenchidos ou parecem um computador; este é só contorno.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    property color color: "#cdd6f4"
    property real stroke: 1.5
    property real size: 16

    implicitWidth: size * 1.1
    implicitHeight: size

    // coordenadas em fração do tamanho, centralizadas na largura
    readonly property real s: height
    readonly property real ox: (width - s) / 2
    function px(f) { return ox + f * s }
    function py(f) { return f * s }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        // corpo da porta com o encaixe da trava embaixo
        ShapePath {
            strokeWidth: icon.stroke
            strokeColor: icon.color
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap

            startX: icon.px(0.14); startY: icon.py(0.20)
            PathLine { x: icon.px(0.86); y: icon.py(0.20) }
            PathLine { x: icon.px(0.86); y: icon.py(0.68) }
            PathLine { x: icon.px(0.66); y: icon.py(0.68) }
            PathLine { x: icon.px(0.66); y: icon.py(0.84) }
            PathLine { x: icon.px(0.34); y: icon.py(0.84) }
            PathLine { x: icon.px(0.34); y: icon.py(0.68) }
            PathLine { x: icon.px(0.14); y: icon.py(0.68) }
            PathLine { x: icon.px(0.14); y: icon.py(0.20) }
        }

        // contatos dourados da porta (quatro traços curtos no topo)
        ShapePath {
            strokeWidth: icon.stroke
            strokeColor: icon.color
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            startX: icon.px(0.32); startY: icon.py(0.20)
            PathLine { x: icon.px(0.32); y: icon.py(0.36) }
            PathMove { x: icon.px(0.44); y: icon.py(0.20) }
            PathLine { x: icon.px(0.44); y: icon.py(0.36) }
            PathMove { x: icon.px(0.56); y: icon.py(0.20) }
            PathLine { x: icon.px(0.56); y: icon.py(0.36) }
            PathMove { x: icon.px(0.68); y: icon.py(0.20) }
            PathLine { x: icon.px(0.68); y: icon.py(0.36) }
        }
    }
}
