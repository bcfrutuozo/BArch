#!/usr/bin/env bash
# Checks the repo before a save. sync.sh runs it first (BARCH_NO_CHECK=1 skips it); on its own:
#   ./scripts/check.sh
# - every shell script: bash -n and shellcheck (warnings and up)
# - every Lua file (the Hyprland config): luac -p
# - every JSON file: jq
# - the user units in systemd/: systemd-analyze --user verify
# - every agent task in agent/tasks has its timer listed in packages/user-services.txt
# - the automation code (agent/events.py, agent/nas.py) compiles and its unit tests pass
# - the music pipeline (server/music): its Python compiles and its unit tests pass
# - hyprctl configerrors, when Hyprland is running
# Exit 1 when anything fails. QML is not checked here: Quickshell reloads on save and logs errors.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1
fail=0
problem() { warn "$*"; fail=1; }
# tracked and untracked files, minus the ignored ones (generated theme files, caches)
files() { git ls-files -co --exclude-standard -z -- "$@"; }

step "Shell scripts"
mapfile -t scripts < <(files | xargs -0 file --mime-type 2>/dev/null | awk -F': +' '$2 == "text/x-shellscript" {print $1}')
for s in "${scripts[@]}"; do bash -n "$s" || problem "syntax error: $s"; done
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "${scripts[@]}" || problem "shellcheck"
else
  warn "shellcheck not installed (pacman -S shellcheck): only bash -n"
fi
((fail)) || ok "${#scripts[@]} scripts"

step "Lua (Hyprland config)"
n=0
while IFS= read -r -d '' f; do
  luac -p "$f" || problem "lua: $f"
  n=$((n + 1))
done < <(files '*.lua')
ok "$n files"

step "JSON"
n=0
while IFS= read -r -d '' f; do
  jq -e . "$f" >/dev/null 2>&1 || problem "invalid json: $f"
  n=$((n + 1))
done < <(files '*.json')
ok "$n files"

step "systemd user units"
mapfile -t units < <(files 'systemd/.config/systemd/user/*.service' 'systemd/.config/systemd/user/*.timer' | tr '\0' '\n')
if ((${#units[@]})); then
  systemd-analyze --user verify "${units[@]}" || problem "systemd-analyze verify"
  ok "${#units[@]} units"
fi

step "Agent tasks"
for t in agent/tasks/*.md; do
  name=$(basename "$t" .md)
  grep -qx "barch-agent@$name.timer" packages/user-services.txt || problem "agent task $name has no timer in packages/user-services.txt"
done
ok "timers listed"

step "Automation (agent/events.py, agent/nas.py)"
python3 -m py_compile agent/events.py agent/nas.py 2>/dev/null || problem "automation: events.py or nas.py does not compile"
python3 -m unittest discover -s agent/tests -q >/dev/null 2>&1 || problem "automation: unit tests fail (python3 -m unittest discover -s agent/tests)"
find agent -name __pycache__ -prune -exec rm -rf {} +
((fail)) || ok "compiles, tests pass"

step "Music pipeline (server/music)"
if [ -d server/music ]; then
  python3 -m compileall -q server/music/barch_music >/dev/null || problem "music pipeline: python does not compile"
  python3 -m unittest discover -s server/music/tests -q >/dev/null 2>&1 || problem "music pipeline: unit tests fail (python3 -m unittest discover -s server/music/tests)"
  find server/music -name __pycache__ -prune -exec rm -rf {} +
  ((fail)) || ok "compiles, tests pass"
fi

step "Book templates (server/books)"
python3 -m py_compile quickshell/.config/quickshell/books/books.py 2>/dev/null || problem "books: books.py does not compile"
for f in server/books/templates/*.xml; do
  [ -e "$f" ] || continue
  python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$f" 2>/dev/null || problem "books: $f is not valid XML"
done

step "Video pipeline (server/video)"
if [ -d server/video ]; then
  python3 -m compileall -q server/video/barch_video server/video/audit.py >/dev/null || problem "video pipeline: python does not compile"
  python3 -m unittest discover -s server/video/tests -q >/dev/null 2>&1 || problem "video pipeline: unit tests fail (python3 -m unittest discover -s server/video/tests)"
  find server/video -name __pycache__ -prune -exec rm -rf {} +
  ((fail)) || ok "compiles, tests pass"
fi

step "Torrent statistics (server/torrents)"
if [ -d server/torrents ]; then
  python3 -m compileall -q server/torrents/barch_torrents >/dev/null || problem "torrent statistics: python does not compile"
  python3 -m unittest discover -s server/torrents/tests -q >/dev/null 2>&1 || problem "torrent statistics: unit tests fail (python3 -m unittest discover -s server/torrents/tests)"
  find server/torrents -name __pycache__ -prune -exec rm -rf {} +
  ((fail)) || ok "compiles, tests pass"
fi

if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
  step "Hyprland"
  errs=$(hyprctl configerrors 2>/dev/null)
  if [[ -n $errs && $errs != "No errors" ]]; then problem "hyprctl configerrors: $errs"; else ok "no config errors"; fi
fi

((fail)) && die "fix the problems above (BARCH_NO_CHECK=1 ./scripts/sync.sh skips the check)"
ok "all checks passed"
