#!/usr/bin/env python3
"""Aplica o tema do BArch no cabeçalho do /boot/limine.conf (Limine 12, limine-entry-tool).

Edita o bloco "### Theme" que o limine-entry-tool já gera (em vez de acrescentar linhas
soltas), atualiza a soma b2sum do papel de parede e deixa o resto do arquivo intacto.
Rode com sudo. Depois rode `limine-update` (o script faz isso e confere o resultado).
"""
import hashlib
import re
import shutil
import subprocess
import sys
import time

CONF = "/boot/limine.conf"
WALL_REL = "/limine/wallpaper.png"
WALL = "/boot" + WALL_REL

import os
# resolução do menu: pode trocar com  RESOLUTION=1920x1080 sudo -E python3 limine-theme.py
RESOLUTION = os.environ.get("RESOLUTION", "1920x1080")   # a GOP da RTX não oferece 4K neste monitor
# menu escondido: QUIET=yes inicia direto (aperte qualquer tecla nos 3 s para ver o menu)
QUIET = os.environ.get("QUIET", "no").lower() in ("yes", "1", "true")

THEME = ([f"quiet: yes"] if QUIET else []) + [
    f"interface_resolution: {RESOLUTION}",
    "term_font_scale: 2x2",
    "interface_branding: BArch",
    "interface_branding_color: ff79c6",
    "interface_help_color: 6272a4",
    "interface_help_color_bright: bd93f9",
    "term_foreground: f8f8f2",
    "term_foreground_bright: ffffff",
    "term_background: 70191a22",
    "term_background_bright: 44475a",
    "term_palette: 21222c;ff5555;50fa7b;f1fa8c;bd93f9;ff79c6;8be9fd;f8f8f2",
    "term_palette_bright: 6272a4;ff6e6e;69ff94;ffffa5;d6acff;ff92df;a4ffff;ffffff",
]
KEYS = re.compile(
    r"^\s*#?\s*(quiet|interface_resolution|interface_branding|interface_branding_colou?r|interface_help_colou?r"
    r"|interface_help_colou?r_bright|term_font_scale|term_foreground|term_foreground_bright|term_background"
    r"|term_background_bright|term_palette|term_palette_bright)\s*:", re.I)


def b2(path):
    h = hashlib.blake2b()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def patch(text, wall_hash):
    lines = text.split("\n")
    # cabeçalho = tudo antes da primeira entrada ("/Nome" ou "/+Nome")
    end = next((i for i, l in enumerate(lines) if l.startswith("/")), len(lines))
    head, body = lines[:end], lines[end:]

    head = [l for l in head if not KEYS.match(l)]
    head = [re.sub(r"^(\s*wallpaper\s*:\s*boot\(\):" + re.escape(WALL_REL) + r")(#[0-9a-f]+)?\s*$",
                   r"\1#" + wall_hash, l) for l in head]
    if not any(re.match(r"^\s*wallpaper\s*:", l) for l in head):
        head += ["", "### Wallpaper with b2sum hash", f"wallpaper: boot():{WALL_REL}#{wall_hash}",
                 "wallpaper_style: stretched"]

    i = next((i for i, l in enumerate(head) if l.strip().lower() == "### theme"), None)
    if i is None:
        head += ["", "### Theme"] + THEME
    else:
        head[i + 1:i + 1] = THEME
    return "\n".join(head + body)


def has_theme(text):
    return "interface_branding: BArch" in text


def main():
    wall_hash = b2(WALL)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(CONF, f"{CONF}.bak-theme-{stamp}")
    with open(CONF) as f:
        text = f.read()
    with open(CONF, "w") as f:
        f.write(patch(text, wall_hash))
    print(f"  ✓ theme written to {CONF} (backup: {CONF}.bak-theme-{stamp})")

    if "--no-update" in sys.argv:
        return
    print("  Running limine-update…")
    r = subprocess.run(["limine-update"], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
        sys.exit("  ✗ limine-update failed (the backup above is untouched)")
    with open(CONF) as f:
        after = f.read()
    ok_theme = has_theme(after)
    ok_hash = wall_hash in after
    print(f"  {'✓' if ok_theme else '✗'} theme kept after limine-update")
    print(f"  {'✓' if ok_hash else '✗'} wallpaper hash up to date")
    if not (ok_theme and ok_hash):
        sys.exit("  limine-update rewrote the header: send me `sudo head -30 /boot/limine.conf`")


if __name__ == "__main__":
    main()
