// PanelAnim.qml — animação de abrir/fechar dos painéis da barra (mesmo estilo do launcher).
// Uso: dentro de qualquer PopupWindow, "PanelAnim { win: popup }".
// Abrir/fechar sempre por Popups.show/hide/toggle, para o fechamento também ser animado.

import QtQuick
import "."

Item {
    id: anim

    required property var win            // o PopupWindow
    readonly property Item card: win ? win.contentItem : null
    property bool closing: false

    visible: false

    Translate { id: shift }

    Component.onCompleted: {
        if (card) card.transform = [shift]
        Popups.register(win, anim)
    }

    Connections {
        target: anim.win
        function onVisibleChanged() {
            if (anim.win.visible && !anim.closing) openAnim.restart()
        }
    }

    ParallelAnimation {
        id: openAnim
        NumberAnimation { target: anim.card; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
        NumberAnimation { target: shift; property: "y"; from: -8; to: 0; duration: 160; easing.type: Easing.OutCubic }
    }

    ParallelAnimation {
        id: closeAnim
        NumberAnimation { target: anim.card; property: "opacity"; to: 0; duration: 110; easing.type: Easing.InCubic }
        NumberAnimation { target: shift; property: "y"; to: -6; duration: 110; easing.type: Easing.InCubic }
        onFinished: {
            anim.closing = false
            anim.win.visible = false
        }
    }

    function open() {
        if (closing) {
            closeAnim.stop()
            closing = false
            openAnim.restart()
        }
        win.visible = true
    }

    function close() {
        if (!win.visible || closing) return
        openAnim.stop()
        closing = true
        closeAnim.restart()
    }
}
