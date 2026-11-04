# Video rules (Radarr, Sonarr)

What the movie and series library accepts, kept in Radarr and Sonarr by
[Recyclarr](https://recyclarr.dev) (a container on the NAS, daily) from `recyclarr/` here.
`./install.sh` copies it to `appdata/recyclarr/`; the API keys come from
`~/.config/barch/video.json` and go only to the NAS (`secrets.yml`), never into the repo.

## The rule

One quality profile, **BArch 4K**, in both apps:

- **2160p only** (UHD Bluray encodes and WEB-DL/WEBRip), **HEVC only**: a title naming AVC/x264,
  AV1, VC-1, MPEG-2 or VP9 scores -10000 (`BArch: not HEVC`).
- **PT-BR audio required**: `BArch: PT-BR audio` (the language Radarr/Sonarr parse as Portuguese
  (Brazil), or `DUAL`, `Dublado`, `Nacional`, `PT-BR`, `Brazilian`, `Português` in the title) is
  +10000 and the profile's minimum score is 8000. The guide's formats alone add up to about 6900
  at most, so nothing without PT-BR is grabbed, and PT-BR plus any -10000 format is not either.
- HDR wanted (HDR10+ a little more); **SDR** and **Dolby Vision without an HDR10 fallback**
  (purple/green outside a DV player) refused; the guide's unwanted formats (BR-DISK, LQ groups,
  upscaled, 3D, extras…) refused; quality tiers and audio formats of the TRaSH Guides rank the rest.
- Upgrades on (until Bluray-2160p and score 20000), so a file under the bar is replaced.
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

## Files

| File | What |
|---|---|
| `recyclarr/recyclarr.yml` | the profile, the formats and their scores (`!secret` for URLs/keys) |
| `recyclarr/settings.yml` | the local custom formats as a resource provider |
| `recyclarr/custom-formats/{radarr,sonarr}/` | `BArch: PT-BR audio`, `BArch: not HEVC` (trash_id = md5 of `barch:<service>:<name>`) |
| `install.sh` | copies to the NAS; with `RECYCLARR=<binary>` it runs `sync --preview` first |

The container (Unraid template printed by `install.sh`): `ghcr.io/recyclarr/recyclarr:8.8.0`,
`--user 99:100`, `/mnt/user/appdata/recyclarr` → `/config`, `CRON_SCHEDULE=@daily`. After a change:
`./install.sh`, then `docker exec recyclarr recyclarr sync` on Unraid.
