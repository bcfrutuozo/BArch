#!/usr/bin/env python3
"""Papéis de parede minimalistas (montanhas em camadas) nas paletas do sistema.

Uso: make_wallpapers.py <pasta>         papéis de parede (claro/escuro, paisagem/retrato)
     make_wallpapers.py <pasta> boot    imagens da tela de boot (Limine e Plymouth)
     make_wallpapers.py <pasta> lock    só as versões da tela de bloqueio (a partir das acima)

Gera, para cada modo (dark = Dracula, light = Catppuccin Latte):
  primary-<modo>.png         3840x2160 (paisagem, AW3225QF)
  secondary-<modo>.png       2160x3840 (retrato, P2723QE)
  primary-lock-<modo>.png    960x540, já desfocada (e 10% mais escura no modo escuro)
  secondary-lock-<modo>.png  540x960, idem
A mesma cena nos dois modos: noite com lua e estrelas / dia com sol.
As versões "lock" são o que a tela de bloqueio (quickshell/lock) mostra: desfocar o PNG 4K na
hora custava ~100 ms de decodificação mais o blur na GPU a cada bloqueio, e o papel de parede
entrava com um pulo; um PNG pequeno já desfocado decodifica em poucos milissegundos.
"""
import sys
import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

RNG_SEED = 7


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


def mix(a, b, t):
    return a * (1 - t) + b * t


PALETTES = {
    "dark": {  # Dracula
        "sky_top": hexrgb("#16171f"),
        "sky_mid": hexrgb("#21222c"),
        "sky_horizon": hexrgb("#3a3550"),       # leve brilho roxo no horizonte
        "glow": hexrgb("#bd93f9"),
        "orb": hexrgb("#e9e6f5"),
        "orb_glow": hexrgb("#bd93f9"),
        "layers": ["#57547c", "#45426a", "#353352", "#25243a", "#17171f"],
        "stars": True,
        "orb_alpha": 0.82,
    },
    "boot": {  # tela de boot: noite Dracula mais escura, para o menu do Limine ficar legível
        "sky_top": hexrgb("#0f1016"),
        "sky_mid": hexrgb("#181922"),
        "sky_horizon": hexrgb("#2c2840"),
        "glow": hexrgb("#bd93f9"),
        "orb": hexrgb("#d9d4ee"),
        "orb_glow": hexrgb("#bd93f9"),
        "layers": ["#3f3d5e", "#33314f", "#28273d", "#1d1d2b", "#121218"],
        "stars": True,
        "orb_alpha": 0.7,
    },
    "light": {  # Catppuccin Latte
        "sky_top": hexrgb("#cdd3e6"),
        "sky_mid": hexrgb("#e3e7f0"),
        "sky_horizon": hexrgb("#f4e6dc"),       # leve calor perto do horizonte
        "glow": hexrgb("#fe640b"),
        "orb": hexrgb("#fbe3c8"),
        "orb_glow": hexrgb("#df8e1d"),
        "layers": ["#c4c8dc", "#aab0ca", "#8f96b5", "#767d9f", "#5c6385"],
        "stars": False,
        "orb_alpha": 0.95,
    },
}


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


def render(mode, W, H, portrait, horizon=None, orb=None, orb_radius=None):
    p = PALETTES[mode]
    rng = np.random.default_rng(RNG_SEED)

    ys = np.linspace(0, 1, H, dtype=np.float32)[:, None]
    xs = np.linspace(0, 1, W, dtype=np.float32)[None, :]

    # horizonte: onde começam as montanhas mais distantes
    if horizon is None:
        horizon = 0.60 if portrait else 0.52

    # ---- céu: gradiente topo → meio → horizonte ----
    t1 = np.clip(ys / horizon, 0, 1)
    sky = np.where(
        (t1 < 0.55)[..., None],
        mix(p["sky_top"], p["sky_mid"], (t1 / 0.55)[..., None]),
        mix(p["sky_mid"], p["sky_horizon"], np.clip((t1 - 0.55) / 0.45, 0, 1)[..., None] ** 1.6),
    )
    img = np.broadcast_to(sky, (H, W, 3)).copy()

    # brilho difuso perto do horizonte
    gy = np.exp(-((ys - horizon) / 0.16) ** 2)
    img = mix(img, p["glow"], (gy * (0.10 if mode == "dark" else 0.07))[..., None])

    # ---- estrelas (só à noite): poucas e discretas ----
    if p["stars"]:
        n = int(W * H / 9000)
        sx = rng.integers(0, W, n)
        sy = (rng.beta(1.2, 2.6, n) * H * horizon * 0.95).astype(int)
        bright = rng.uniform(0.12, 0.55, n) ** 1.5
        for x, y, b in zip(sx, sy, bright):
            r = 1 if b < 0.3 else 2
            y0, y1, x0, x1 = max(0, y - r), min(H, y + r + 1), max(0, x - r), min(W, x + r + 1)
            yy, xx = np.mgrid[y0:y1, x0:x1]
            d = np.sqrt((yy - y) ** 2 + (xx - x) ** 2)
            a = np.clip(1 - d / (r + 0.5), 0, 1)[..., None] * b
            img[y0:y1, x0:x1] = mix(img[y0:y1, x0:x1], p["orb"], a)

    # ---- lua / sol ----
    aspect = W / H
    cx, cy = orb or ((0.70, 0.22) if portrait else (0.74, 0.24))
    radius = orb_radius or (0.085 if portrait else 0.055)          # em fração da altura (paisagem) / largura (retrato)
    scale = W if portrait else H
    dx = (xs - cx) * (W / scale)
    dy = (ys - cy) * (H / scale)
    d = np.sqrt(dx ** 2 + dy ** 2) / radius
    halo = np.exp(-np.clip(d - 1, 0, None) * 1.6) * (0.20 if mode == "dark" else 0.30)
    img = mix(img, p["orb_glow"], halo[..., None])
    disc = np.clip((1.0 - d) * radius * scale * 0.6, 0, 1)        # borda suavizada (~1-2 px)
    img = mix(img, p["orb"], (disc * p["orb_alpha"])[..., None])

    # ---- montanhas em camadas (mais distantes = mais claras/enevoadas) ----
    layers = p["layers"]
    nl = len(layers)
    y = np.arange(H, dtype=np.float32)[:, None]
    for i, col in enumerate(layers):
        c = hexrgb(col)
        k = i / (nl - 1)
        base = H * (horizon + k * (0.30 if portrait else 0.36))
        amp = H * (0.13 - 0.045 * k) * (0.75 if portrait else 1.0)
        period = W * (0.45 - 0.22 * k)
        ridge_n = value_noise_1d(W, 5, rng, period)
        ridge = base - amp * (0.55 + ridge_n) - H * 0.02 * np.sin(np.linspace(0, np.pi * (1.3 + i * 0.4), W) + i)
        cover = np.clip(y - ridge[None, :] + 0.5, 0, 1)            # anti-aliasing da borda
        # névoa na base de cada camada: puxa para a cor do céu no horizonte
        fog = np.clip((y - ridge[None, :]) / (H * 0.18), 0, 1)
        shade = mix(c, c * (0.86 if mode == "dark" else 0.93), fog[..., None])
        haze = (1 - k) * 0.22
        shade = mix(shade, p["sky_horizon"], haze)
        img = mix(img, shade, cover[..., None])

    # ---- dithering: evita faixas nos degradês ----
    img = img + rng.uniform(-0.6, 0.6, img.shape).astype(np.float32)
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


def boot(out):
    """Imagens da tela de boot: Limine (4K) e Plymouth (1080p, vai dentro do initramfs)."""
    img = render("boot", 3840, 2160, False, horizon=0.66, orb=(0.80, 0.20), orb_radius=0.035)
    img.save(f"{out}/boot-limine.png", optimize=True)
    img.resize((1920, 1080), Image.LANCZOS).save(f"{out}/boot-plymouth.png", optimize=True)
    print("ok boot")


LOCK_SCALE = 4          # 3840x2160 -> 960x540
LOCK_BLUR = 4           # raio gaussiano na imagem reduzida (~16 px em 4K, como o blur antigo da tela)


def lock_variants(out):
    """Versões da tela de bloqueio, derivadas dos papéis de parede já gerados."""
    for mode in ("dark", "light"):
        for name in ("primary", "secondary"):
            img = Image.open(f"{out}/{name}-{mode}.png").convert("RGB")
            img = img.resize((img.width // LOCK_SCALE, img.height // LOCK_SCALE), Image.LANCZOS)
            img = img.filter(ImageFilter.GaussianBlur(LOCK_BLUR))
            if mode == "dark":
                img = ImageEnhance.Brightness(img).enhance(0.9)
            img.save(f"{out}/{name}-lock-{mode}.png", optimize=True)
    print("ok lock")


def main(out):
    if len(sys.argv) > 2 and sys.argv[2] == "boot":
        return boot(out)
    if len(sys.argv) > 2 and sys.argv[2] == "lock":
        return lock_variants(out)
    for mode in ("dark", "light"):
        render(mode, 3840, 2160, False).save(f"{out}/primary-{mode}.png", optimize=True)
        render(mode, 2160, 3840, True).save(f"{out}/secondary-{mode}.png", optimize=True)
        print("ok", mode)
    lock_variants(out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
