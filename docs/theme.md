# Theme and wallpapers

One theme for everything: the palettes, what is generated from them, and the wallpapers drawn in their colors.

`quickshell/.config/quickshell/theme/palettes.json` holds the palettes and `theme/Theme.qml`
derives everything from them. A palette is ten tones (`crust`, `base`, `surface`, `overlay`,
`subtext`, `text`, `accent`, `green`, `yellow`, `red`, the Catppuccin names) plus a label and,
optionally, sixteen official terminal colors (`ansi`); without them the terminal colors are
derived (`palette/palette.js`, shared with the editor). It ships with forty, each with the
official colors of its theme: twenty-six dark (OLED, Dracula, Catppuccin Mocha / Macchiato /
Frappé, Tokyo Night and Storm, Nord, Gruvbox, Solarized, Rosé Pine and Moon, Everforest,
Kanagawa and Dragon, One Dark, Ayu Dark and Mirage, GitHub Dark, Monokai Pro, Flexoki, Night
Owl, Palenight, Oxocarbon, Horizon, Nightfox) and fourteen light (Catppuccin Latte, Nord Light,
Snow, Paper, Solarized Light, Rosé Pine Dawn, Everforest Light, One Light, Ayu Light, GitHub
Light, Flexoki Light, Gruvbox Light, Tokyo Night Day, Dayfox). A tone that failed the editor's
contrast checks with its official value was moved in lightness just enough to pass (mostly
accents and yellows of the light ones). Whether a palette is dark comes from its `base`. One
of each side is pinned: the dark one is what Dark mode shows, the light one what Light mode
shows. The **Themes** tile in the Control Center lists them in the two groups with their colors;
a click pins it (`barch theme dark nord`, `barch theme light snow`, `barch theme palettes`; saved
in `~/.local/state/quickshell/flavors.json`).

**Palette editor** (`quickshell/palette/`, its own Quickshell window: **Edit palettes…** in the
Themes tile, `barch theme edit [palette]`, or "Palette Editor" in the launcher): the ten tones
with hex fields and hue / saturation / lightness sliders, contrast checks (text, subtext and
accent on base, crust on accent, the three state colors), a sample (bar island, buttons, the
sixteen terminal colors, a focused border) and the window itself painted with the draft. Every
change goes to the bar as `theme preview`, so the bar, the Hyprland borders, GTK and the lock
show the draft live (a light draft is shown even in Dark mode); **Save** writes it through the
bar (`theme save`, the bar is the only writer of `palettes.json`), pins it on its side and
renders its wallpapers in the background; **Close** puts everything back. **From an image…**
(also `barch theme from-image photo.jpg --id praia`) runs `tools/palette_from_image.py`: the
picture's dominant colors become the background ramp, the most present saturated color the
accent, the nearest hues the green / yellow / red, each pushed to the minimum contrast, and the
result opens in the editor unsaved. Delete refuses a pinned palette. Custom palettes live in the
same `palettes.json`, so they are saved with the repo.

From the pinned pair it generates the colors for
foot, Neovim, the lock screen, the Hyprland borders, GTK 3 (`BArch-dark/light` themes over adw-gtk3),
GTK 4/libadwaita, qt6ct, fontconfig and MangoHud. The Corsair keyboard (K95 RGB Platinum) and mouse (Scimitar RGB Elite)
follow it too: `barch-rgb.service` (`agent/rgb.py`) paints them in the accent through the pipes of
`ckb-next-daemon` (system service of `ckb-next`; its GUI is left closed, or its profile would paint
over this), again when the theme changes, a preview included, when the daemon or a device comes
back and after a resume (the color is repeated for a second, as the ckb-next GUI's frames would be:
the Scimitar Elite's side keypad ignores a single write). In that software mode the keyboard's light key only reports itself, so
the service steps the brightness (100, 66, 33, off) when it is pressed. `barch rgb color green`
(a tone of the palette or a hex), `brightness`, `on|off`; `barch rgb flash red 4` blinks and goes
back, which the `vpn-dropped` rule does. Changing the pinned palette of the mode in use
repaints the bar, the borders, the lock and the open GTK apps at once; terminals, Neovim and Qt
apps already open keep their colors until reopened. `theme-auto` switches the Hyprland theme,
the apps (`apps-theme`: GTK theme, Papirus icons, cursor); the wallpapers are drawn in the colors
of the palette in use (see [Wallpapers](#wallpapers)). Generated files inside the repo are git-ignored.

## Wallpapers

**Wallpapers** on every monitor (a background layer, no hyprpaper), drawn by
`tools/make_wallpapers.py` in the colors of every palette of the theme: it reads the palettes
from `theme/palettes.json` and derives sky, light, water, trees and so on from their ten tones, so
a dark palette renders the night (moon, stars) and a light one the day (sun). Sixteen scenes
(Mountains, Waves, Dunes, Forest, City, Aurora, Lake, Hills, Clouds, Mesa, Retro, Polygons, Mesh,
Nebula, Bokeh, Contours), each in `~/Pictures/Wallpapers/<palette>/<scene>/` as `primary.png`
(main monitor), `secondary.png` (portrait), the small pre-blurred `*-lock.png` copies for the lock
screen and a `thumb.png`. The bar shows the folder of the palette in use, crossfading when the
mode or the pinned palette changes; a palette without a folder yet uses Dracula or Latte
meanwhile and gets rendered in the background the first time it is pinned (about a minute,
with a notification; `barch wallpaper render [palette|all]` does it by hand). The launcher's `b `
mode (also the Wallpaper tile in the Control Center) lists the scenes with thumbnails and marks
the ones in use; Enter asks where to apply it (desktop and lock screen, desktop only, lock
screen only), Shift+Enter applies it to both. The choice lives in
`~/.local/state/quickshell/wallpaper.json` (`barch wallpaper`), which the lock screen watches,
so the two can differ. `make_wallpapers.py ~/Pictures/Wallpapers [-p palette]... [scene...]`
regenerates them (a new scene is a function in `SCENES`; a new palette in `palettes.json` is
enough, and a palette saved in the editor renders its set by itself).
