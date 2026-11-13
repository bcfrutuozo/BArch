# Books

The book stack on the NAS (`server/books`, its README for the containers) through the Books app.

**Books** (`quickshell/books/`, "Books" in the launcher, `barch books browse [search|shelf|requests|rejected|downloads]`):
the book stack on the NAS (`server/books`: Shelfmark, Calibre-Web-Automated, Audiobookshelf) through
Shelfmark's API (`books.py` next to it, the same calls `barch books` makes; Shelfmark's admin key in
`~/.config/barch/books.json`, the Hardcover token stays in Shelfmark). **Search**: Hardcover books with
their covers, series and whether the library has them, and a **Want to Read** button that puts the book
on the Hardcover shelf Shelfmark's Hardcover Sync turns into requests and downloads (hourly, or **Sync
now**). **Want to Read**: the shelf with what became of each book (not synced yet, needs a decision,
downloading, in the library). **Requests**: the ones the automatic download found no strict match for
(a misspelt author, a subtitle no release carries), with the reason, a release search whose query you
fix (title and surname by default, every source or one), **Download** on the right release, **Accept** (a window with the
releases, the ones that fit the request first, the best marked: the automatic rule minus the author's
surname, EPUB first, scanned DjVu last; you pick the one to download), Reject or Back to pending, and **Fix with Agent** (`barch books fix <id> ["hint"]`, prompt `quickshell/books/request-fix.md`):
Claude finds out what the book really is, searches with better queries and downloads the right release
once, or says what is missing; it never rejects. **Rejected**: everything you said no to (an audiobook you skipped, say), with the same
release search: **Download** on one takes the request back and downloads it. **Downloads**: Shelfmark's queue with progress.
