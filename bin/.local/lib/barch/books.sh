# shellcheck shell=bash
# barch: books: the book stack on the NAS through Shelfmark (quickshell/books/books.py).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# books: the book stack on the NAS (server/books) through Shelfmark's API; quickshell/books/books.py
# does the calls (it is what the Books app runs too) and answers JSON.
BOOKS_PY=$HOME/.config/quickshell/books/books.py
books_py() {
  OUT=$(python3 -I "$BOOKS_PY" "$@") || die 1 "$(jq -r '.error // "books.py failed"' <<<"$OUT" 2>/dev/null || echo "books.py failed")"
}

# books fix <request id> ["hint"]: a request no source matched by itself (a misspelt author, a subtitle
# no release carries, a book only under another title): Claude finds out what the book really is,
# searches the releases with better queries and downloads the right one, or says what is missing.
books_fix() {
  local id=${1:-} hint=${2:-} run rc=0
  [[ -n $id ]] || usage_error "books fix <request id> [\"hint\"]"
  need claude
  books_py request "$id"
  run=$STATE/books-agent/request-$id-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$run"
  {
    echo "# Context"
    echo
    echo "- Request id: \`$id\` (use exactly this with barch books releases / fulfil / reject)"
    echo "- Run folder (write here only): $run"
    if [[ -n $hint ]]; then echo; echo "## Bruno's hint"; echo; echo "$hint"; fi
    echo
    echo "## The request"
    echo
    echo '```json'
    jq '.request | del(.book_data.description)' <<<"$OUT"
    echo '```'
  } >"$run/context.md"
  { cat "$REPO/quickshell/.config/quickshell/books/request-fix.md"; echo; cat "$run/context.md"; } >"$run/prompt.md"
  local allowed=(Read WebSearch WebFetch "Bash(barch books request *)" "Bash(barch books releases *)"
                 "Bash(barch books fulfil *)" "Bash(barch books search *)" "Bash(jq *)" "Bash(head *)" "Bash(cat *)")
  local schema='{"type":"object","properties":{"summary":{"type":"string"},"downloaded":{"type":"boolean"}},"required":["summary","downloaded"]}'
  (cd "$run" && timeout "${BOOKS_CLAUDE_TIMEOUT:-20m}" claude -p --model "${BOOKS_CLAUDE_MODEL:-sonnet}" --output-format json \
    --permission-mode dontAsk --strict-mcp-config --add-dir "$run" --json-schema "$schema" \
    --disallowedTools Edit Write NotebookEdit --allowedTools "${allowed[@]}" \
    <"$run/prompt.md" >"$run/result.json" 2>"$run/claude.log") || rc=$?
  cost_log books-agent "$(jq -r '.total_cost_usd // empty' "$run/result.json" 2>/dev/null)" "fix $id"
  jq -e '.structured_output | type == "object"' "$run/result.json" >/dev/null 2>&1 ||
    die 1 "Claude did not finish (exit $rc): see $run/claude.log"
  OUT=$(jq -c --arg id "$id" --arg run "$run" '{ok: true, id: $id, run: $run, summary: .structured_output.summary,
    downloaded: .structured_output.downloaded, session: .session_id, cost: .total_cost_usd}' "$run/result.json")
  show "$OUT" '.summary'
}

books_req_line='"#\(.id)  \(.status)\(if .delivery and .delivery != "none" then "/" + .delivery else "" end)  \(.type)\t\(.title) — \(.authors | join(", "))\(if .year then " (\(.year))" else "" end)\(if .reason != "" then "\n      " + .reason else "" end)\(if .admin_note != "" then "\n      note: " + .admin_note else "" end)"'

cmd_books() {
  local sub=${1:-status}
  (($#)) && shift
  case $sub in
    browse) app_open books BARCH_BOOKS_PAGE "${1:-}" ;;
    status)
      books_py status
      show "$OUT" '"shelfmark: " + (if .requests.error then .requests.error else "\(.requests.pending) pending of \(.requests.total) requests" end) + " · \(.active) in the queue"' ;;
    search)
      [[ -n ${1:-} ]] || usage_error "books search <query>"
      books_py search "$@"
      show "$OUT" '.books[] | "\(if .want then "★" else " " end) \(.id)\t\(.title)\(if .subtitle != "" then ": " + .subtitle else "" end) — \(.authors | join(", "))\(if .year then " (\(.year))" else "" end)\(if .owned then "  [in library]" else "" end)"' ;;
    shelf)
      books_py shelf
      show "$OUT" '.books[] | "\(.id)\t\(.title) — \(.authors | join(", "))\(if (.requests | length) > 0 then "  [" + (.requests | map("\(.type) \(.status)" + (if .delivery and .delivery != "none" then "/" + .delivery else "" end)) | join(", ")) + "]" else "  [not synced yet]" end)"' ;;
    want|unwant)
      [[ -n ${1:-} ]] || usage_error "books $sub <hardcover book id>"
      if [[ $sub == want ]]; then books_py want "$1"; else books_py want "$1" --off; fi
      show "$OUT" '"\(.id): " + (if .want then "on Want to Read" else "off Want to Read" end)' ;;
    sync)
      books_py sync
      show "$OUT" '.message' ;;
    requests|list|rejected)
      [[ $sub == rejected ]] && set -- rejected
      books_py requests "${1:-pending}"
      show "$OUT" ".requests[] | $books_req_line" ;;
    show|request)
      [[ -n ${1:-} ]] || usage_error "books show <request id>"
      books_py request "$1"
      show "$OUT" ".request | $books_req_line + (if .url != \"\" then \"\n      \" + .url else \"\" end) + (if .release then \"\n      release: \(.release.source) \(.release.title)\" else \"\" end)" ;;
    releases)
      [[ -n ${1:-} ]] || usage_error "books releases <request id> [--query Q] [--source S] [--type ebook|audiobook]"
      books_py releases "$@"
      show "$OUT" '"\(.releases | length) releases for #\(.request.id) \(.request.title) (searched: \(.searched | join(", ")))" + (if (.errors | length) > 0 then "\nerrors: \(.errors)" else "" end) + "\n" + (.releases | map("  [\(.n)] \(.source)\(if .indexer != "" then "/" + .indexer else "" end)  \(.format) \(.language) \(.size)\(if .seeders != null then " \(.seeders)s" else "" end)\t\(.title)") | join("\n"))' ;;
    fulfil|download)
      [[ -n ${1:-} ]] || usage_error "books fulfil <request id> --pick N"
      books_py fulfil "$@"
      show "$OUT" '"#\(.request.id // "?"): downloading \(.release.source) \(.release.title)"' ;;
    accept)
      [[ -n ${1:-} ]] || usage_error "books accept <request id> [--query Q] [--source S]"
      books_py accept "$@"
      show "$OUT" '"#\(.request.id // "?"): downloading \(.release.source) \(.release.format) \(.release.title) (best of \(.candidates))"' ;;
    reject|reopen|cancel)
      [[ -n ${1:-} ]] || usage_error "books $sub <request id>"
      books_py "$sub" "$@"
      show "$OUT" '"#\(.request.id): \(.request.status)"' ;;
    downloads)
      books_py downloads
      show "$OUT" '.items[] | "\(.bucket)\t\(if .progress then "\(.progress | floor) %  " else "" end)\(.title) — \(.author)  [\(.source) \(.format)]\(if .message != "" then "\n      " + .message else "" end)"' ;;
    fix) books_fix "$@" ;;
    install) exec "$REPO/server/books/install.sh" "$@" ;;
    *) usage_error "books status|browse|search|shelf|want|unwant|sync|requests|rejected|show|releases|fulfil|accept|reject|reopen|cancel|downloads|fix|install" ;;
  esac
}
