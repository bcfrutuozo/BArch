#!/usr/bin/env bash
# Refuses a commit that would publish something private: every line of the staged tree is matched
# against the extended regexes in ~/.config/barch/private.txt (one per line, # comments), which
# stays on this machine (your domain, a public address, a hostname). Run by sync.sh after `git add`.
#   ./scripts/private-scan.sh            # exit 1 and the hits when something matches
set -euo pipefail
source "$(dirname "$0")/lib.sh"

list=${BARCH_PRIVATE:-$HOME/.config/barch/private.txt}
step "Private patterns"
if [[ ! -s $list ]]; then
  warn "$list is missing or empty: nothing private is checked (one regex per line, e.g. example\\.com)"
  exit 0
fi
cd "$REPO"
patterns=$(grep -vE '^[[:space:]]*(#|$)' "$list" || true)
[[ -n $patterns ]] || { ok "No patterns in $list."; exit 0; }
if hits=$(git grep --cached -n -I -i -E -f <(printf '%s\n' "$patterns") 2>/dev/null); then
  printf '%s\n' "$hits" | cut -c1-200 >&2
  die "$(wc -l <<<"$hits") line(s) above match $list: move them to a config outside the repo."
fi
ok "Nothing private staged."
