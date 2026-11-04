# Video (Radarr, Sonarr, the PT-BR pipeline)

The rule for movies and series: **2160p, HEVC, HDR, no starved re-encode, the original audio and
PT-BR audio, PT-BR subtitles**. Two pieces keep it:

- [Recyclarr](https://recyclarr.dev) (a container on the NAS, daily) keeps Radarr's and Sonarr's
  profile from `recyclarr/` here: what they may grab.
- The **video pipeline** (`barch_video/`, its own container) adds the PT-BR dub to every file that
  came without it, from another release of the same film, without touching the video.

`./install.sh` (`barch video install`) copies both to the NAS. The API keys live in
`~/.config/barch/video.json` and go only to the NAS (`secrets.yml`, `secrets.json`), never into
the repo.

## The rule

One quality profile, **BArch 4K**, in both apps:

- **2160p only** (UHD Bluray encodes and WEB-DL/WEBRip), **HEVC only**: a title naming AVC/x264,
  AV1, VC-1, MPEG-2 or VP9 scores -10000 (`BArch: not HEVC`).
- **PT-BR audio preferred**: `BArch: PT-BR audio` (the language Radarr/Sonarr parse as Portuguese
  (Brazil), or `DUAL`, `Dublado`, `Nacional`, `PT-BR`, `Brazilian`, `Português` in the title) is
  +2000; the minimum score is 0. Not more than ~2500: the guide's formats add up to about 7400 at
  most, and a -10000 release must stay below 0 with all of them. A 4K release with the dub saves
  the pipeline a step; one without it is grabbed anyway and gets the dub afterwards. No public
  indexer has 4K dual releases (only Brazilian private trackers do), which is why the pipeline exists.
- HDR wanted (HDR10+ a little more); **SDR** and **Dolby Vision without an HDR10 fallback**
  (purple/green outside a DV player) refused; the guide's unwanted formats (BR-DISK, LQ groups,
  upscaled, 3D, extras…) refused; quality tiers and audio formats of the TRaSH Guides rank the rest.
- Upgrades on (until Bluray-2160p and score 20000), so a file under the bar is replaced.
- The old release profiles (`H265 Filter`, `Avoid x264, AVI, MP4`, `MKV Filter`) are disabled in
  both apps: the custom formats do their job, and `MKV Filter` wanted `.mkv` in release names.
- Language of the profile: **Any** (set once by hand; the guide's "Original" would refuse a release
  parsed as PT-BR only).

Left out on purpose: the guide's **Bad Dual Groups** (alfaHD, GUEIRA, SiGLA, C76, XiQUEXiQUE…) are
the Brazilian dual-audio groups. What a title cannot tell is checked on the files themselves.

## Audit

`./audit.py` (read only; Radarr from `~/.config/barch/video.json`, ffprobe over the media share)
checks every movie with a file: HEVC, 2160p, HDR, a video bitrate of at least 10 Mb/s, audio in
the movie's **original language** (Radarr's `originalLanguage`; English is not required for a
movie that is not English) **and in Portuguese**, a Portuguese subtitle. Verdicts: `ok`; `fix`
(only what is fixed in place: subtitle through Bazarr, extra or default audio tracks through
mkvmerge); `replace` (only another release fixes it). `--json` for scripts.

## The PT-BR pipeline

One job per movie Radarr has a file for (`m<radarr id>`), in `/data/video-pipeline/jobs/`:

| State | What |
|---|---|
| `search` | the file has no Portuguese audio: Prowlarr is searched by the original title and the Brazilian one (Wikidata, from the IMDb id) for a dubbed release. Candidates must say `Dublado`/`DUAL`/`Nacional`/`PT-BR`, match the title and year (±1), have seeders, not be cam/TS, subtitled-only or a pack; `DUAL` ranks first (it brings the original audio), then 1080p, Blu-ray, a surround dub, seeders |
| `downloading` | the best one in qBittorrent, category `barch-dub` (`/data/completed/videos/barch-dub`, Radarr never sees it); no progress for 24 h drops it |
| `aligning` | `sync.py`: the donor's timeline mapped onto the 4K file's (below); then the mux, the check, the replacement |
| `done` | the file has PT-BR: muxed, or it came with it |
| `waiting` | no candidate today: searched again every 24 h |
| `review` | four candidates failed, or the 4K file lacks the original audio (that needs another 4K release, not a dub) |
| `skipped` | left alone by hand (`barch video skip`) |

**Alignment** (`barch_video/sync.py`). Both audio tracks are decoded to 8 kHz mono. The envelope is
the spectral flux of the lows (< 250 Hz) and highs (> 3 kHz) only: the voice band is what a dub
changes, music, effects and room tone are what it keeps, so a dub lines up with the original as
well as the original with itself (when the donor is `DUAL`, its original track is used anyway).
Twelve 120 s windows spread over the film are placed in the 4K track by cross-correlation (the
first over ±120 s, the next ones near the offset found, or over ±120 s again when they are not
there); the offset most windows share wins, for each speed the lengths allow (1, PAL 25/23.976,
24/23.976 and their inverses). Nine of twelve windows must agree within 40 ms, in one run:
two runs at different offsets are another cut (a scene added or missing) and the donor is dropped,
like a donor of another master or another film. Tested on Prada 2's own tracks: a 2.5 s delay
came back as −2506 ms, a PAL donor as speed `pal`, a 40 s cut at 50 min was refused with the map
of both runs; `tests/test_sync.py` repeats it on synthetic soundtracks.

**Mux** (mkvmerge, no video re-encode). Into a copy next to the movie: the 4K file's video, its
audio in the original language (other languages dropped; the original first and default), its
Portuguese and English subtitles; from the donor, the Portuguese audio (`pt-BR`, "Português
(Brasil)") and the Portuguese/English **subtitles the 4K file lacks, shifted by the same offset**
(a PAL donor's audio re-timed with ffmpeg's atempo into E-AC-3, its subtitles with mkvmerge's ratio
sync). The copy is checked once more (its PT-BR track against its original along the film, within
40 ms) and only then replaces the file; Radarr rescans and is told the file's languages (original
+ Portuguese (Brazil)), so the PT-BR format scores and Radarr does not go looking for a dual
release. The donor torrent stays seeding (`delete_donor` false): the music pipeline's seed check
(`server/music`, `barch music seeds`) deletes it at ratio 3 after 72 h or 90 days later, recorded
in the seed history.

**Subtitles Bazarr finds** go through Bazarr's own sync against the file's audio: in Bazarr,
Settings > Subtitles > *Automatic subtitles synchronization* on, *Always use Audio Track as
Reference for Syncing* on, and a languages profile with Portuguese (Brazil) (and English).

```bash
barch video status                # counts per state, what it is doing
barch video list [review]         # one line per movie
barch video show m12              # candidates, alignment, history
barch video retry|skip|unskip m12 # search again from scratch / leave alone / take back
barch video use m12 <guid>        # this candidate next
barch video audit                 # the library against the rule, from the files themselves
python3 -m barch_video align <4k file> <donor> [ref_audio_no donor_audio_no]   # in the container: just measure
```

Movies only for now; series (Sonarr) follow the same way once movies run.

## Files

| File | What |
|---|---|
| `recyclarr/recyclarr.yml` | the profile, the formats and their scores (`!secret` for URLs/keys) |
| `recyclarr/settings.yml` | the local custom formats as a resource provider |
| `recyclarr/custom-formats/{radarr,sonarr}/` | `BArch: PT-BR audio`, `BArch: not HEVC` (trash_id = md5 of `barch:<service>:<name>`) |
| `install.sh` | copies Recyclarr's config and the pipeline to the NAS; with `RECYCLARR=<binary>` it runs `sync --preview` first |
| `barch_video/` | the pipeline: `sync.py` (alignment, mux, check), `pipeline.py` (the jobs), `service.py` (API on 8339), `integrations.py` |
| `deploy/` | the s6 scripts (packages, service) and the example config/secrets |
| `audit.py` | `barch video audit` |
| `tests/` | alignment on synthetic soundtracks, the ranking of candidates |

The containers (Unraid templates printed by `install.sh`): `recyclarr`
(`ghcr.io/recyclarr/recyclarr:8.8.0`, `--user 99:100`, daily) and `barch-video`
(`ghcr.io/linuxserver/baseimage-alpine`, the s6 scripts install python3 + numpy/scipy, ffmpeg and
mkvtoolnix at start; `/data`, `/movies`, `/tv` as qBittorrent and Radarr see them; port 8339).
After a change: `barch video install`, then `docker exec recyclarr recyclarr sync` on Unraid.
