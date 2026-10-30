#!/usr/bin/env python3
"""Papéis de parede minimalistas, uma versão por paleta do tema, em várias cenas.

Uso: make_wallpapers.py <pasta> [-p PALETA]... [cena ...]
                                 as cenas pedidas (ou todas) nas paletas pedidas (por padrão
                                 dracula e latte, o par inicial do Theme.qml); --all = as 12
     make_wallpapers.py <pasta> boot      imagens da tela de boot (Limine e Plymouth)
     make_wallpapers.py <pasta> lock      só as versões lock/thumb (a partir das já geradas)
     make_wallpapers.py <pasta> list      cenas e paletas disponíveis

As paletas (os 10 tons de cada uma) são lidas do próprio Theme.qml do bar, que é a fonte única;
cada cena deriva todas as suas cores desses tons, então uma paleta escura rende a noite (lua,
estrelas) e uma clara rende o dia (sol). Cada cena vai para <pasta>/<paleta>/<cena>/:
  primary.png          3840x2160 (paisagem, AW3225QF)
  secondary.png        2160x3840 (retrato, P2723QE)
  primary-lock.png     960x540, já desfocada (e 10% mais escura nas paletas escuras)
  secondary-lock.png   540x960, idem
  thumb.png            480x270, miniatura do seletor (launcher "b ")
<pasta>/<paleta>/scenes.json lista as cenas prontas daquela paleta e <pasta>/scenes.json o
catálogo (todas as cenas, com label e descrição, e as paletas já renderizadas).

As versões "lock" são o que a tela de bloqueio (quickshell/lock) mostra: desfocar o PNG 4K na
hora custava ~100 ms de decodificação mais o blur na GPU a cada bloqueio; um PNG pequeno já
desfocado decodifica em poucos milissegundos.

O bar (quickshell/wallpaper/Wallpapers.qml) usa a pasta da paleta em uso (Theme.flavor) e manda
gerar aqui, em segundo plano, a de uma paleta que ainda não existe; a cena de cada lado fica em
~/.local/state/quickshell/wallpaper.json ({"desktop": "...", "lock": "..."}).
"""
import argparse
import colorsys
import json
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

RNG_SEED = 7
LANDSCAPE = (3840, 2160)
PORTRAIT = (2160, 3840)
THEME_QML = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "quickshell", ".config", "quickshell", "theme", "Theme.qml")
DEFAULT_PALETTES = ("dracula", "latte")

WHITE = np.array([255, 255, 255], dtype=np.float32)
BLACK = np.array([0, 0, 0], dtype=np.float32)


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


def mix(a, b, t):
    return a * (1 - t) + b * t


def lighten(c, f):
    """Multiplica a luminosidade (HLS) por f."""
    h, l, s = colorsys.rgb_to_hls(*(np.clip(c, 0, 255) / 255))
    r, g, b = colorsys.hls_to_rgb(h, min(1.0, l * f), s)
    return np.array([r, g, b], dtype=np.float32) * 255


def lightness(c):
    return colorsys.rgb_to_hls(*(np.clip(c, 0, 255) / 255))[1]


# ============================================================ paletas (do Theme.qml)

def load_palettes(path=THEME_QML):
    """Lê o bloco `palettes: ({ ... })` do Theme.qml: id → {tom: "#hex", ansi?: [...]}."""
    with open(path) as f:
        qml = f.read()
    m = re.search(r"readonly property var palettes:\s*\(\{(.*?)\n\s*\}\)", qml, re.S)
    if not m:
        raise SystemExit(f"palettes not found in {path}")
    body = re.sub(r"//[^\n]*", "", m.group(1))              # fora os comentários
    out = {}
    for pm in re.finditer(r"(\w+):\s*\{((?:[^{}]|\{[^{}]*\})*)\}", body):
        pid, inner = pm.group(1), pm.group(2)
        tones = dict(re.findall(r"(\w+):\s*\"(#[0-9a-fA-F]{6})\"", re.sub(r"ansi:\s*\{[^{}]*\}", "", inner)))
        am = re.search(r"ansi:\s*\{([^{}]*)\}", inner)
        if am:
            reg = re.search(r"regular:\s*\[([^\]]*)\]", am.group(1))
            tones["ansi"] = re.findall(r"\"(#[0-9a-fA-F]{6})\"", reg.group(1)) if reg else None
        if {"crust", "base", "surface", "overlay", "subtext", "text", "accent", "green", "yellow", "red"} <= set(tones):
            out[pid] = tones
    if not out:
        raise SystemExit(f"no palettes parsed from {path}")
    return out


class Pal:
    """Os tons de uma paleta e tudo que as cenas derivam deles (céu, astro, rampas)."""

    def __init__(self, pid, tones, boot=False):
        self.id = pid
        for k in ("crust", "base", "surface", "overlay", "subtext", "text", "accent", "green", "yellow", "red"):
            setattr(self, k, hexrgb(tones[k]))
        self.dark = lightness(self.base) < 0.5
        ansi = tones.get("ansi")
        if ansi and len(ansi) >= 8:
            self.pink, self.cyan = hexrgb(ansi[5]), hexrgb(ansi[6])
        else:
            self.pink = mix(self.red, self.accent, 0.5)
            self.cyan = mix(self.green, self.accent, 0.55)
        self.orange = mix(self.yellow, self.red, 0.45)
        if self.dark:
            self.sky_top = mix(self.crust, BLACK, 0.25)
            self.sky_mid = self.base
            self.sky_horizon = mix(self.surface, self.accent, 0.22)
            self.glow = self.accent
            self.orb = mix(self.text, WHITE, 0.3)
            self.orb_glow = self.accent
            self.stars, self.orb_alpha = True, 0.82
        else:                                   # nas claras, crust é o tom MAIS claro
            self.sky_top = mix(self.surface, self.accent, 0.12)
            self.sky_mid = mix(self.base, WHITE, 0.35)
            self.sky_horizon = mix(self.crust, self.yellow, 0.18)
            sun = lighten(self.yellow, 1.5)                 # os amarelos claros são escuros (contraste)
            self.glow = lighten(self.orange, 1.25)
            self.orb = mix(WHITE, sun, 0.45)
            self.orb_glow = lighten(mix(self.yellow, self.red, 0.3), 1.3)
            self.stars, self.orb_alpha = False, 0.95
        if boot:                                # tela de boot: a mesma noite, mais escura
            for k in ("sky_top", "sky_mid", "sky_horizon"):
                setattr(self, k, mix(getattr(self, k), BLACK, 0.3))
            self.orb = mix(self.orb, BLACK, 0.1)
            self.orb_alpha = 0.7
        self.boot = boot

    def ramp(self, n, far, near):
        return [mix(far, near, i / max(n - 1, 1)) for i in range(n)]

    # ---- rampas por cena: longe → perto ----
    def mountains(self, n=5):
        if self.dark:
            far, near = lighten(mix(self.surface, self.accent, 0.3), 1.15), mix(self.crust, BLACK, 0.25)
            if self.boot:
                far, near = mix(far, BLACK, 0.3), mix(near, BLACK, 0.3)
        else:
            far, near = lighten(mix(self.surface, self.accent, 0.1), 1.04), mix(self.subtext, self.accent, 0.25)
        return self.ramp(n, far, near)

    def water(self):
        """(longe, perto, camadas de onda, crista)"""
        if self.dark:
            far = mix(mix(self.base, self.cyan, 0.25), self.accent, 0.08)
            near = mix(self.crust, BLACK, 0.3)
            layers = self.ramp(7, mix(self.surface, self.cyan, 0.22), mix(self.crust, self.cyan, 0.08))
            return far, near, layers, self.cyan
        far = lighten(mix(self.surface, self.cyan, 0.35), 1.08)
        near = mix(self.text, self.cyan, 0.4)
        return far, near, self.ramp(7, mix(far, self.cyan, 0.1), mix(near, self.cyan, 0.15)), self.crust

    def sand(self):
        if self.dark:
            return self.ramp(4, lighten(mix(self.surface, self.accent, 0.4), 1.2), mix(self.crust, self.accent, 0.1))
        return self.ramp(4, mix(self.crust, self.yellow, 0.3), mix(self.surface, self.orange, 0.5))

    def trees(self):
        if self.dark:
            return self.ramp(4, mix(self.base, self.green, 0.10), mix(self.crust, BLACK, 0.3))
        return self.ramp(4, mix(self.overlay, self.green, 0.15), mix(self.text, self.green, 0.2))

    def far_hills(self, n=2):
        if self.dark:
            return self.ramp(n, mix(self.surface, self.accent, 0.25), mix(self.base, self.accent, 0.15))
        return self.ramp(n, mix(self.surface, self.accent, 0.1), mix(self.overlay, self.accent, 0.15))

    def city(self):
        if self.dark:
            return self.ramp(3, mix(self.surface, self.accent, 0.2), mix(self.crust, BLACK, 0.2))
        return self.ramp(3, mix(self.surface, self.accent, 0.08), mix(self.subtext, self.accent, 0.1))

    def hills(self):
        if self.dark:
            return self.ramp(4, mix(self.surface, self.green, 0.25), mix(self.crust, self.green, 0.08))
        return self.ramp(4, mix(self.crust, self.green, 0.3), mix(self.subtext, self.green, 0.4))

    def mesa(self):
        if self.dark:
            return self.ramp(4, mix(self.surface, self.red, 0.3), mix(self.crust, self.red, 0.08))
        return self.ramp(4, mix(self.crust, self.orange, 0.35), mix(self.subtext, self.orange, 0.55))

    def ground(self, n=2):
        """cume baixo (aurora)"""
        if self.dark:
            return self.ramp(n, mix(self.base, BLACK, 0.2), mix(self.crust, BLACK, 0.4))
        return self.ramp(n, mix(self.surface, self.accent, 0.1), mix(self.overlay, self.accent, 0.1))


# ============================================================ desenho

def value_noise_1d(n, octaves, rng, base_period):
    """Ruído suave 1D (soma de oitavas com interpolação cosseno)."""
    out = np.zeros(n, dtype=np.float64)
    amp, period, total = 1.0, base_period, 0.0
    x = np.arange(n)
    for _ in range(octaves):
        pts = rng.uniform(-1, 1, int(n / period) + 3)
        xi = x / period
        i0 = np.floor(xi).astype(int)
        f = xi - i0
        f = (1 - np.cos(f * np.pi)) / 2
        out += amp * (pts[i0] * (1 - f) + pts[i0 + 1] * f)
        total += amp
        amp *= 0.5
        period /= 2.0
    return out / total


def noise2d(rng, W, H, octaves, base_period):
    """Ruído suave 2D (-1..1): grades aleatórias ampliadas com bicúbica, somadas em oitavas."""
    out = np.zeros((H, W), dtype=np.float32)
    amp, period, total = 1.0, float(base_period), 0.0
    for _ in range(octaves):
        gw, gh = int(W / period) + 2, int(H / period) + 2
        grid = Image.fromarray(rng.uniform(-1, 1, (gh, gw)).astype(np.float32), "F")
        out += amp * np.asarray(grid.resize((W, H), Image.BICUBIC))
        total += amp
        amp *= 0.5
        period /= 2.0
    return out / total


class Canvas:
    """Uma imagem em construção: céu, astro, estrelas e camadas preenchidas até a base."""

    def __init__(self, P, W, H, portrait, horizon):
        self.P = P
        self.dark = P.dark
        self.W, self.H, self.portrait, self.horizon = W, H, portrait, horizon
        self.rng = np.random.default_rng(RNG_SEED)
        self.ys = np.linspace(0, 1, H, dtype=np.float32)[:, None]
        self.xs = np.linspace(0, 1, W, dtype=np.float32)[None, :]
        self.y = np.arange(H, dtype=np.float32)[:, None]     # em pixels
        t1 = np.clip(self.ys / max(horizon, 1e-3), 0, 1)
        sky = np.where(
            (t1 < 0.55)[..., None],
            mix(P.sky_top, P.sky_mid, (t1 / 0.55)[..., None]),
            mix(P.sky_mid, P.sky_horizon, np.clip((t1 - 0.55) / 0.45, 0, 1)[..., None] ** 1.6),
        )
        self.img = np.broadcast_to(sky, (H, W, 3)).copy()

    def flat(self, color):
        self.img = np.broadcast_to(color, self.img.shape).copy()

    def glow(self, strength=None, sigma=0.16, color=None, at=None):
        if strength is None:
            strength = 0.10 if self.dark else 0.07
        gy = np.exp(-((self.ys - (self.horizon if at is None else at)) / sigma) ** 2)
        self.img = mix(self.img, color if color is not None else self.P.glow, (gy * strength)[..., None])

    def stars(self, density=9000, below=None):
        if not self.P.stars:
            return
        W, H, rng = self.W, self.H, self.rng
        n = int(W * H / density)
        sx = rng.integers(0, W, n)
        sy = (rng.beta(1.2, 2.6, n) * H * (self.horizon if below is None else below) * 0.95).astype(int)
        bright = rng.uniform(0.12, 0.55, n) ** 1.5
        for x, y, b in zip(sx, sy, bright):
            r = 1 if b < 0.3 else 2
            y0, y1, x0, x1 = max(0, y - r), min(H, y + r + 1), max(0, x - r), min(W, x + r + 1)
            yy, xx = np.mgrid[y0:y1, x0:x1]
            d = np.sqrt((yy - y) ** 2 + (xx - x) ** 2)
            a = np.clip(1 - d / (r + 0.5), 0, 1)[..., None] * b
            self.img[y0:y1, x0:x1] = mix(self.img[y0:y1, x0:x1], self.P.orb, a)

    def orb(self, cx, cy, radius, halo=None):
        """Lua / sol: raio em fração da altura (paisagem) ou da largura (retrato)."""
        W, H, P = self.W, self.H, self.P
        scale = W if self.portrait else H
        dx = (self.xs - cx) * (W / scale)
        dy = (self.ys - cy) * (H / scale)
        d = np.sqrt(dx ** 2 + dy ** 2) / radius
        if halo is None:
            halo = 0.20 if self.dark else 0.30
        self.img = mix(self.img, P.orb_glow, (np.exp(-np.clip(d - 1, 0, None) * 1.6) * halo)[..., None])
        disc = np.clip((1.0 - d) * radius * scale * 0.6, 0, 1)
        self.img = mix(self.img, P.orb, (disc * P.orb_alpha)[..., None])

    def ridge(self, base, amp, period, octaves=5, wobble=0.0, phase=0.0):
        n = value_noise_1d(self.W, octaves, self.rng, period)
        r = base - amp * (0.55 + n)
        if wobble:
            r = r - self.H * wobble * np.sin(np.linspace(0, np.pi * 1.3, self.W) + phase)
        return r

    def fill(self, ridge, c, fog=0.18, fog_dark=None, haze=0.0, shade=None):
        """Preenche abaixo de `ridge` com a cor c; névoa na base (puxa para a cor do céu no
        horizonte) e `haze` para as camadas distantes. `shade` (por coluna, -1..1) clareia/escurece."""
        y = self.y
        cover = np.clip(y - ridge[None, :] + 0.5, 0, 1)
        col = np.broadcast_to(c, (1, 1, 3))
        if fog:
            if fog_dark is None:
                fog_dark = 0.86 if self.dark else 0.93
            f = np.clip((y - ridge[None, :]) / (self.H * fog), 0, 1)
            col = mix(c, c * fog_dark, f[..., None])
        if shade is not None:
            depth = np.exp(-np.clip(y - ridge[None, :], 0, None) / (self.H * 0.12))
            col = col * (1 + shade[None, :, None] * depth[..., None])
        if haze:
            col = mix(col, self.P.sky_horizon, haze)
        self.img = mix(self.img, col, cover[..., None])

    def finish(self):
        img = self.img + self.rng.uniform(-0.6, 0.6, self.img.shape).astype(np.float32)
        return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


# ============================================================ cenas

def scene_mountains(P, W, H, portrait, horizon=None, orb=None, orb_radius=None):
    """Montanhas em camadas (a cena original; também a da tela de boot)."""
    c = Canvas(P, W, H, portrait, horizon or (0.60 if portrait else 0.52))
    c.glow()
    c.stars()
    cx, cy = orb or ((0.70, 0.22) if portrait else (0.74, 0.24))
    c.orb(cx, cy, orb_radius or (0.085 if portrait else 0.055))
    layers = P.mountains()
    nl = len(layers)
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        base = H * (c.horizon + k * (0.30 if portrait else 0.36))
        amp = H * (0.13 - 0.045 * k) * (0.75 if portrait else 1.0)
        r = c.ridge(base, amp, W * (0.45 - 0.22 * k))
        r = r - H * 0.02 * np.sin(np.linspace(0, np.pi * (1.3 + i * 0.4), W) + i)
        c.fill(r, col, haze=(1 - k) * 0.22)
    return c.finish()


def scene_waves(P, W, H, portrait):
    """Mar aberto: ondas em camadas e o reflexo da lua / do sol na água."""
    c = Canvas(P, W, H, portrait, 0.56 if portrait else 0.50)
    c.glow(0.14 if c.dark else 0.10, sigma=0.10)
    c.stars()
    cx, cy, r = (0.5, 0.26, 0.09) if portrait else (0.62, 0.27, 0.06)
    c.orb(cx, cy, r)
    far, near, layers, crest = P.water()
    water = np.clip((c.ys - c.horizon) / (1 - c.horizon), 0, 1)
    sea = mix(far, near, (water ** 0.8)[..., None])
    c.img = np.where((c.ys >= c.horizon)[..., None], np.broadcast_to(sea, c.img.shape), c.img)
    nl = len(layers)
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        base = H * (c.horizon + 0.004 + (k ** 1.3) * (1 - c.horizon - 0.04))
        amp = H * (0.002 + 0.014 * k)
        rr = c.ridge(base, amp, W * (0.10 - 0.05 * k), octaves=3)
        rr = rr - amp * 0.35 * np.sin(np.linspace(0, 2 * np.pi * (4 + 2 * i), W) * (1 + 0.1 * value_noise_1d(W, 2, c.rng, W * 0.2)) + i * 1.7)
        c.fill(rr, col, fog=0)
        line = np.clip(1 - np.abs(c.y - rr[None, :]) / (1.0 + 2.0 * k), 0, 1) * (0.05 + 0.10 * k)
        c.img = mix(c.img, crest, line[..., None])
    depth = np.clip((c.ys - c.horizon) / (1 - c.horizon), 0, 1)
    width = (0.012 if portrait else 0.018) + 0.10 * depth
    path = np.exp(-((c.xs - cx) / width) ** 2) * np.exp(-depth * 1.4) * (c.ys >= c.horizon)
    shimmer = 0.45 + 0.55 * (0.5 + 0.5 * value_noise_1d(H, 3, c.rng, 24))[:, None]
    c.img = mix(c.img, P.orb_glow if c.dark else P.orb, (path * shimmer * (0.42 if c.dark else 0.38))[..., None])
    return c.finish()


def scene_dunes(P, W, H, portrait):
    """Dunas: poucas curvas largas e suaves, um lado iluminado e outro na sombra."""
    c = Canvas(P, W, H, portrait, 0.52 if portrait else 0.46)
    c.glow(0.12 if c.dark else 0.14, sigma=0.14)
    c.stars()
    c.orb(*((0.30, 0.20, 0.075) if portrait else (0.26, 0.24, 0.055)), halo=0.22 if c.dark else 0.40)
    layers = P.sand()
    nl = len(layers)
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        base = H * (c.horizon + k * (0.30 if portrait else 0.38))
        amp = H * (0.11 - 0.03 * k) * (0.8 if portrait else 1.0)
        period = W * (1.1 - 0.5 * k)
        rr = c.ridge(base, amp, period, octaves=2, wobble=0.03 * (1 - k), phase=i * 2.1)
        slope = np.gradient(rr)
        shade = np.clip(-slope * (period * 0.5 / max(amp, 1)), -1, 1) * (0.16 if c.dark else 0.10)
        c.fill(rr, col, fog=0.25, haze=(1 - k) * 0.25, shade=shade)
    return c.finish()


def scene_forest(P, W, H, portrait):
    """Pinheiros em camadas na névoa, com montanhas distantes."""
    c = Canvas(P, W, H, portrait, 0.58 if portrait else 0.52)
    c.glow()
    c.stars()
    c.orb(*((0.68, 0.20, 0.08) if portrait else (0.72, 0.22, 0.05)))
    for i, col in enumerate(P.far_hills()):
        rr = c.ridge(H * (c.horizon + 0.07 * i), H * (0.10 - 0.03 * i) * (0.75 if portrait else 1), W * (0.4 - 0.1 * i))
        c.fill(rr, col, haze=0.35 - 0.1 * i)
    layers = P.trees()
    nl = len(layers)
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        ground = c.ridge(H * (c.horizon + 0.10 + k * (0.26 if portrait else 0.30)), H * 0.02, W * 0.3, octaves=2)
        h = H * (0.07 + 0.11 * k) * (0.8 if portrait else 1.0)
        top = np.full(W, H * 2.0)
        x = -c.rng.uniform(0, h * 0.3)
        while x < W:
            th = h * c.rng.uniform(0.7, 1.15)
            hw = th * c.rng.uniform(0.26, 0.36)
            cx = x + hw
            x0, x1 = max(0, int(cx - hw)), min(W, int(cx + hw) + 1)
            if x1 > x0:
                xs = np.arange(x0, x1, dtype=np.float32)
                yb = ground[int(min(max(cx, 0), W - 1))]
                for tier in range(3):
                    ay = yb - th + tier * th * 0.26
                    bh = th * 0.42
                    thw = hw * (0.45 + 0.275 * tier)
                    outline = ay + (np.abs(xs - cx) / thw) * bh
                    outline = np.where(np.abs(xs - cx) <= thw, outline, H * 2.0)
                    top[x0:x1] = np.minimum(top[x0:x1], outline)
            x += hw * c.rng.uniform(0.9, 1.5)
        top = np.minimum(top, ground + h * 0.05)
        c.fill(top, col, fog=0.22, haze=(1 - k) * 0.3)
    return c.finish()


def scene_city(P, W, H, portrait):
    """Silhueta de cidade; à noite, janelas acesas."""
    c = Canvas(P, W, H, portrait, 0.62 if portrait else 0.60)
    c.glow(0.16 if c.dark else 0.08, sigma=0.12)
    c.stars(density=14000)
    c.orb(*((0.26, 0.18, 0.07) if portrait else (0.22, 0.20, 0.045)))
    rng = c.rng
    lit_cols = [P.yellow, P.orange, P.text]
    day_win = P.crust
    cols3 = P.city()
    tiers = [  # (base, altura mín/máx, largura mín/máx, cor, névoa, janelas)
        (c.horizon, (0.04, 0.14), (0.010, 0.030), cols3[0], 0.35, False),
        (c.horizon + 0.06, (0.06, 0.24), (0.014, 0.036), cols3[1], 0.15, True),
        (c.horizon + (0.10 if portrait else 0.09), (0.10, 0.36), (0.018, 0.050), cols3[2], 0.0, True),
    ]
    scale = W if portrait else H
    pitch_x, pitch_y = max(6, int(scale * 0.0075)), max(6, int(scale * 0.0085))
    ww, wh = max(2, int(pitch_x * 0.5)), max(3, int(pitch_y * 0.55))
    for base_f, hr, wr, col, haze, windows in tiers:
        base = H * base_f
        top = np.full(W, H * 2.0)
        buildings = []
        x = -rng.uniform(0, W * 0.02)
        while x < W:
            w = W * rng.uniform(*wr)
            h = scale * rng.uniform(*hr)
            x0, x1 = max(0, int(x)), min(W, int(x + w))
            if x1 > x0:
                top[x0:x1] = base - h
                buildings.append((x0, x1, base - h))
                if h > scale * hr[1] * 0.8 and rng.uniform() < 0.3:        # antena
                    ax = (x0 + x1) // 2
                    top[ax:ax + 2] = base - h - scale * 0.02
            x += w + W * rng.uniform(0.001, 0.006)
        top = np.minimum(top, base)                                      # chão entre os prédios
        c.fill(top, col, fog=0, haze=haze)
        if not windows:
            continue
        facade = col
        for x0, x1, t in buildings:
            lit = lit_cols[rng.integers(0, 3)] if c.dark else day_win
            p_on, alpha = (0.30, 0.8) if c.dark else (1.0, 0.16)
            cols = range(x0 + pitch_x // 2, x1 - ww, pitch_x)
            rows = range(int(t) + pitch_y, int(base) - wh, pitch_y)
            if not cols or not rows:
                continue
            on = rng.uniform(size=(len(rows), len(cols))) < p_on
            glow_a = rng.uniform(0.6, 1.0, size=on.shape)
            for ri, yy in enumerate(rows):
                for ci, xx in enumerate(cols):
                    if on[ri, ci]:
                        c.img[yy:yy + wh, xx:xx + ww] = mix(facade, lit, alpha * glow_a[ri, ci])
    return c.finish()


def scene_aurora(P, W, H, portrait):
    """Aurora boreal à noite; raios de sol de dia. Um cume baixo embaixo."""
    c = Canvas(P, W, H, portrait, 0.74 if portrait else 0.70)
    rng = c.rng
    if c.dark:
        c.stars(density=7000)
        c.orb(*((0.80, 0.12, 0.05) if portrait else (0.84, 0.16, 0.035)), halo=0.12)
        bands = [(0.20, P.green, P.accent, 0.62), (0.33, P.green, P.pink, 0.46), (0.46, P.cyan, P.accent, 0.34)]
        for j, (yc_f, lo, hi, a) in enumerate(bands):
            yc = H * (yc_f + 0.10 * value_noise_1d(W, 3, rng, W * 0.5))[None, :]
            fade_up = H * ((0.08 if portrait else 0.11) + 0.03 * j)
            fade_down = H * 0.035
            streak = np.clip(0.35 + 0.65 * value_noise_1d(W, 4, rng, W * 0.07), 0, 1)[None, :] ** 1.5
            above = np.clip(yc - c.y, 0, None)
            prof = np.where(c.y <= yc, np.exp(-above / fade_up), np.exp(-((c.y - yc) / fade_down) ** 2))
            col = mix(lo, hi, np.clip(above / fade_up, 0, 1)[..., None] ** 0.7)
            c.img = mix(c.img, col, (prof * streak * a)[..., None])
    else:
        sx, sy, sr = (0.66, 0.24, 0.09) if portrait else (0.72, 0.22, 0.06)
        scale = W if portrait else H
        dx, dy = (c.xs - sx) * (W / scale), (c.ys - sy) * (H / scale)
        ang = np.arctan2(dy, dx)
        rays = np.zeros_like(ang)
        for n_k in (7, 11, 17, 23):
            rays += rng.uniform(0.3, 1.0) * np.sin(n_k * ang + rng.uniform(0, 2 * np.pi))
        rays = np.clip(rays / 2.5, 0, 1) ** 1.6
        dist = np.sqrt(dx ** 2 + dy ** 2)
        beam = rays * np.exp(-dist / 0.9) * np.clip((c.horizon + 0.08 - c.ys) / 0.25, 0, 1)
        c.img = mix(c.img, P.orb, (beam * 0.36)[..., None])
        c.glow(0.10, sigma=0.12)
        c.orb(sx, sy, sr, halo=0.36)
    for i, col in enumerate(P.ground()):
        rr = c.ridge(H * (c.horizon + 0.10 * i), H * (0.07 - 0.02 * i) * (0.8 if portrait else 1), W * (0.35 - 0.1 * i))
        c.fill(rr, col, haze=0.15 - 0.1 * i)
    return c.finish()


def scene_mesh(P, W, H, portrait):
    """Abstrato: manchas suaves nas cores de destaque da paleta, sem paisagem."""
    c = Canvas(P, W, H, portrait, 1.0)
    rng = c.rng
    a0, a1 = (mix(P.crust, P.base, 0.4), mix(P.base, P.surface, 0.2)) if c.dark else (P.base, P.crust)
    diag = np.clip((c.xs + c.ys) / 2, 0, 1)
    c.img = np.broadcast_to(mix(a0, a1, diag[..., None]), c.img.shape).copy()
    k = 1.0 if c.dark else 0.55
    blobs = [(0.20, 0.25, 0.34, 0.28, P.accent, 0.36 * k), (0.78, 0.28, 0.30, 0.34, P.pink, 0.24 * k),
             (0.60, 0.88, 0.42, 0.30, P.cyan, 0.17 * k), (0.12, 0.86, 0.26, 0.24, P.orange, 0.11 * k)]
    for bx, by, sx, sy, col, alpha in blobs:
        if portrait:
            bx, by, sx, sy = by, bx, sy, sx
        th = rng.uniform(-0.5, 0.5)
        u = (c.xs - bx) * np.cos(th) - (c.ys - by) * np.sin(th)
        v = (c.xs - bx) * np.sin(th) + (c.ys - by) * np.cos(th)
        g = np.exp(-((u / sx) ** 2 + (v / sy) ** 2))
        c.img = mix(c.img, col, (g * alpha)[..., None])
    return c.finish()


def scene_lake(P, W, H, portrait):
    """Montanhas refletidas num lago parado."""
    water = 0.50
    c = Canvas(P, W, H, portrait, water)
    c.glow(sigma=0.12)
    c.stars()
    c.orb(*((0.66, 0.16, 0.08) if portrait else (0.70, 0.18, 0.05)))
    layers = P.mountains()
    nl = len(layers)
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        base = H * (0.30 + k * 0.17) if not portrait else H * (0.32 + k * 0.16)
        amp = H * (0.11 - 0.04 * k) * (0.7 if portrait else 1.0)
        rr = np.minimum(c.ridge(base, amp, W * (0.45 - 0.22 * k)), H * water)
        c.fill(rr, col, fog=0.12, haze=(1 - k) * 0.22)
    hw = int(H * water)
    refl = np.ascontiguousarray(c.img[:hw][::-1][:H - hw])
    shift = (np.sin(np.arange(refl.shape[0]) / 9.0) * 3 * (0.3 + 0.7 * value_noise_1d(refl.shape[0], 2, c.rng, 60))).astype(int)
    for r in range(refl.shape[0]):
        if shift[r]:
            refl[r] = np.roll(refl[r], shift[r], axis=0)
    refl = np.asarray(Image.fromarray(np.clip(refl, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2)), dtype=np.float32)
    water_col = mix(P.crust, P.accent, 0.1) if c.dark else lighten(mix(P.surface, P.accent, 0.3), 1.1)
    depth = np.linspace(0, 1, refl.shape[0], dtype=np.float32)[:, None, None]
    c.img[hw:] = mix(refl * (0.8 if c.dark else 0.94), water_col, 0.12 + 0.38 * depth ** 1.5)
    line = np.exp(-((c.y - hw) / 1.5) ** 2) * (0.25 if c.dark else 0.35)
    c.img = mix(c.img, P.orb, np.broadcast_to(line, (H, 1))[..., None] * np.ones((1, W, 1), dtype=np.float32))
    return c.finish()


def scene_hills(P, W, H, portrait):
    """Colinas suaves, em verde discreto."""
    c = Canvas(P, W, H, portrait, 0.56 if portrait else 0.50)
    c.glow()
    c.stars()
    c.orb(*((0.30, 0.20, 0.08) if portrait else (0.28, 0.22, 0.055)))
    layers = P.hills()
    nl = len(layers)
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        base = H * (c.horizon + k * (0.30 if portrait else 0.38))
        amp = H * (0.10 - 0.02 * k) * (0.8 if portrait else 1.0)
        rr = c.ridge(base, amp, W * (0.8 - 0.3 * k), octaves=2, wobble=0.02, phase=i * 1.3)
        slope = np.gradient(rr)
        shade = np.clip(-slope * (W * 0.3 / max(amp, 1)), -1, 1) * (0.10 if c.dark else 0.06)
        c.fill(rr, col, fog=0.3, haze=(1 - k) * 0.28, shade=shade)
    return c.finish()


def scene_clouds(P, W, H, portrait):
    """Céu com nuvens volumosas, iluminadas por cima."""
    c = Canvas(P, W, H, portrait, 0.95)
    c.stars(below=0.6)
    c.orb(*((0.70, 0.14, 0.08) if portrait else (0.76, 0.16, 0.055)), halo=0.3)
    n = noise2d(c.rng, W, H, 6, W * (0.5 if portrait else 0.35))
    band = np.exp(-((c.ys - 0.62) / 0.30) ** 2)
    dens = np.clip((n + 0.05) * 2.2, 0, 1) * band
    dens = np.asarray(Image.fromarray((dens * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6)), dtype=np.float32) / 255
    lit = mix(P.overlay, P.accent, 0.3) if c.dark else WHITE
    shadow = mix(P.surface, P.base, 0.5) if c.dark else mix(P.surface, P.accent, 0.05)
    gy = np.gradient(dens, axis=0)
    shade = np.clip(0.45 + gy * 90, 0, 1)
    cloud = mix(shadow, lit, shade[..., None])
    c.img = mix(c.img, cloud, (np.clip(dens * 1.25, 0, 1) ** 0.9)[..., None])
    return c.finish()


def scene_mesa(P, W, H, portrait):
    """Canyon: mesas em patamares, tons quentes."""
    c = Canvas(P, W, H, portrait, 0.52 if portrait else 0.48)
    c.glow(0.12, sigma=0.14)
    c.stars()
    c.orb(*((0.70, 0.20, 0.075) if portrait else (0.74, 0.22, 0.05)))
    layers = P.mesa()
    nl = len(layers)
    kernel = np.ones(21) / 21
    for i, col in enumerate(layers):
        k = i / (nl - 1)
        base = H * (c.horizon + k * (0.30 if portrait else 0.38))
        amp = H * (0.12 - 0.03 * k) * (0.8 if portrait else 1.0)
        n = value_noise_1d(W, 3, c.rng, W * (0.35 - 0.12 * k))
        steps = np.round((0.55 + n) * 4) / 4
        rr = np.convolve(np.pad(base - amp * steps, 10, mode="edge"), kernel, mode="valid")
        c.fill(rr, col, fog=0.22, haze=(1 - k) * 0.25)
    return c.finish()


def scene_polygons(P, W, H, portrait):
    """Terreno low-poly: triângulos chapados num degradê."""
    rng = np.random.default_rng(RNG_SEED)
    cols, rows = (12, 20) if portrait else (22, 12)
    cw, ch = W / cols, H / rows
    pts = np.zeros((rows + 1, cols + 1, 2))
    for r in range(rows + 1):
        for q in range(cols + 1):
            jx = 0 if q in (0, cols) else rng.uniform(-0.38, 0.38) * cw
            jy = 0 if r in (0, rows) else rng.uniform(-0.38, 0.38) * ch
            pts[r, q] = (q * cw + jx, r * ch + jy)
    if P.dark:
        a, b = lighten(mix(P.surface, P.accent, 0.35), 1.1), mix(P.crust, P.base, 0.5)
    else:
        a, b = mix(P.crust, P.accent, 0.15), mix(P.overlay, P.accent, 0.4)
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for r in range(rows):
        for q in range(cols):
            p00, p01, p10, p11 = pts[r, q], pts[r, q + 1], pts[r + 1, q], pts[r + 1, q + 1]
            tris = [(p00, p01, p11), (p00, p11, p10)] if (r + q) % 2 else [(p00, p01, p10), (p01, p11, p10)]
            for tri in tris:
                cy = sum(t[1] for t in tri) / 3 / H
                cx = sum(t[0] for t in tri) / 3 / W
                t = np.clip(0.65 * cy + 0.35 * cx, 0, 1)
                col = mix(a, b, t) * (1 + rng.uniform(-0.09, 0.09))
                draw.polygon([tuple(p) for p in tri], fill=tuple(int(v) for v in np.clip(col, 0, 255)))
    return img


def scene_retro(P, W, H, portrait):
    """Synthwave: sol listrado no horizonte e grade em perspectiva."""
    c = Canvas(P, W, H, portrait, 0.60 if portrait else 0.58)
    tint = mix(P.base, P.pink, 0.45) if c.dark else mix(P.crust, P.orange, 0.25)
    c.img = mix(c.img, tint, (np.clip((c.ys - 0.15) / (c.horizon - 0.15), 0, 1) ** 2.2 * (0.6 if c.dark else 0.7))[..., None])
    c.stars(density=7000)
    scale = W if portrait else H
    r = 0.16 if portrait else 0.20
    sx, sy = 0.5, c.horizon - r * 0.55 * (scale / H)
    dx = (c.xs - sx) * (W / scale)
    dy = (c.ys - sy) * (H / scale)
    d = np.sqrt(dx ** 2 + dy ** 2) / r
    halo = np.exp(-np.clip(d - 1, 0, None) * 2.2) * (0.35 if c.dark else 0.3)
    c.img = mix(c.img, P.pink if c.dark else P.orange, halo[..., None])
    top, bot = (P.yellow, P.pink) if c.dark else (P.orb, P.orange)
    t = np.clip((c.ys - (sy - r * H / scale)) / (2 * r * H / scale), 0, 1)
    sun = mix(top, bot, t[..., None])
    disc = np.clip((1.0 - d) * r * scale * 0.6, 0, 1)
    stripes = np.where(t > 0.45, (np.sin((t - 0.45) * 95) > -0.2 + (t - 0.45) * 1.8), True)
    c.img = mix(c.img, sun, (disc * stripes * 0.95)[..., None])
    ground = mix(P.crust, P.pink, 0.08) if c.dark else mix(P.base, P.accent, 0.05)
    c.img = np.where((c.ys >= c.horizon)[..., None], ground, c.img)
    below = np.clip(c.ys - c.horizon, 1e-4, None)
    z = 0.03 / below
    vx = (c.xs - 0.5) / below * (0.9 if portrait else 0.35)
    thick = 0.0025 + 0.004 * (c.ys - c.horizon)
    hl = np.exp(-((np.mod(z, 1.0) - 0.5) / (z * 0.02 + 0.03)) ** 2) * 0.9
    vl = np.exp(-((np.mod(vx * 8, 1.0) - 0.5) / (thick / below * 1.6)) ** 2)
    grid = np.clip(hl + vl, 0, 1) * (c.ys >= c.horizon) * np.clip((c.ys - c.horizon) / 0.03, 0, 1)
    c.img = mix(c.img, P.accent, (grid * (0.75 if c.dark else 0.35))[..., None])
    c.img = mix(c.img, P.pink if c.dark else P.orange,
                (np.exp(-((c.ys - c.horizon) / 0.004) ** 2) * (0.8 if c.dark else 0.5))[..., None])
    return c.finish()


def scene_nebula(P, W, H, portrait):
    """Nebulosa: nuvens de cor sobre estrelas (de dia, a versão pastel)."""
    c = Canvas(P, W, H, portrait, 1.0)
    c.flat(mix(P.crust, BLACK, 0.3) if c.dark else P.base)
    rng = c.rng
    if c.dark:
        c.stars(density=4500, below=1.0)
    cols = ([(P.accent, 0.75), (P.pink, 0.55), (P.cyan, 0.30)] if c.dark
            else [(P.accent, 0.34), (P.pink, 0.30), (P.cyan, 0.22)])
    for col, alpha in cols:
        n = noise2d(rng, W, H, 6, W * 0.45)
        warp = noise2d(rng, W, H, 3, W * 0.3)
        a = np.clip(1.7 * n + 0.4 * warp + 0.25, 0, 1) ** 1.4
        c.img = mix(c.img, col, (a * alpha)[..., None])
    if c.dark:
        c.stars(density=12000, below=1.0)
    return c.finish()


def scene_bokeh(P, W, H, portrait):
    """Bokeh: círculos de luz desfocados, grandes ao fundo e nítidos na frente."""
    rng = np.random.default_rng(RNG_SEED)
    a, b = (mix(P.crust, BLACK, 0.1), mix(P.base, P.accent, 0.15)) if P.dark else (P.base, mix(P.surface, P.accent, 0.1))
    ys = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    xs = np.linspace(0, 1, W, dtype=np.float32)[None, :, None]
    bg = Image.fromarray(np.clip(mix(a, b, (0.6 * ys + 0.4 * xs)), 0, 255).astype(np.uint8))
    accents = [P.accent, P.pink, P.cyan, P.orange]
    scale = min(W, H)
    groups = ([(14, 0.10, 0.20, 60, 0.20), (22, 0.04, 0.09, 18, 0.30), (30, 0.012, 0.035, 3, 0.55)] if P.dark
              else [(14, 0.10, 0.20, 60, 0.16), (22, 0.04, 0.09, 18, 0.20), (24, 0.012, 0.035, 3, 0.30)])
    for n, rmin, rmax, blur, alpha in groups:
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        draw = ImageDraw.Draw(layer)
        for _ in range(n):
            r = scale * rng.uniform(rmin, rmax)
            x, y = rng.uniform(-r, W + r), rng.uniform(-r, H + r)
            col = accents[rng.integers(0, len(accents))]
            av = int(255 * alpha * rng.uniform(0.6, 1.0))
            draw.ellipse([x - r, y - r, x + r, y + r], fill=(int(col[0]), int(col[1]), int(col[2]), av))
        layer = layer.filter(ImageFilter.GaussianBlur(blur))
        bg = Image.alpha_composite(bg.convert("RGBA"), layer).convert("RGB")
    return bg


def scene_contours(P, W, H, portrait):
    """Curvas de nível de um relevo imaginário, em linhas finas da cor de destaque."""
    c = Canvas(P, W, H, portrait, 1.0)
    c.flat(mix(P.crust, P.base, 0.6) if c.dark else P.base)
    levels = (noise2d(c.rng, W, H, 4, W * 0.45) + 0.6 * noise2d(c.rng, W, H, 2, W * 0.9)) * 11
    gy, gx = np.gradient(levels)
    g = np.maximum(np.sqrt(gx ** 2 + gy ** 2), 1e-4)
    frac = np.mod(levels, 1.0)
    dist = np.minimum(frac, 1 - frac) / g
    line = np.clip(3.2 - dist, 0, 1)
    major = (np.mod(np.floor(levels), 4) == 0)
    strength = np.where(major, 1.0, 0.55) * line
    glow = np.exp(-((c.xs - 0.3) ** 2 + (c.ys - 0.35) ** 2) / 0.35)
    c.img = mix(c.img, mix(P.base, P.accent, 0.12) if c.dark else mix(P.surface, P.accent, 0.05), (glow * 0.8)[..., None])
    c.img = mix(c.img, P.accent, (strength * (0.55 if c.dark else 0.5) * (0.55 + 0.45 * glow))[..., None])
    return c.finish()


# id → (label, descrição, função); a ordem é a do seletor
SCENES = {
    "mountains": ("Mountains", "Layered ridges under the moon or the sun", scene_mountains),
    "waves": ("Waves", "Open sea with the light on the water", scene_waves),
    "dunes": ("Dunes", "Soft desert ridges", scene_dunes),
    "forest": ("Forest", "Pine treelines in the mist", scene_forest),
    "city": ("City", "Skyline, windows lit at night", scene_city),
    "aurora": ("Aurora", "Northern lights at night, sun rays by day", scene_aurora),
    "lake": ("Lake", "Mountains mirrored in still water", scene_lake),
    "hills": ("Hills", "Rolling green hills", scene_hills),
    "clouds": ("Clouds", "Big clouds lit from above", scene_clouds),
    "mesa": ("Mesa", "Canyon terraces in warm tones", scene_mesa),
    "retro": ("Retro", "Synthwave sun and perspective grid", scene_retro),
    "polygons": ("Polygons", "Low-poly terrain", scene_polygons),
    "mesh": ("Mesh", "Soft color blobs, no landscape", scene_mesh),
    "nebula": ("Nebula", "Clouds of color over the stars", scene_nebula),
    "bokeh": ("Bokeh", "Out-of-focus lights", scene_bokeh),
    "contours": ("Contours", "Contour lines of an imaginary relief", scene_contours),
}

LOCK_SCALE = 4          # 3840x2160 -> 960x540
LOCK_BLUR = 4           # raio gaussiano na imagem reduzida (~16 px em 4K, como o blur antigo da tela)
THUMB = (480, 270)

PALETTES = {}           # preenchido em main() (e nos processos filhos, via initializer)


def init_palettes(p):
    global PALETTES
    PALETTES = p


def boot(out, palettes):
    """Imagens da tela de boot: Limine (4K) e Plymouth (1080p, vai dentro do initramfs)."""
    P = Pal("boot", palettes["dracula"], boot=True)
    img = scene_mountains(P, 3840, 2160, False, horizon=0.66, orb=(0.80, 0.20), orb_radius=0.035)
    img.save(f"{out}/boot-limine.png")
    img.resize((1920, 1080), Image.LANCZOS).save(f"{out}/boot-plymouth.png")
    print("ok boot")


def render_job(out, pid, scene, portrait):
    P = Pal(pid, PALETTES[pid])
    W, H = PORTRAIT if portrait else LANDSCAPE
    name = "secondary" if portrait else "primary"
    img = SCENES[scene][2](P, W, H, portrait)
    img.save(f"{out}/{pid}/{scene}/{name}.png")
    return f"{pid}/{scene}/{name}"


def derive(out, pid, scene, dark):
    """Versões lock (pequenas, desfocadas) e a miniatura, a partir das imagens já geradas."""
    for name in ("primary", "secondary"):
        src = f"{out}/{pid}/{scene}/{name}.png"
        if not os.path.exists(src):
            continue
        img = Image.open(src).convert("RGB")
        if name == "primary":
            img.resize(THUMB, Image.LANCZOS).save(f"{out}/{pid}/{scene}/thumb.png")
        img = img.resize((img.width // LOCK_SCALE, img.height // LOCK_SCALE), Image.LANCZOS)
        img = img.filter(ImageFilter.GaussianBlur(LOCK_BLUR))
        if dark:
            img = ImageEnhance.Brightness(img).enhance(0.9)
        img.save(f"{out}/{pid}/{scene}/{name}-lock.png")


def present(out, pid):
    return [s for s in SCENES if os.path.exists(f"{out}/{pid}/{s}/primary.png")]


def manifest(out, palettes):
    """<pasta>/<paleta>/scenes.json por paleta e o catálogo <pasta>/scenes.json."""
    rendered = []
    for pid in palettes:
        scenes = present(out, pid)
        if not scenes:
            continue
        rendered.append(pid)
        with open(f"{out}/{pid}/scenes.json", "w") as f:
            json.dump({"palette": pid, "scenes": scenes}, f, indent=2)
            f.write("\n")
    catalog = {"scenes": [{"id": s, "label": SCENES[s][0], "description": SCENES[s][1]} for s in SCENES],
               "palettes": rendered}
    with open(f"{out}/scenes.json", "w") as f:
        json.dump(catalog, f, indent=2)
        f.write("\n")
    print("ok scenes.json:", ", ".join(rendered))


def workers():
    """Processos em paralelo: cada render 4K usa ~1 GB no pico; cuidado em VMs pequenas."""
    try:
        with open("/proc/meminfo") as f:
            kb = int(next(l for l in f if l.startswith("MemAvailable")).split()[1])
    except (OSError, StopIteration, ValueError):
        kb = 8 << 20
    return max(1, min(os.cpu_count() or 1, 8, kb // (1536 << 10)))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("-p", "--palette", action="append", default=[], help="paleta do Theme.qml (repetível)")
    ap.add_argument("--all", action="store_true", help="todas as paletas")
    ap.add_argument("--theme", default=THEME_QML, help="Theme.qml de onde ler as paletas")
    ap.add_argument("what", nargs="*", help="cenas, ou: boot | lock | list")
    a = ap.parse_args(argv[1:])
    palettes = load_palettes(a.theme)
    out = a.out.rstrip("/")
    if a.what == ["list"]:
        print("scenes:")
        print("\n".join(f"  {s:<10} {SCENES[s][0]:<10} {SCENES[s][1]}" for s in SCENES))
        print("palettes:", ", ".join(palettes))
        return 0
    os.makedirs(out, exist_ok=True)
    if a.what == ["boot"]:
        boot(out, palettes)
        return 0
    wanted = list(palettes) if a.all else (a.palette or list(DEFAULT_PALETTES))
    unknown = [p for p in wanted if p not in palettes]
    if unknown:
        print("unknown palette(s):", ", ".join(unknown), "- see 'list'", file=sys.stderr)
        return 2
    if a.what == ["lock"]:
        for pid in wanted:
            for s in present(out, pid):
                derive(out, pid, s, Pal(pid, palettes[pid]).dark)
            print("ok lock", pid)
        manifest(out, palettes)
        return 0
    scenes = a.what or list(SCENES)
    unknown = [s for s in scenes if s not in SCENES]
    if unknown:
        print("unknown scene(s):", ", ".join(unknown), "- see 'list'", file=sys.stderr)
        return 2
    for pid in wanted:
        for s in scenes:
            os.makedirs(f"{out}/{pid}/{s}", exist_ok=True)
    jobs = [(out, pid, s, p) for pid in wanted for s in scenes for p in (False, True)]
    with ProcessPoolExecutor(max_workers=workers(), initializer=init_palettes, initargs=(palettes,)) as pool:
        for done in pool.map(render_job, *zip(*jobs)):
            print("ok", done, flush=True)
    for pid in wanted:
        dark = Pal(pid, palettes[pid]).dark
        for s in scenes:
            derive(out, pid, s, dark)
        print("ok lock+thumb", pid, flush=True)
    manifest(out, palettes)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
