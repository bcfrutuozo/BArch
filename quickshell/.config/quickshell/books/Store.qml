// Store.qml — the book stack (server/books) through books.py, next to this file (the same calls
// `barch books` makes): Hardcover search and Want to Read through Shelfmark, the requests the
// automatic download could not settle, their releases, the download queue, Fix with Agent.
pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: store

    readonly property string script: Quickshell.shellDir + "/books.py"

    property var status: ({ requests: {}, active: 0, queue: 0 })
    property bool reachable: true
    property string statusText: ""
    property bool statusBad: false
    property int busy: 0

    // Search
    property string query: ""
    property var results: []
    property int resultsPage: 1
    property bool resultsMore: false
    property bool searching: false
    property var wanting: ({})           // book id -> true while the change is on its way

    // Want to Read
    property var shelf: []
    property bool shelfLoading: false

    // Requests
    property string requestFilter: "pending"
    property var requests: []
    property var selected: null          // the request on the right
    property var releases: []
    property var releasesErrors: ({})
    property var releasesSearched: []
    property bool releasesLoading: false
    property string fixing: ""           // request id Claude is working on
    property var fixResult: ({})         // request id -> { summary, downloaded }

    // Downloads
    property var downloads: []

    readonly property int pendingCount: (status.requests || {}).pending || 0

    function say(msg, bad) { statusText = msg; statusBad = !!bad }
    function openUrl(u) { if (u) Quickshell.execDetached(["xdg-open", u]) }
    function authors(a) { return (a || []).join(", ") }
    function surname(a) { const n = ((a || [])[0] || "").trim().split(/\s+/); return n[n.length - 1] || "" }

    Component {
        id: procComp
        Process {
            id: p
            property var cb: null
            property string out: ""
            property string err: ""
            stdout: StdioCollector { onStreamFinished: p.out = text }
            stderr: StdioCollector { onStreamFinished: p.err = text }
            onExited: (code, status) => { if (cb) cb(out, err, code); p.destroy() }
        }
    }
    function run(cmd, cb) { const p = procComp.createObject(store, { command: cmd, cb: cb }); p.running = true; return p }

    // books(["search", "dune"], d => ...): d is the parsed answer when ok; errors go to the status line
    function books(args, cb, quiet, fail) {
        busy++
        run(["python3", "-I", script].concat(args), (out, err, code) => {
            busy--
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            if (!d) { reachable = false; say("books.py: " + (err.trim().split("\n").pop() || "no answer"), true); if (fail) fail(""); return }
            if (!d.ok) {
                if (/not reachable|refused the key/.test(d.error || "")) reachable = false
                if (!quiet) say(d.error || "Shelfmark refused", true)
                if (fail) fail(d.error || "")
                return
            }
            reachable = true
            if (cb) cb(d)
        })
    }

    function refresh() {
        books(["status"], d => status = d, true)
        loadDownloads()
        loadRequests()
    }

    // ---- search / want
    function search(q, page) {
        query = q.trim()
        if (!query) return
        searching = true
        books(["search", query, "--page", String(page || 1)], d => {
            searching = false
            results = (page || 1) > 1 ? results.concat(d.books) : d.books
            resultsPage = d.page || 1
            resultsMore = d.has_more
            say(results.length + " books for “" + query + "”")
        }, false, () => searching = false)
    }
    function setWant(book, on) {
        const w = Object.assign({}, wanting); w[book.id] = true; wanting = w
        books(on ? ["want", book.id] : ["want", book.id, "--off"], d => {
            results = results.map(b => b.id === book.id ? Object.assign({}, b, { want: on }) : b)
            if (!on) shelf = shelf.filter(b => b.id !== book.id)
            say((on ? "on Want to Read: " : "off Want to Read: ") + book.title)
            done()
        }, false, done)
        function done() { const w2 = Object.assign({}, store.wanting); delete w2[book.id]; store.wanting = w2 }
    }

    function loadShelf() {
        shelfLoading = true
        books(["shelf"], d => { shelfLoading = false; shelf = d.books }, false, () => shelfLoading = false)
    }
    function sync() {
        books(["sync"], d => { say(d.message || "sync started"); syncFollow.restart() })
    }
    Timer { id: syncFollow; interval: 20000; onTriggered: { store.loadShelf(); store.loadRequests(); store.loadDownloads() } }

    // ---- requests
    function loadRequests() {
        books(["requests", requestFilter], d => {
            requests = d.requests
            if (selected) {
                const s = requests.filter(r => r.id === selected.id)[0]
                if (s) selected = s
            } else if (requests.length) select(requests[0])
        }, true)
    }
    function select(r) {
        if (selected && r && selected.id === r.id) return
        selected = r; releases = []; releasesErrors = ({}); releasesSearched = []
    }
    function findReleases(rid, q, source, type) {
        releasesLoading = true; releases = []; releasesErrors = ({})
        const args = ["releases", String(rid)]
        if (q) args.push("--query", q)
        if (source) args.push("--source", source)
        if (type) args.push("--type", type)
        books(args, d => {
            releasesLoading = false
            if (!selected || selected.id !== rid) return
            releases = d.releases; releasesErrors = d.errors || ({}); releasesSearched = d.searched || []
            say(d.releases.length + " releases (" + releasesSearched.join(", ") + ")")
        }, false, () => releasesLoading = false)
    }
    property var fulfilling: ({})        // request id -> true while its Download is on its way (one click counts)
    function fulfil(rid, n) {
        const key = String(rid)
        if (fulfilling[key]) return
        const f = Object.assign({}, fulfilling); f[key] = true; fulfilling = f
        const done = () => { const g = Object.assign({}, store.fulfilling); delete g[key]; store.fulfilling = g }
        say("#" + rid + ": sending the release to Shelfmark…")
        books(["fulfil", key, "--pick", String(n)], d => {
            done()
            say("#" + rid + ": downloading " + (d.release.title || ""))
            selected = null
            releases = []
            loadRequests(); loadDownloads()
        }, false, () => { done(); loadRequests() })
    }
    property var accepting: ({})         // request id -> true while its Accept runs (several at once)
    function setAccepting(rid, on) { const a = Object.assign({}, accepting); if (on) a[String(rid)] = true; else delete a[String(rid)]; accepting = a }
    property var acceptError: ({})       // request id -> why Accept downloaded nothing
    // the best release that carries the title (books.py accept): the listed ones when there are,
    // otherwise a search with the query on screen first
    function accept(rid, q, source) {
        setAccepting(rid, true)
        const args = ["accept", String(rid)]
        if (!(selected && selected.id === rid && releases.length)) {
            if (q) args.push("--query", q)
            if (source) args.push("--source", source)
        }
        const e0 = Object.assign({}, acceptError); delete e0[String(rid)]; acceptError = e0
        say("#" + rid + (args.length > 2 ? ": searching every source for releases (a minute or two)…" : ": picking the best of the releases listed…"))
        books(args, d => {
            setAccepting(rid, false)
            say("#" + rid + ": downloading " + (d.release.title || "") + " (" + [d.release.source, d.release.format].filter(x => x).join(" · ") + ", best of " + d.candidates + ")")
            selected = null; releases = []
            loadRequests(); loadDownloads()
        }, false, err => {
            setAccepting(rid, false)
            const e = Object.assign({}, acceptError); e[String(rid)] = err; acceptError = e
            if (selected && String(selected.id) === String(rid)) findCached(rid)
        })
    }
    // the releases Accept looked at, so they can be picked by hand
    function findCached(rid) { books(["releases", String(rid), "--cached"], d => { if (selected && selected.id === rid) releases = d.releases }, true) }
    function act(what, rid) {
        books([what, String(rid)], d => { say("#" + rid + ": " + d.request.status); loadRequests() })
    }
    function fix(rid, hint) {
        fixing = String(rid)
        say("Claude is working on #" + rid + "…")
        busy++
        const cmd = ["barch", "--json", "books", "fix", String(rid)]
        if (hint) cmd.push(hint)
        run(cmd, (out, err, code) => {
            busy--
            fixing = ""
            let d = null
            try { d = JSON.parse(out) } catch (e) {}
            const r = Object.assign({}, fixResult)
            r[String(rid)] = d ? { summary: d.summary, downloaded: d.downloaded } : { summary: (err.trim() || "Claude did not finish"), downloaded: false }
            fixResult = r
            say(d && d.downloaded ? "#" + rid + ": Claude downloaded it" : "#" + rid + ": Claude answered", !d)
            loadRequests(); loadDownloads()
        })
    }

    // ---- downloads
    function loadDownloads() { books(["downloads"], d => downloads = d.items, true) }

    // every 2 s while something downloads (the progress bars), every 10 s otherwise
    readonly property bool downloading: downloads.some(d => ["downloading", "resolving", "locating", "queued", "processing"].indexOf(d.bucket) !== -1)
    Timer { interval: store.downloading ? 2000 : 10000; running: true; repeat: true; onTriggered: { store.books(["status"], d => store.status = d, true); store.loadDownloads() } }
    Component.onCompleted: refresh()
}
