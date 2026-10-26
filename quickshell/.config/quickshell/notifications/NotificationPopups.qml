// NotificationPopups.qml — balões de notificação no canto superior direito, logo abaixo da barra.
// Entram deslizando da direita, os mais novos em cima (no máximo 5 ao mesmo tempo).

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../theme"
import "."

Scope {
    id: root

    property string screenName: "HDMI-A-2"    // mesmo monitor da barra
    property int maxVisible: 5
    readonly property int cardWidth: 400
    readonly property var shown: Notifs.popups.slice(-maxVisible).reverse()

    PanelWindow {
        id: win

        screen: {
            const s = Quickshell.screens
            for (let i = 0; i < s.length; i++) if (s[i].name === root.screenName) return s[i]
            return s[0]
        }

        visible: root.shown.length > 0
        color: "transparent"
        anchors { top: true; right: true }
        margins {
            top: Theme.gap + Theme.islandHeight + Theme.popupGap
            right: Theme.gap
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-notifications"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        implicitWidth: root.cardWidth
        implicitHeight: Math.max(1, stack.implicitHeight)

        Column {
            id: stack
            width: root.cardWidth
            spacing: 8

            Repeater {
                model: ScriptModel { values: root.shown }

                NotificationCard {
                    required property var modelData
                    entry: modelData
                    popup: true
                    width: root.cardWidth
                }
            }

            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "x"; from: root.cardWidth; to: 0; duration: 240; easing.type: Easing.OutCubic }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200 }
                }
            }
            move: Transition {
                NumberAnimation { properties: "x,y"; duration: 220; easing.type: Easing.OutCubic }
            }
        }
    }
}
