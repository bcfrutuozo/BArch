pragma Singleton

// Popups.qml — controla os painéis da barra:
//  - só um painel aberto por vez (cada painel avisa quando abre/fecha: opened/closed);
//  - abrir/fechar animado (show/hide/toggle usam o PanelAnim do painel, se houver).

import QtQuick
import Quickshell

Singleton {
    id: root

    property var current: null
    property var anims: []          // [{ win, anim }]

    function register(win, anim) {
        anims = anims.filter(e => e.win !== win).concat([{ win: win, anim: anim }])
    }
    function animOf(p) {
        for (const e of anims) if (e.win === p) return e.anim
        return null
    }

    // aberto e não está fechando
    function isOpen(p) {
        const a = animOf(p)
        return p.visible && !(a && a.closing)
    }

    function show(p) {
        const a = animOf(p)
        if (a) a.open(); else p.visible = true
    }
    function hide(p) {
        const a = animOf(p)
        if (a) a.close(); else p.visible = false
    }
    function toggle(p) {
        if (isOpen(p)) hide(p); else show(p)
    }

    function opened(p) {
        if (current && current !== p) hide(current)
        current = p
    }

    function closed(p) {
        if (current === p) current = null
    }
}
