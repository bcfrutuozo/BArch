# Books (Shelfmark, Calibre-Web-Automated, Audiobookshelf)

Readarr is retired upstream and its metadata server is gone, so books are asked for, not monitored:

```
Shelfmark (search, request) -> Prowlarr / Soulseek (slskd) -> qBittorrent / slskd
   -> ebooks:      /mnt/user/downloads/torrents/books-ingest -> Calibre-Web-Automated -> /mnt/user/media/books
   -> audiobooks:  /mnt/user/media/audiobooks (Author/Title)  -> Audiobookshelf
   -> Kindle (send to e-reader), Kobo / KOReader (sync), OPDS, browser, Audiobookshelf apps
```

| Container | Image | Port | What |
|---|---|---|---|
| `calibre-web-automated` | `crocodilestick/calibre-web-automated:v4.0.8` | 8083 | The ebook library in Calibre's format: everything dropped in its ingest folder is imported (and deleted from there), converted to EPUB, given metadata and a cover; the users of the whole stack |
| `audiobookshelf` | `ghcr.io/advplyr/audiobookshelf:2.37.2` | 13378 | Audiobooks, with its own apps and progress sync |
| `shelfmark` | `ghcr.io/calibrain/shelfmark:1.6.1` | 8084 | Search by book (Hardcover, Open Library), releases from Prowlarr's indexers and Soulseek, one click; marks what the library already has; other users request and an admin approves |

All three on `frutuozoproxy` as 99:100. The templates in `templates/` are the whole configuration:
Shelfmark's variables are its first-start settings (its Settings page overrides them afterwards), so
a rebuilt container comes back the same.

Choices made there:

- **Ebooks go through the ingest folder** (`FILE_ORGANIZATION=rename`, flat): Calibre-Web-Automated
  names and files them in the library. Shelfmark mounts the library read only, only to mark owned books.
- **Audiobooks go straight into the library** as `Author/Title/` (Audiobookshelf has no ingest folder).
- **Logins come from Calibre-Web-Automated** (`AUTH_METHOD=cwa`, its `app.db` mounted read only):
  one user for both. A password changed there needs a Shelfmark restart.
- **Torrents keep seeding** (`PROWLARR_TORRENT_ACTION=keep`): categories `books` and `audiobooks`
  (`/data/completed/books`, `/data/completed/audiobooks`) are in the music pipeline's seed check
  (`server/music`, `seed.categories`), which removes them at ratio 3 after 72 h or after 90 days and
  records them in the seed history, like Radarr's.
- **Languages**: `BOOK_LANGUAGE=pt,en` (each user can change their own).
- **Usenet** through NZBGet (NZBFinder in Prowlarr, tags `lidarr` + `vpn`, 4500 queries a day): categories
  `books` and `audiobooks` with DestDir `/downloads/completed/usenet/{books,audiobooks}`, removed after import
  (`PROWLARR_USENET_ACTION=move`). Shelfmark mounts NZBGet's `/downloads` at the same path, since it takes the
  path NZBGet reports as is. NZBGet's `lidarr` category goes to `/downloads/music-inbox`, which the music
  pipeline imports like a folder dropped by hand (Lidarr does not import finished downloads).

## From the desktop

The **Books** app (`barch books browse`) and `barch books` reach Shelfmark's API with an admin key:
`SHELFMARK_API_KEY` in the container (template) and the same value in `~/.config/barch/books.json`
(`{"shelfmark": {"url": "http://100.100.0.10:8084", "key": "..."}}`, mode 600). Hardcover is searched and
written through Shelfmark, so its token stays there. Search a book, Want to Read, and Hardcover Sync does
the rest; what it cannot match waits in Requests, where a fixed query or Fix with Agent settles it.

## Install

```bash
./install.sh cleanup     # first time: also prints how to remove Readarr, Calibre and Calibre-Web
./install.sh             # stages the templates (Prowlarr key filled in) and prints the Unraid steps
```

Then `barch music install`, so the seed check knows the two book categories.

Order matters once: Calibre-Web-Automated first (it creates the library and `app.db`; default
login `admin` / `admin123`), then Audiobookshelf (a library on `/audiobooks`, an API token), then
Shelfmark with the Hardcover token (hardcover.app/account/api, the scopes listed in its README), the
slskd API key (role `readwrite`) and Audiobookshelf's token.

Updating: change the tag in `templates/`, run `./install.sh`, copy the template again (or edit the
Repository field in the Docker tab).
