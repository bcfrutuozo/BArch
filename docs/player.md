# Player

The music library on the NAS played on this desktop.

**Player** (`quickshell/player/`, "Player" in the launcher, `barch player [page]`): the music library on the
NAS played on this desktop, in the bar's theme, in the spirit of [omaTUNES](https://github.com/Balthazzahr/omatunes).
The library is never scanned from here: the pipeline on the NAS keeps a **catalog** of `/music`
(`server/music/catalog.py`: every album with its tracks' tags, lengths and formats, an album read again only when
its files change, every 15 min and right after a delivery; `GET /api/catalog`, gzip), the app fetches it once
(`~/.cache/barch/player/catalog.json`) and asks again with `?since=<version>`, so an album the pipeline delivered
shows up by itself. The audio comes from the share (`/mnt/nasfrutuozo/media/music`; the covers too: `cover.jpg`, `cover.png`, `folder.jpg`...,
and an album with only the picture embedded in its tracks gets it from the API) or, when it is
not mounted, streamed from the API (`/api/catalog/stream`, with Range). Playback is an **mpv** the app starts
(`player/mpv.sh`: `--no-config`, audio only, gapless, idle) and drives over its JSON IPC socket; mpv holds the
queue, so prev/next and gapless are its own, and with `mpv-mpris` installed (`pacman -S mpv-mpris`) the bar's
media island, `playerctl` and the voice commands see it. Pages: **Albums** (covers; sort by artist, title, year,
recently added, most played; hover plays), **Artists**, **Tracks** (every track as a table, sortable, grouped by
album / artist / genre / year), **Genres**, **Queue** (drag to reorder, remove, save as a playlist), **Favorites**,
**Recent**, **Lyrics** (a `.lrc` next to the file or the LYRICS tag through the API, else
[LRCLIB](https://lrclib.net); synced lines follow the music, a click seeks), **Statistics** (day / week / month /
year / all time: plays, hours, the top artists, albums and genres by minutes, a leaderboard's top 100 tracks),
**Playlists** (hand-made, dragged into order; **smart**: rules on artist, album, genre, title, year, likes, plays,
when it was played, sort and limit, evaluated when opened), **Visualizer** (the spectrum of what plays, drawn on
the GPU: `viz.frag` (a ShaderEffect; `make-shaders.sh` compiles it with qsb) draws bars, mirror, wave, radial
around the cover or dots from a one-pixel-high texture of the bands that the scene graph eases between frames, so
it moves at the display's rate; 24 to 128 bands, sensitivity, the palette's colors or the accent or a heat scale,
the cover blurred behind, trails (the previous frame fed back into the shader), and a small version in the bottom
bar. `player/viz.py` captures the player's own PipeWire stream, the mpv node `barch-player`, never the microphone
or the rest of the desktop, as `barch-player-viz`, which the privacy indicator ignores; FFT in numpy, log-spaced
bands, 60 frames a second, only while a view wants them), **Equalizer** (ten octave bands from 31 Hz to 16 kHz,
±12 dB, a preamp, thirteen presets, the response curve; applied live as mpv's `af` chain of lavfi `equalizer`
filters, so it holds for every output, Bluetooth included) and **Settings**. **Plex and Tautulli** see what plays
here: the player reports each track to the pipeline (`POST /api/player/timeline`, `server/music/plexplay.py`),
which finds the track in Plex by its file path (cached) and sends Plex a client's timeline (`/:/timeline`,
product "BArch Player", client `barch-player-<hostname>`, a session per track, playing every 10 s, paused,
stopped), so Plex counts the play, shows it in Now Playing and Tautulli writes it in its history like a Plexamp
play; the Plex token never leaves the NAS. A switch in Settings turns it off; `barch player plex` shows the last
report and what Plex's Now Playing has. The music does not depend on the window: closing it (Ctrl+W, Super+W,
the X) keeps the process and the music, and a note button shows up next to the tray in the bar's right island
(`media/PlayerTray.qml`, from `~/.local/state/barch/player/window.json`; accent while playing, the track in its
tooltip; click brings the window back, middle click pauses, right click quits) until the window is open again;
Ctrl+Q quits; a closed window with nothing playing quits by itself after a minute. Closed from the player itself
the window is only hidden, so it is back at once; closed by the compositor it is rebuilt (its pages load on first
visit, so that is quick too). Right-click on any row or cover:
play, play next, add to queue, add to playlist, like, go to album / artist, open folder. An album view with
Play / Shuffle / Play next / Queue and the format badge (`16-bit · 44.1 kHz`). Search across artists, albums and
tracks (`/`). Keyboard: Space, N / P, ← →, S, R, + −, M, L, Q, Y, Esc. A play counts once a track passes half its
length (or four minutes). Likes, play counts, the history, the playlists, volume, shuffle, repeat and the last queue
(restored paused at the next start) live in `~/.local/state/barch/player/state.json`, one JSON like omaTUNES's.
`barch player play|pause|toggle|next|prev|status|volume|seek|like|shuffle|repeat`, `barch player play-album
"Artist/Album"`, `playlist <name>`, `search "text"`, `eq rock|on|off|band 3 +4|preamp -3`, `catalog refresh` talk
to the open window over IPC.
