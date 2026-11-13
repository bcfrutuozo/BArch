# Video

Radarr, Sonarr and the PT-BR dub pipeline (`server/video`, its README) through the Video app.

**Video** (`quickshell/video/`, "Video" in the launcher, `barch video browse [search|movies|series|downloads|dub]`):
Radarr, Sonarr and the PT-BR pipeline (`server/video`) through `video.py` next to it (keys in
`~/.config/barch/video.json`, the same as `barch video`). **Search**: TMDB/TVDB lookups through Radarr and
Sonarr, and Add with a profile: *auto* adds it with BArch 4K, looks at the 2160p releases that fit and
falls back to BArch 1080p when none does, then searches. **Movies**: the posters with the checklist of each
file (original-language audio, PT-BR audio, English and PT-BR subtitles; green, red, or dim without a file),
filters (wanted, incomplete, downloading, complete); a click opens the file and its media info, the profile
(4K / 1080p), the dub job, **Search now** and **Releases**: everything the indexers have, ranked (the ones
that fit first), each with why Radarr rejected it, and **Grab** for any of them. **Series**: episodes on
disk and the dub per season; a series opens to its seasons (checklist over the episodes, Search and
Releases per season or episode). The checklist also marks audio in a language beyond the original and
PT-BR (`+deu`, red: a German DL release of an English series; the pipeline trims it, and such releases
score -10000 since 2026-11-08, `BArch: foreign audio`), with a "Foreign audio" filter in Movies; in
Releases the languages badge turns red for the same reason. **Downloads**: Radarr's and Sonarr's queue (a season pack's episodes
together) with progress and warnings; remove, or blocklist and search another. **PT-BR dub**: the jobs
(`m<id>`, `s<series>x<season>`) with the reason they wait, the candidates (Use one), the alignment, the
episodes and the history; Retry / Skip / Unskip; **Find the dub**: a Prowlarr search with your own words
(the Brazilian title, "3ª Temporada": what fits joins the candidates, the rest is listed with why and an
"Add anyway"), a release by magnet/URL, and **Fix with Agent** (`barch video fix <id> ["hint"]`, prompt
`quickshell/video/job-fix.md`): Claude finds the Brazilian title and the editions, searches the indexers
with better queries, queues the right donor and reports; the pipeline downloads and muxes afterwards.
`qs ipc call app select movie|series|dub <id>` opens one.
