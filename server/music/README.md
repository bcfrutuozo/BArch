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
   discography) becomes one job per album; disc folders (`CD1`, `Disc 2 - Title`, `Album, disc 2`,
   `Album (CD 3)`: `pipeline.is_disc_folder`) stay one album. `barch music rescan <id>` takes a
   download in again from scratch when an older version split it wrong (the old jobs are
   superseded; one that delivered something should be undone first).
2. **Collect** (`audio.py`), in a work folder: the download is never touched, so it keeps seeding.
   zip/rar/7z are extracted; a CUE that describes an image (FLAC, APE, WV, WAV) is split per track
   with the `flac` tool, sample exact and keeping 16/24 bit, and the split must add up to the image
   sample for sample (an image described by two CUEs, `X.flac.cue` and `X.wav.cue`, is split once);
   a CUE whose image did not come is only a hint; other lossless formats become
   FLAC; anything lossy stops the album. Every track passes `flac -t`.
3. **Match** (`matcher.py`): MusicBrainz releases found from the folder name, the CUE and the old
   tags (or the MusicBrainz id they carry), each scored on the track count of every disc, the length
   of every track, the titles and the names. Accepted only when the best one fits (worst track
   within 7 s, mean within 3 s, names close) and no other release with different titles fits as
   well; editions with the same tracks count as one. When nothing found by the album's name fits,
   the songs are asked instead: four titles spread over the download are searched as recordings,
   the release groups they share (studio albums before box sets and compilations) give their
   releases with the download's track count, scored like the rest; that is how a "The Best Of"
   folder holding *Stormbringer* whole lands on *Stormbringer* (the candidate says so). An edition MusicBrainz lacks with the same
   songs in another order (an LP) is recognized when every track matches one track by title and
   length; it waits for `--keep-order`, then keeps the download's numbering with each song's own
   MusicBrainz title and id (over an album already in the library: --replace or reject, never a merge).
   A download that is one disc where the release has several with the same number of tracks in all
   (a "2LP" ripped as one CUE of 13 tracks, MusicBrainz 6 + 7: *Purpendicular*, MOVLP 361) is matched
   with its tracks spread over MusicBrainz's discs in order, and tagged that way (1.01–1.06,
   2.01–2.07, DISCTOTAL 2), still only when every length fits.
4. **Tags** (`album.py`, `style.py`), only the library's set: ARTIST, ALBUM, TITLE, TRACKNUMBER,
   TRACKTOTAL, DISCNUMBER, DISCTOTAL, DATE, GENRE, MUSICBRAINZ_ALBUMID, MUSICBRAINZ_TRACKID
   (ALBUMARTIST only on Various Artists albums, as the library has them).
   - ARTIST is the album's artist credit on every track (`A; B` for a collaboration). A track
     MusicBrainz credits to someone else (a solo song on a band's compilation: "Don Dokken" on
     The Very Best of Dokken) is tagged like the rest, with a note in the job; a track credited to
     the album's artist and others ("Dokken & X") puts the others in the title as `[feat. X]`.
     Only a Various Artists album keeps each track's own credit.
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
5. **Cover** (`cover.py`): every source is gathered (Cover Art Archive release and release group,
   the images in the download, iTunes, Deezer, Amazon by the release's ASIN, Discogs by name when
   `discogs_token` is in `secrets.json`; square, at least 500 px) and each is looked at on a
   200x200 thumbnail: a scan of an old sleeve has a frame (a flat band at the edge that ends with
   a jump in brightness, on two sides or more). A store's image counts only when artist and album
   match and, if any other source has an image, when it is the same picture (24x24 grey
   fingerprints, correlation 0.75 or more; the same art measured 0.83-0.99, other albums at most
   0.60). The download's images count by their names (`cover.image_role`): Front / Cover / Folder /
   Portada are the front, Back / Contraportada / Booklet / Inlay / CD / Obi are never used, the rest
   come after the named ones. Ranking: confirmed, no frame, store artwork, named front, 1000 px or
   more, larger. A framed scan that still wins has its frame trimmed. A 1000x1000 JPEG embedded in every track and `cover.jpg`. An
   album already in the library keeps its cover; when it is a framed scan and a clean one exists,
   a note says so. **Library covers** (`libcovers.py`, `barch music covers`, Covers in the app):
   check an artist (or everything), see the scan next to the clean artwork, Replace writes
   `cover.jpg`, the embedded picture of every track and uploads Plex's poster; Undo puts the old
   ones back (kept in `<jobs>/covers/undo/`).
6. **Checks**: every required tag filled, no two tracks with the same file name, the cover. Any
   problem: review, never a partial import.
6b. **Already in `/music`** (`merge.py`): the album is completed and fixed, never replaced. First the
   library's MUSICBRAINZ_ALBUMID is checked against the match: a folder that holds *another* album with
   the same name (MusicBrainz has eight "Greatest Hits" release groups for Deep Purple) goes to review,
   to get its own folder with `--album "Greatest Hits (2008)"` or be rejected, never merged. Each
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
   deleted from qBittorrent (inbox folders are removed). Before that its seed numbers go to the
   seed history (below).

A network error on the way (MusicBrainz answering 503, Wikidata down) is not the album's fault:
the job goes back to the queue and waits 2, 4, 8, 16 and 32 minutes between tries, with the error
shown as its problem; only the sixth failure makes it `failed` (Telegram ❌, `barch music retry`).
Anything else that breaks fails at once.

## Review

**In a browser:** `http://<nas>:8338/` (`review.html`, served by the pipeline itself, phone friendly) is the
review queue and the resolve form of the Music app: every job by state, problems, notes, candidates, a
MusicBrainz search by hand (`/api/mb/search`), the merge plan, the proposal with its cover and a title field
per track, the switches (year only, keep order, replace, the tracks to swap), the equivalent `barch music
resolve` line, Resolve / Retry / Reject / Undo (the last two ask for a second press) and the log. When no
cover was good enough, the one you find goes in as a URL or as an upload (`POST /api/jobs/<id>/cover`, the
phone's camera roll works): it is checked (square, at least 500 px), kept with the job as `cover-chosen.jpg`,
shown in place of the proposal's, and Resolve runs the album with it (`barch music cover <id> <file|URL>` does
both at once). Before that is even needed, `barch-events` on the desktop sees the album land in the queue
with only the cover missing (`music.review`, `cover_only`) and the `music-cover` rule runs
`barch music cover-ask <id>`: Claude searches the web for the front (prompt `quickshell/music/job-cover-ask.md`),
checks it and delivers it with `barch music cover`, so the album comes in on its own; **Find cover** in the
Music app does the same on demand, with a hint. It asks once
for the token of `~/.config/barch/music.json` and keeps it in the browser only; over Tailscale that is the
whole setup, nothing else is exposed.

```bash
barch music list                     # what waits, and why
barch music show <id>                # problems, notes, candidates with their scores, the proposal
barch music resolve <id> --release https://musicbrainz.org/release/<mbid>
barch music resolve <id> --date 1981-09-01 --genre "Hard Rock"
barch music resolve <id> --date-year-only   # no source anywhere has the day: YYYY-01-01
barch music resolve <id> --cover https://.../front.jpg --title 1.03="Some Title [Bonus]"
barch music resolve <id> --cover ~/Downloads/front.jpg   # a file: uploaded first (square, >= 500 px), then the album runs with it
barch music resolve <id> --replace-tracks 1.07   # an existing track is wrong: take the download's audio
barch music resolve <id> --replace   # replace the whole album (the old one is kept with the job)
barch music undo <id>                # put /music back as it was before that job
barch music retry|reject <id>
barch music reject <id> --delete     # and the torrent (or inbox folder) goes once every album of it is done or rejected
```

An edition MusicBrainz lacks (a track list that exists nowhere there) is added by hand, with Bruno's
MusicBrainz account: `barch music mb-add <id>` turns the job's download (artist, album, year, every
track with its title and the length measured from the files; `tracks` in the job) into a release
editor seed, a form that opens musicbrainz.org/release/add in the browser already filled in; he checks
and submits there (nothing is written from here, no credentials anywhere), then
`barch music resolve <id> --release <the new mbid>`.

A box set that only reissues albums the library has (Aerosmith's *Box of Fire*: twelve albums plus a
bonus disc) is one job per disc folder; Bruno does not want it (every album once), so its jobs are
rejected with `--delete`. A rejected download never changes Lidarr's monitoring of an album that
already has files; only an album still missing is unmonitored, so the RSS sync does not grab another
copy of what was refused.

Claude can do the same, and does when asked: **Fix with Agent** in the Music app, `barch music fix <id>
["hint"]`, gives him the whole job (prompt `quickshell/music/job-fix.md`, the library's rules spelled
out): he researches, answers with `barch music resolve` / `barch music cover`, waits for the run and
goes on with the next problem until the album is in; he never rejects and never takes `--replace` /
`--replace-tracks` unless the library copy is plainly damaged, so what is left in the queue is a
decision of Bruno's, named in the answer. Jobs live in `/data/music-pipeline/<id>/job.json` with their log.

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
`barch music adopt "<Artist/Album>" <release>` takes an album of `/music` made by hand, once MusicBrainz has it (after
`mb-add`, or a local artist added there), through the pipeline again as a merge into its own folder: the MusicBrainz ids
and the library's rules on its files, the audio never replaced, an undo log (a copy goes through the inbox).
`barch music lidarr-add <mbid> <folder>` tracks an artist `/music` already has at its own folder (BArch profile,
the usual quality profile and root folder, artist monitored, nothing searched on adding: the hourly check does it).
`barch music lidarr-artists [q]` and `lidarr-albums <artist>` show what Lidarr tracks (album ids for
`lidarr-search`); `lidarr-profiles` / `lidarr-profile <name> --primary Album --secondary Studio
--statuses Official --apply all|<artist ids>` define what an artist's list holds (MusicBrainz has 340 "albums"
for Deep Purple: 195 compilations, 73 live, 37 EPs, 24 studio albums; `BArch` = Album + EP, Studio + Compilation
+ Live, Official, on every artist; `BArch Studio` lists the 24 and is unused); `lidarr-lists` / `lidarr-list <Type> <name> field=value..` add an import list from Lidarr's own
schema (`LastFmUser userId=.. count=50`; the Spotify ones need the OAuth step in Lidarr's UI).
`lidarr-queue` shows what Lidarr grabbed and is downloading, `lidarr-queue-remove <ids>|all` drops them (blocklisted,
deleted from qBittorrent; `--keep` leaves the download); `lidarr-commands` the running commands (`lidarr-cancel <id>`
stops a queued one; a started one cannot be stopped, and a RefreshArtist in flight writes every album back as it was
when it started, undoing a monitor change made meanwhile).

**The rule, enforced by the pipeline** (`Lidarr.enforce`, every hour while idle, or `barch music lidarr-enforce`):
Bruno wants every distinct album of every artist (studio, EP, live, compilation; official releases only; no singles,
no bootlegs) and never the same album twice. So every artist is put on the `BArch` metadata profile (`lidarr.profile`
in config.json; "" turns the check off), and every **official** album Lidarr lists without a single file is monitored
and searched once (`lidarr-seen.json` in the jobs folder remembers the ids, so an album unmonitored by hand or by a
reject stays that way). A newly added artist gets the same treatment within the hour. Rejecting a job in the review
unmonitors its album in Lidarr, otherwise the RSS sync would grab another release of it.

*Official* is decided by `canon.py`, not by MusicBrainz's release status: MusicBrainz marks as Official hundreds of
regional EPs, budget compilations and grey-market live records of a big artist (Deep Purple: 616 release groups,
"Stereo Pop Special‐12", "Battle of Deep Purple & Jimi Hendrix"), and Lidarr's status filter lets all of them in. A
studio album always counts; an EP, live album or compilation counts when its release group links to Wikidata or
Wikipedia, or when its title is in the artist's Wikipedia (the article and the discography article, in English, where
only titles in italics count, and in the language of the artist's country, where a distinctive title anywhere in
the text counts too: the Japanese discographies are tables). Of several groups with the same title (the "Burn" EPs
of 1974 next to the album) only one counts. An artist without any Wikipedia article is not judged: all of it counts.
Measured on 2026-11-04: of the albums missing, Deep Purple 297 → 70, Iron Maiden 41 → 14, T‐SQUARE 24 → 17 (the
Japanese article finds the archive live albums), Insomnium 7 → 7. An album already monitored that turns out
unofficial is unmonitored once (monitored again by hand, it stays); an album with files is never touched. The
verdicts are cached per artist for a week (`canon.json` in the jobs folder) and the hourly run judges artists for
at most five minutes, so the first pass over the library takes a few hours; an artist not judged yet waits.
`barch music lidarr-albums <artist>` shows each album's verdict (`studio`, `wikidata`, `wikipedia`, `unofficial`)
and judges the artist on the spot. Since this check is what monitors a new album, every artist is kept on "monitor new
items: none" (`lidarr.canon: false` in config.json goes back to "all" and every album the profile lets in).

## Upkeep (what runs between jobs)

The loop works the queue first; when it is empty it runs the hourly Lidarr check and then the library
sweep, one album per turn, so a new download never waits for either.

- **Library sweep** (`library.py`, `library.json` and `library-undo/` in the jobs folder; `library_sweep: false`
  turns it off): every album folder of `/music` without MusicBrainz ids goes through `matcher.find` with the
  lengths read from its own files (tags or the `1.03 - ` name give disc and position; a "(2008)" folder suffix
  is dropped for the search). Accepted (the same rules as a download: lengths, names, no rival with other
  titles, nothing reordered or cut) -> `MUSICBRAINZ_ALBUMID` and `MUSICBRAINZ_TRACKID` written on the files,
  only those, the old values in an undo log, and a Lidarr `RescanFolders` of that artist's folder. Otherwise the
  album waits with its candidates (`GET /api/library/sweep`, the Music app's Library tab: compare, `tag`,
  `skip`, `retry`, `barch music mb-add "Artist/Album"`); "none" and "ambiguous" are tried again after a month.
  About 30 s per album (MusicBrainz's one request per second): the first pass over the library takes hours.
- **Release profile** (`Lidarr.release_rules`, every hour): one profile ignoring box sets, discographies and
  "complete albums" packs (`Lidarr.BLOCK`, regexes on the release title), restored if edited. Vinyl rips are
  not blocked (Purpendicular came right from one).
- **Stalled downloads** (`clean_stalled`, `lidarr.stalled_hours`, 48; 0 off): a queue item whose torrent is
  stalled, fetching metadata or in error with no activity for that long, at two hourly checks in a row, is
  removed with its download, blocklisted, and Lidarr searches another release; Telegram says which.
- **Pending artists** (`lidarr-pending.json`): `add-artists` keeps the ones Lidarr's metadata server does not
  know yet (it copies new MusicBrainz artists days later) and tries them every hour; Telegram says when one is in.
  Adding artists cancels the whole-library `RescanFolders` Lidarr queues per artist (about 40 min each) and
  queues one of just their folders.
- **Same title, own folder**: an album whose library folder already holds another release group with the same
  title gets `--album "<title> (<year>)"` by itself (one try; a second collision goes to the review).
- **Box set discs**: "1975 - Toys In The Attic (CD3 - Box Of Fire)" -> album "Toys In The Attic", year 1975, and
  the box is searched too; a candidate box whose disc 3 has the same track count is scored as that disc (below
  the album standing alone).
- **Digest** (`GET /api/digest`, `barch music digest`; `digest: false` off): the week in one Telegram message
  on Sundays at 18:00, with what the torrents removed that week seeded.
- **Seed history** (`seeds.py`, `GET /api/seeds[?days=N&live=1]`, `barch music seeds [days] [--live]`): qBittorrent
  forgets a torrent once deleted, so every torrent the pipeline removes (imported, rejected with delete, or
  stalled and replaced) is read first and appended to `<jobs>/seed-history.jsonl`: size, downloaded, uploaded,
  ratio, seeding and active time, added/finished, the swarm, private or not, the tracker hosts (never the
  announce URL: a private tracker's carries the passkey) and the reason. Shown in total, per tracker and the
  latest; `--live` adds the torrents still in the client. Nothing from before 2026-11-04 exists.

## Tests

`python3 -m unittest discover -s server/music/tests` (run by `scripts/check.sh`);
`LIBRARY_JSON=<scan of /music>` adds the check of every file name of the library.
