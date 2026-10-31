.pragma library
// palette.js — o que os dez tons de uma paleta derivam: lado (escura/clara), as 16 cores de
// terminal, contraste. Usado pelo Theme.qml (a barra) e pelo editor (quickshell/palette), para
// os dois verem exatamente as mesmas cores derivadas. Fica em palette/ porque um config do
// Quickshell só importa arquivos dentro da sua própria pasta (a barra alcança ../palette/).

var tones = ["crust", "base", "surface", "overlay", "subtext", "text", "accent", "green", "yellow", "red"]

function valid(p) {
    if (!p || typeof p !== "object") return false
    return tones.every(t => /^#[0-9a-fA-F]{6}$/.test(String(p[t] || "")))
}

function isDark(p) { return Qt.color(p.base).hslLightness < 0.5 }

function mix(a, b, t) { const B = Qt.color(b); return Qt.tint(Qt.color(a), Qt.rgba(B.r, B.g, B.b, t)) }

// 16 cores de terminal: as oficiais (campo "ansi") ou derivadas dos dez tons
function terminal(p) {
    if (p.ansi) return { fg: p.ansi.fg, bg: p.ansi.bg, regular: p.ansi.regular, bright: p.ansi.bright,
                         selFg: p.text, selBg: p.overlay }
    const dark = isDark(p)
    const blue = p.accent, magenta = mix(p.red, p.accent, 0.5), cyan = mix(p.green, p.accent, 0.5)
    const adj = x => dark ? Qt.lighter(Qt.color(x), 1.15) : Qt.darker(Qt.color(x), 1.15)
    return {
        fg: p.text, bg: p.base,
        regular: [dark ? p.surface : p.text, p.red, p.green, p.yellow, blue, magenta, cyan, dark ? p.subtext : p.overlay],
        bright:  [dark ? p.overlay : p.subtext, adj(p.red), adj(p.green), adj(p.yellow), adj(blue), adj(magenta), adj(cyan),
                  dark ? p.text : p.surface],
        selFg: p.text, selBg: dark ? p.overlay : p.surface
    }
}

// contraste WCAG entre duas cores (1 a 21); 4.5 lê bem como texto, 3 basta para ícones e bordas
function luminance(c) {
    const col = Qt.color(c)
    const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    return 0.2126 * f(col.r) + 0.7152 * f(col.g) + 0.0722 * f(col.b)
}
function contrast(a, b) {
    const la = luminance(a), lb = luminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function hex(c) { return Qt.color(c).toString().slice(0, 7) }
