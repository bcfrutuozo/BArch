#!/usr/bin/env bash
# Checks the repo before a save. sync.sh runs it first (BARCH_NO_CHECK=1 skips it); on its own:
#   ./scripts/check.sh
# - every shell script: bash -n and shellcheck (warnings and up)
# - every Lua file (the Hyprland config): luac -p
# - every JSON file: jq
# - the user units in systemd/: systemd-analyze --user verify
# - every agent task in agent/tasks has its timer listed in packages/user-services.txt
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

if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
  step "Hyprland"
  errs=$(hyprctl configerrors 2>/dev/null)
  if [[ -n $errs && $errs != "No errors" ]]; then problem "hyprctl configerrors: $errs"; else ok "no config errors"; fi
fi

((fail)) && die "fix the problems above (BARCH_NO_CHECK=1 ./scripts/sync.sh skips the check)"
ok "all checks passed"
