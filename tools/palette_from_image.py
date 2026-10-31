#!/usr/bin/env python3
"""palette_from_image.py — uma paleta do BArch (os dez tons) a partir de uma imagem.

    palette_from_image.py <imagem> [--id ID] [--label NOME] [--dark | --light]

Imprime o JSON da paleta ({"id", "label", "crust", "base", ... "red"}), no formato de
quickshell/.config/quickshell/theme/palettes.json. `barch theme from-image` roda isto e abre o
resultado no editor (quickshell/palette) para acertar antes de salvar.

Como escolhe: quantiza a imagem em 48 cores dominantes; o lado (escura/clara) vem da luminosidade
média, salvo --dark/--light. O fundo (base) é a cor dominante mais escura (ou mais clara, numa
paleta clara), dessaturada; crust, surface e overlay são degraus dela no mesmo matiz, subtext e
text ficam com luminosidade fixa para ler bem. O destaque (accent) é a cor saturada mais presente,
e green/yellow/red são as cores dominantes mais próximas desses matizes (ou sintetizadas quando a
imagem não as tem). Toda cor de texto ou destaque é clareada/escurecida até o contraste mínimo
sobre o fundo (4.5 para texto e destaque, 3 para as três cores de estado). Depende de: Pillow.
"""
import argparse
import colorsys
import json
import os
import re
import sys

from PIL import Image

TONES = ["crust", "base", "surface", "overlay", "subtext", "text", "accent", "green", "yellow", "red"]


# ------------------------------------------------------------ cor
def hls(rgb):
    r, g, b = (v / 255 for v in rgb)
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return h, l, s


def from_hls(h, l, s):
    r, g, b = colorsys.hls_to_rgb(h % 1.0, max(0.0, min(1.0, l)), max(0.0, min(1.0, s)))
    return tuple(int(round(v * 255)) for v in (r, g, b))


def hexs(rgb):
    return "#%02x%02x%02x" % rgb


def luminance(rgb):
    def f(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = rgb
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def hue_dist(a, b):
    d = abs(a - b) % 1.0
    return min(d, 1.0 - d)


def fit_contrast(rgb, bg, target, lighter):
    """Move a luminosidade (clareando ou escurecendo) até o contraste mínimo sobre bg."""
    h, l, s = hls(rgb)
    for _ in range(80):
        if contrast(rgb, bg) >= target:
            break
        l = l + 0.012 if lighter else l - 0.012
        if not 0.0 <= l <= 1.0:
            break
        rgb = from_hls(h, l, s)
    return rgb


# ------------------------------------------------------------ imagem
def dominant(img, n=48):
    """[(peso, (r, g, b))] das n cores mais presentes, peso somando 1."""
    im = img.convert("RGB")
    im.thumbnail((256, 256))
    q = im.quantize(n, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette()
    counts = q.getcolors(n * n) or []
    total = sum(c for c, _ in counts) or 1
    return [(c / total, (pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2])) for c, i in counts]


def circular_mean_hue(items):
    """Matiz médio ponderado (items: [(peso, h)]); None sem cor saturada."""
    import math
    x = sum(w * math.cos(h * 2 * math.pi) for w, h in items)
    y = sum(w * math.sin(h * 2 * math.pi) for w, h in items)
    if abs(x) < 1e-6 and abs(y) < 1e-6:
        return None
    return (math.atan2(y, x) / (2 * math.pi)) % 1.0


def build(colors, dark):
    weighted = [(w, rgb, hls(rgb)) for w, rgb in colors]
    tint = circular_mean_hue([(w * s, h) for w, _, (h, l, s) in weighted if s > 0.15])
    if tint is None:
        tint = 0.61                                   # azul: neutro que não parece modo noturno

    # ---- fundo: a dominante mais escura (clara) com peso visível; os degraus seguem seu matiz
    visible = [t for t in weighted if t[0] >= 0.01] or weighted
    base_src = min(visible, key=lambda t: t[2][1]) if dark else max(visible, key=lambda t: t[2][1])
    bh, bl, bs = base_src[2]
    if bs < 0.05:
        bh = tint
    bs = min(bs, 0.35)
    if dark:
        bl = max(0.07, min(0.15, bl))
        ramp = {"crust": bl - 0.04, "base": bl, "surface": bl + 0.09, "overlay": bl + 0.17}
        text_l = {"subtext": 0.62, "text": 0.88}
    else:
        bl = max(0.88, min(0.95, bl))
        ramp = {"crust": min(0.985, bl + 0.05), "base": bl, "surface": bl - 0.08, "overlay": bl - 0.16}
        text_l = {"subtext": 0.40, "text": 0.17}
    out = {k: from_hls(bh, l, bs) for k, l in ramp.items()}
    for k, l in text_l.items():
        out[k] = from_hls(bh, l, min(bs, 0.22))
    base = out["base"]
    out["subtext"] = fit_contrast(out["subtext"], base, 4.0, dark)
    out["text"] = fit_contrast(out["text"], base, 7.0, dark)

    # ---- destaque: a cor saturada mais presente
    lo, hi = (0.55, 0.75) if dark else (0.30, 0.45)

    def settle(rgb, target):
        h, l, s = hls(rgb)
        rgb = from_hls(h, max(lo, min(hi, l)), max(0.45, min(0.85, s)))
        return fit_contrast(rgb, base, target, dark)

    sat = [t for t in weighted if t[2][2] > 0.30 and 0.12 < t[2][1] < 0.90]
    if sat:
        accent_src = max(sat, key=lambda t: t[0] * t[2][2])[1]
    else:
        accent_src = from_hls(tint, 0.6, 0.6)
    out["accent"] = settle(accent_src, 4.5)

    # ---- verde, amarelo, vermelho: as dominantes mais próximas desses matizes, ou sintetizadas
    for name, target_h in (("green", 130 / 360), ("yellow", 48 / 360), ("red", 4 / 360)):
        near = [t for t in weighted if t[2][2] > 0.25 and hue_dist(t[2][0], target_h) < 30 / 360]
        if near:
            src = max(near, key=lambda t: t[0] * t[2][2])[1]
        else:
            src = from_hls(target_h, 0.6, 0.6)
        out[name] = settle(src, 3.0)

    return {k: hexs(out[k]) for k in TONES}


def slug(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    s = re.sub(r"^[^a-z]+", "", s) or "palette"
    return s[:30]


def main():
    ap = argparse.ArgumentParser(description="uma paleta do BArch a partir de uma imagem (JSON)")
    ap.add_argument("image")
    ap.add_argument("--id", help="id da paleta (minúsculas, dígitos e -); padrão: o nome do arquivo")
    ap.add_argument("--label", help="nome para a interface; padrão: o id com inicial maiúscula")
    side = ap.add_mutually_exclusive_group()
    side.add_argument("--dark", action="store_true", help="paleta escura (padrão: pela luminosidade da imagem)")
    side.add_argument("--light", action="store_true", help="paleta clara")
    a = ap.parse_args()

    try:
        img = Image.open(a.image)
    except OSError as e:
        sys.exit(f"cannot open {a.image}: {e}")
    colors = dominant(img)
    mean_l = sum(w * hls(rgb)[1] for w, rgb in colors)
    dark = a.dark or (not a.light and mean_l < 0.55)

    pid = slug(a.id or os.path.splitext(os.path.basename(a.image))[0])
    label = a.label or pid.replace("-", " ").title()
    pal = {"id": pid, "label": label, "dark": dark}
    pal.update(build(colors, dark))
    json.dump(pal, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
