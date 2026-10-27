// MinimizedWidget.qml — janelas minimizadas na barra (Super+M minimiza).
// Um ícone por janela; clique devolve a janela ao workspace de onde ela saiu.
// Passar o mouse mostra o título; clique direito abre o menu da janela. Some quando não há nada minimizado.

import QtQuick
import Quickshell
import Quickshell.Widgets
import "../theme"
import "../windowmenu"

Item {
    id: root
    visible: Minimized.windows.length > 0
    implicitWidth: row.implicitWidth
    implicitHeight: Math.max(row.implicitHeight, 18)

    function iconFor(cls) {
        const e = DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(cls) : null
        return Quickshell.iconPath(e && e.icon ? e.icon : (cls || "").toLowerCase(), "application-x-executable")
    }

    WindowMenu { id: menu }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Repeater {
            model: Minimized.windows

            Item {
                id: item
                required property var modelData
                width: 22; height: 22

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: mouse.containsMouse ? Theme.hover : "transparent"
                }
                IconImage {
                    anchors.centerIn: parent
                    implicitSize: 16
                    source: root.iconFor(item.modelData.cls)
                    opacity: mouse.containsMouse ? 1 : 0.75
                }
                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: ev => {
                        if (ev.button === Qt.RightButton)
                            menu.show(item, ev.x, item.height + 10, { address: item.modelData.address, title: item.modelData.title,
                                ws: item.modelData.ws, floating: false, pinned: false, minimized: true })
                        else Minimized.restore(item.modelData.address)
                    }
                }

                // título ao passar o mouse
                PopupWindow {
                    visible: mouse.containsMouse && !menu.visible
                    anchor.item: item
                    anchor.rect.x: item.width / 2
                    anchor.rect.y: item.height + 12
                    anchor.rect.width: 1
                    anchor.rect.height: 1
                    anchor.edges: Edges.Top
                    anchor.gravity: Edges.Bottom
                    implicitWidth: Math.min(360, tip.implicitWidth + 20)
                    implicitHeight: tip.implicitHeight + 12
                    color: "transparent"
                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.buttonRadius
                        color: Theme.bg
                        border.color: Theme.border
                        border.width: 1
                        Text {
                            id: tip
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, 340)
                            text: item.modelData.title
                                + (item.modelData.ws !== "" ? "  ·  " + (item.modelData.ws.startsWith("special:") ? "Scratchpad" : "Workspace " + item.modelData.ws) : "")
                            color: Theme.fg
                            font.family: Theme.font
                            font.pixelSize: Theme.fontSize - 2
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
