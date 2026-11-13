# Music

The music pipeline on the NAS (`server/music`, its own README for the container) and the Music app that drives it. The Player is in [player.md](player.md).

## Music app

**Music** (`quickshell/music/`, "Music" in the launcher, `barch music browse [review|albums|covers|library|artists|lidarr]`): the
music pipeline on the NAS (see [the pipeline](#the-pipeline)) through its API. **Review**: the queue, and for each album what
the pipeline found (the download, the problems, the MusicBrainz candidates with why they fit, the
merge plan for an album already in the library, the proposed files, the log, the cover) and the
inputs of `barch music resolve` as a form: Use a candidate or a release found with the
MusicBrainz search right there (the release picked shows up next to the download track by track:
disc and position, both titles, both lengths and the difference, the rows that do not fit in red,
so you see where a match drifts; `GET /api/jobs/<id>/compare?release=`), date (or the year-only last resort), genre, album, artist folder,
the cover (a URL, or **Upload…** an image found online: checked, kept with the job and shown at
once; **Find cover** sends Claude to search the web for it, `barch music cover-ask <id>`, which
the `music-cover` rule already does by itself for every album that waits only for a cover),
a title per track, keep the download's order, replace the album, the tracks to swap
for the download's (the merge's suggestions are switches); the equivalent command is shown under
it, Resolve queues the album again, Retry and Reject next to it. **Fix with Agent** (`barch music
fix <id> ["hint"]`, prompt `quickshell/music/job-fix.md`) hands the album to Claude: it gets the
whole job, researches MusicBrainz, Wikipedia, Discogs and the web, decides what you would
(release, date, genre, cover, the merge, a folder of its own for a same-title album) with the same
`resolve` and `cover` commands, waits for the run and goes on with the next problem until the album
is in, never rejecting and never replacing your audio on its own; the answer says what it found and,
if something is left, the one decision that is yours. These runs (fix, cover-ask, covers ask)
always use Sonnet (`MUSIC_CLAUDE_MODEL` in the environment overrides it). **Albums**: every job by state,
Undo for a delivered one. **Covers**: the covers already in the library, one artist at a time
(picked from the list of `/music`, filtered as you type): every album of the artist with its cover
as it is and what its last check found, the ones never checked marked as such; Load reads the
folders again, Check is per album (its row) and runs under a veil with the progress while the
list stays still; a replaced one stays marked replaced, with Undo:
the ones that are a scan of the sleeve with a frame next to the clean artwork of the same album,
Replace (cover.jpg, the picture embedded in every track and Plex's poster), Keep mine, Undo; every
candidate found is shown too (a click makes it the proposal), and when none is right, a sentence
about what is wrong goes to **Ask Claude** (`barch music covers ask`, prompt in
`quickshell/music/cover-ask.md`): it looks at the images, adapts one with ImageMagick or searches
the web for another, and adds it as the proposal (Replace is still yours).
**Library**: the library tied to MusicBrainz (see [the pipeline](#the-pipeline)): how far the sweep is, Pause, and the albums
it could not settle, each with its candidates; Use one to see it next to the album's files track by
track, Tag writes its ids, Add to MusicBrainz opens the release editor filled in from the files, Skip.
**Reorder** shows up when the files are the same songs as the release in another order (the comparison
lists the moves, `1.01 → 1.04`): the files are renumbered and renamed to MusicBrainz's order (titles and
audio untouched, undo log kept) and tagged, so the album is as it was catalogued. **Delete** (click twice)
throws the files you have away (kept 30 days in `/music/.library-trash`) and puts the album back in
Lidarr's search, monitored, so the pipeline brings a catalogued edition.
The same from a shell: `barch music library [list|show|compare|tag|reorder|delete|skip|retry]`, and **`barch music library
fix "<Artist/Album>"`** hands one album to Claude (prompt `quickshell/music/library-fix.md`): it reads the
files' lengths and titles, compares the candidates and what MusicBrainz, Discogs and the web say about the
edition, tags the release that fits (never skips; an edition MusicBrainz lacks is left for `mb-add`).
`barch music agent-sweep [library|review|all] [--parallel N]` runs that over every Library album and
`music fix` over every Review job as a detached user unit (one JSON line per album in
`~/.local/state/barch/music-agent/sweep-<stamp>/log.jsonl`, `status` and `stop`), stopping by itself at 90 % of
the Claude plan's week. A sweep over 308 albums ran on 2026-11-08. The sweep also puts MusicBrainz ids an old
tagger wrote in title case (`B15d9a20-…-Ad58`, 15 albums of Taylor Swift, Maroon 5, Tina Turner, Jeremy Soule)
back in lower case, since Lidarr compares them exactly and never mapped those files.
**Artists**: the same for the artist folders of `/music`: Lidarr knows an artist by its MusicBrainz id and keeps one
folder for it, and an album's files only map in the folder of the artist MusicBrainz credits the release to. Each
folder is checked against Lidarr's artists (linked; missing; suspect, when the folder's tied albums are credited to
another MusicBrainz artist than Lidarr's, a namesake; skipped; waiting for Lidarr's metadata server) with the
MusicBrainz artists its own albums are credited to first: **Link** makes the folder that Lidarr artist (a wrong one
leaves Lidarr, files kept), **Move into** puts the albums of a second folder of one artist (`THE SQUARE`, a credit
under another name) into the folder Lidarr tracks it at (an album whose name is there already stays; `--replace` sends that one to
`/music/.library-trash` instead, for the edition you keep), **Skip**.
The Lidarr artists with nothing in `/music` yet (the import lists' ones) can be **Replaced** by the right artist or
removed, and **Add an artist** tracks one the library does not have (one the Spotify lists could not map): the
hourly enforce brings its official albums. A game composer whose albums Lidarr does not list is linked, not
suspect: the BArch metadata profile leaves Soundtrack out. `barch music artists [list|show|find|link|move|add|remove|skip]`.
**Lidarr & scan**: scan now, FLAC only, monitor / search album ids.

## The pipeline

`server/music` (details in its README) runs in its own container on the NAS (`barch-music`) and turns every
finished Lidarr download (and any folder dropped in `/data/music-inbox` or downloaded by Soulseek: slskd + Soularr, `/data/slskd/completed`; slskd reaches the Soulseek server and every peer through the SOCKS5 proxy of the qBittorrent VPN container, `soulseek.connection.proxy` in its `slskd.yml`, so it fails closed without the VPN and has no incoming port; it shares the media folders back, read only, with every metadata and sidecar file filtered out, `shares` in the same file) into an album of
`/music` exactly like the hand-made ones: lossless only, CUE images split per track, the
MusicBrainz release found by track count and lengths, only the library's tags (artist: the album's on
every track, even one MusicBrainz credits to someone else, extra names going to the title; `Various Artists`
albums keep each track's own and get `ALBUMARTIST`; album, title, numbers, the original date to the day (MusicBrainz, Wikidata, every Wikipedia; YYYY-01-01 only when it exists nowhere and Bruno says so), a genre on every track, two MusicBrainz ids), titles in Bruno's style (his
title-case dictionary, one trailing `[feat. A; B - Bonus - Live]` in a fixed order), a cover of at
least 500 px (1000 px when any source has it) embedded and as `cover.jpg`, the label's clean
artwork before a scan of the sleeve (a store's image counts only with the same artist and album
and when it is visibly the same picture as the scan or the Cover Art Archive's; a scan that still
wins has its frame trimmed), file names with the
library's replacements. Then Lidarr rescans and stops looking for the album, Plex scans, the
torrent keeps seeding until ratio 3 after at least 72 h, or 90 days after it finished (`seed` in its
`config.json`; the oldest go first while the downloads disk has less than 100 GB free; the same check
takes the finished torrents of Radarr, Sonarr and the video pipeline's PT-BR donors), and only
then is deleted, once what it seeded (uploaded, ratio, seed time, tracker) is in a seed history
(`barch music seeds [days] [--live]`: what is seeding and how far from its goal, the history per
tracker; the stalled downloads it replaces are recorded too; `barch music seeds check` runs the hourly check now). An album that is already there is completed (the missing tracks only) and
fixed by the library's rules, never replaced, with an undo log; a track of Bruno's that looks wrong
is only swapped with his ok. Anything it cannot do completely (no match, a year-only date, no
cover) waits in a review queue with the reason and the candidates:
`barch music list`, `barch music show <id>`, `barch music resolve <id> --release …|--date …|--cover …`,
all of it in the **Music** app (`barch music browse`), or from the phone: the pipeline serves the same
review queue and resolve form as a page at `http://<nas>:8338/` (asks for the `barch music` token once). What comes in starts
in Spotify too: three Lidarr import lists (since 2026-11-12) add the albums saved there, the artists followed and the
albums of the tracks of the playlist 🫧 (`barch music lidarr-lists`); a new artist gets the official discography like any
other (below), nothing is removed when it leaves Spotify (Lidarr 3 has no list cleaning). Their OAuth goes through
`spotify.lidarr.audio`, which also renews the token at each daily sync. On the Lidarr side it enforces the library's rule every
hour: every artist on the `BArch` metadata profile (every distinct album: studio, EP, live, compilation), and every
official album without a file monitored once, new ones too. "Without a file" is checked against `/music`, not only
against Lidarr's count: an album whose folder exists in the library is never monitored or searched (and is unmonitored
at every run if it is, partial ones too: Lidarr counting 24 of 137 tracks of a box-set release is still Bruno's "On Air";
a bonus track or a tie is the Library tab's job, `lidarr-search` fetches one by hand), and the albums of an artist the
MusicBrainz sweep has not finished wait for it. Only dotfiles are skipped when `/music` is listed: an album whose title
starts with "..." counts (the sweep, the enforce and the Player's catalog all skipped those until 2026-11-08). Lidarr had mapped
only 4 % of the hand-made library until 2026-11-03, so its "missing" list was mostly albums Bruno had; on 2026-11-04
the enforce searched 122 of them and Soularr (which downloads Lidarr's missing list from Soulseek) fetched dozens
more, 66 of which the pipeline then merged into albums already there with nothing to change. Tying an album Lidarr
cannot map (no ids yet, or a release its metadata lacks) is the Library tab's job, never a download's. Official is not MusicBrainz's status (it calls hundreds of
regional EPs and budget compilations of a big artist Official): an EP, live album or compilation counts only when
Wikidata or the artist's Wikipedia (English and the artist's own language) knows it, so Deep Purple goes from 297
missing albums to 70; an artist without Wikipedia is not filtered (`server/music/canon.py`, `barch music
lidarr-albums <artist>` shows each verdict). An album already in the library is completed, and
another album with the same title (the eight "Greatest Hits" of Deep Purple) gets its own folder and ALBUM with its
year by itself (`Greatest Hits (2008)`). One disc of a box set split per disc ("1975 - Toys In The Attic (CD3 - Box Of
Fire)") is matched as the album it is, or as that disc of the box when the album does not stand alone.

It also serves the **Player** (see [player.md](player.md)): `/api/catalog` is every album of `/music` with its tracks, kept fresh by
the files' names, sizes and mtimes (`catalog.py`), `/api/catalog/stream` the audio with Range for a desktop without the
share, `/api/catalog/lyrics` a `.lrc` or LYRICS tag; `barch player catalog refresh` reads the folders again now. `/api/player/timeline`
(`plexplay.py`) turns what the player plays into a Plex client's timeline, so Plex and Tautulli count it (Plex over https:
"Secure connections: Required" refuses plain HTTP, the client moves to https by itself).

What it keeps tidy by itself (2026-11-04): **the library tied to MusicBrainz**: while no download waits, it goes over
every album of `/music` and matches it with the lengths of its own files; a sure match gets `MUSICBRAINZ_ALBUMID` and
`MUSICBRAINZ_TRACKID` on its files (nothing else, an undo log kept) and Lidarr rescans that artist, so the hand-made
library stops being unmapped files; the rest waits in the Music app's Library tab. **What Lidarr grabs**: a release
profile it keeps ignores box sets, discographies and "complete albums" packs (`barch music lidarr-release-profiles`);
a download with no progress for 48 h at two hourly checks in a row is blocklisted and another release searched
(`lidarr-stalled` shows them); an artist Lidarr's metadata server does not know yet (one just added to MusicBrainz)
waits and is added within the hour once it does (`lidarr-pending`). **The week** in one Telegram message on Sundays
at 18:00 (`barch music digest`): albums in, the review and why, Lidarr's queue, the sweep, artists waiting.
