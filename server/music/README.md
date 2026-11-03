# Music pipeline

From a finished download to `/music`, in the library's own style, or to a review queue with
the exact reason. It runs as an s6 service inside the linuxserver **beets** container on the
NAS (the beets importer itself is not used), so nothing depends on Unraid's User Scripts.

```
qBittorrent (category lidarr or music) ─┐                       ┌─> /music/Artist/Album/D.TT - Title.flac + cover.jpg
/data/music-inbox/<folder> (manual) ────┴─> collect ─> match ─> tags ─> cover ─> checks ─┤   Lidarr rescan + unmonitor, Plex scan,
                                                                                         │   torrent deleted, Telegram ✅
                                                                                         └─> review (barch music, Telegram ⚠️)
```

## What it does, step by step

1. **Intake.** Every 2 min (or right away via `/done`) it takes the completed torrents of the
   categories in `config.json` that do not carry the `pipeline` tag yet, and the folders in
   `/data/music-inbox` that stopped changing two minutes ago. A torrent with several albums (a
   discography) becomes one job per album; disc folders (`CD1`, `Disc 2`) stay one album.
2. **Collect** (`audio.py`), in a work folder: the download is never touched, so it keeps seeding.
   zip/rar/7z are extracted; a CUE that describes an image (FLAC, APE, WV, WAV) is split per track
   with the `flac` tool, sample exact and keeping 16/24 bit, and the split must add up to the image
   sample for sample; a CUE whose image did not come is only a hint; other lossless formats become
   FLAC; anything lossy stops the album. Every track passes `flac -t`.
3. **Match** (`matcher.py`): MusicBrainz releases found from the folder name, the CUE and the old
   tags (or the MusicBrainz id they carry), each scored on the track count of every disc, the length
   of every track, the titles and the names. Accepted only when the best one fits (worst track
   within 7 s, mean within 3 s, names close) and no other release with different titles fits as
   well; editions with the same tracks count as one. An edition MusicBrainz lacks with the same
   songs in another order (an LP) is recognized when every track matches one track by title and
   length; it waits for `--keep-order`, then keeps the download's numbering with each song's own
   MusicBrainz title and id (over an album already in the library: --replace or reject, never a merge).
4. **Tags** (`album.py`, `style.py`), only the library's set: ARTIST, ALBUM, TITLE, TRACKNUMBER,
   TRACKTOTAL, DISCNUMBER, DISCTOTAL, DATE, GENRE, MUSICBRAINZ_ALBUMID, MUSICBRAINZ_TRACKID.
   - DATE is the original release day, never just the year: the release group's on MusicBrainz,
     the earliest dated edition of that year, Wikidata's publication date, then the release field of
     the album's infobox on every Wikipedia that has it (references removed; only dates of the first
     release's year; the one most of them agree on). Nothing to the day: review. Only when no source
     on earth has it, `--date-year-only` makes it YYYY-01-01.
   - GENRE on every track: the library's for this artist, else MusicBrainz (release group, release,
     artist), else Wikidata (album, artist); none: review.
   - GENRE is the one the library already uses for the artist, else MusicBrainz's.
   - TITLE follows the rules measured over the whole library (`style.py`, `tests/test_style.py`):
     Bruno's title-case dictionary (`title_rules.json`, whole words), official parentheses kept,
     his qualifiers in one trailing `[ ]` in the order feat. → Bonus → Unreleased → kind → Live →
     variant, several guests joined by `; `. `Bonus` = not on the first edition of the album
     (compared by title); `Live` = a live recording on a studio album.
5. **Cover** (`cover.py`): Cover Art Archive (release, release group), the images in the download,
   iTunes, Deezer; square, at least 500 px, the first of 1000 px or more wins; a 1000x1000 JPEG
   embedded in every track and written as `cover.jpg`.
6. **Checks**: every required tag filled, no two tracks with the same file name, the cover. Any
   problem: review, never a partial import.
6b. **Already in `/music`** (`merge.py`): the album is completed and fixed, never replaced. Each
   position is judged by its MusicBrainz length (5 s): missing in the library and right in the
   download → added with the album's own ALBUM/ARTIST/DATE/GENRE; in the library and right → its
   audio stays, whatever the download has; in the library and wrong but right in the download →
   review (`--replace-tracks 1.07`, the original kept with the job). The tracks that stay get the
   library's rules only: style.py on their own TITLE (his choices win over MusicBrainz), the file
   name from the tag, tags outside the set removed (rip proofs CDTOC/CTDB* kept), empty required
   tags filled, the cover embedded when missing. The same date and genre rule as a new album: a
   library album with a year-only DATE gets the full one from the sources (else review), a track
   without GENRE gets the album's. Every change goes to an undo log (`barch music undo <id>`).
   Not caught on purpose: the case of ordinary words (`Young girls`), since the library has
   Portuguese and Japanese titles with lower-case words.
7. **Deliver**: written into a hidden `.pipeline-<id>` folder next to the album, tags read back and
   compared, `flac -t` again, then moved in. File names: `/`→`,` `?`→`!` `:`→`-` `"`→`'`;
   folders: `:` `?` `/`→`_`, `"`→`-`, no trailing dot.
8. **After**: Lidarr rescans the artist and the album is unmonitored (no new download for it),
   Plex scans the folder, and once every album of the torrent is in, the torrent and its files are
   deleted from qBittorrent (inbox folders are removed).

## Review

```bash
barch music list                     # what waits, and why
barch music show <id>                # problems, notes, candidates with their scores, the proposal
barch music resolve <id> --release https://musicbrainz.org/release/<mbid>
barch music resolve <id> --date 1981-09-01 --genre "Hard Rock"
barch music resolve <id> --date-year-only   # no source anywhere has the day: YYYY-01-01
barch music resolve <id> --cover https://.../front.jpg --title 1.03="Some Title [Bonus]"
barch music resolve <id> --replace-tracks 1.07   # an existing track is wrong: take the download's audio
barch music resolve <id> --replace   # replace the whole album (the old one is kept with the job)
barch music undo <id>                # put /music back as it was before that job
barch music retry|reject <id>
```

Claude can do the same (`barch agent ask "resolve the music review"`): the CLI shows everything a
decision needs. Jobs live in `/data/music-pipeline/<id>/job.json` with their log.

## Install / update

```bash
barch music install                  # = server/music/install.sh: code, config, s6 scripts, token
```

then, once, on Unraid: the root commands it prints for the s6 scripts (`beets-init` must be owned by
root and `/config` returns to the container user at every start, so when they change they are
staged in the `temporary` share and installed from there),
`chown -R 99:100 /mnt/user/appdata/beets/pipeline && chmod -R u=rwX,g=rwX,o=rwX` on it (the container
owns it; Unraid's own share permissions, so the SMB user can update it) and `chmod 600` on `secrets.json`; in the beets template
`/mnt/user/downloads/torrents -> /data`, the two `beets-init` folders -> `/custom-cont-init.d` and
`/custom-services.d` (read only), port 8338, network `frutuozoproxy`. Secrets (Lidarr API key, Plex
token, Telegram bot, optional AcoustID key) go in `appdata/beets/pipeline/secrets.json`.
`barch music lidarr-flac-only` sets every Lidarr quality profile to FLAC / FLAC 24bit.

## Tests

`python3 -m unittest discover -s server/music/tests` (run by `scripts/check.sh`);
`LIBRARY_JSON=<scan of /music>` adds the check of every file name of the library.
