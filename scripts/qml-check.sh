#!/usr/bin/env bash
# QML checks for quickshell/ (check.sh runs it; on its own: ./scripts/qml-check.sh [-v]).
# - every qmldir lists each component of its folder, and lists nothing that is missing (a component
#   left out of an app's qmldir only fails when the app opens)
# - no broken symlink (the shared controls are linked from ui/ into each app)
# - every file outside lock/ under `pragma ComponentBehavior: Bound`, and no delegate reading
#   modelData/index without `required property` (scripts/qml-delegates.py)
# - Quickshell.* only where `import Quickshell` is
# - qmllint (Qt 6) on every file, failing only on what it gets right here: syntax errors, files it
#   cannot open, a type it cannot find (an inline component of another file), unqualified access outside lock/ (an id or a required property is always at
#   hand), duplicate bindings, a property or function shadowing one of the base type (state,
#   children, palette...) and ids shadowing a property. The rest of its output is mostly about the
#   Quickshell types it cannot see (missing-property, PanelWindow not creatable, singletons
#   declared without a version), so it is not checked; -v prints all of it.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../quickshell/.config/quickshell" || exit 1
verbose=0
[[ ${1:-} == -v ]] && verbose=1
fail=0
bad() { echo "  $*"; fail=1; }

for q in */qmldir; do
  d=${q%/qmldir}
  for f in "$d"/*.qml; do
    [[ -e $f ]] || continue
    n=$(basename "$f" .qml)
    [[ $n == shell ]] && continue
    grep -qE "^(singleton +)?$n( |$)" "$q" || bad "$f: not listed in $q"
  done
  while read -r f; do
    [[ -e $d/$f ]] || bad "$q lists $f, which does not exist"
  done < <(awk '$NF ~ /\.(qml|js)$/ {print $NF}' "$q")
done

while IFS= read -r l; do bad "broken symlink: $l"; done < <(find . -xtype l)

# every file outside lock/ is `pragma ComponentBehavior: Bound` (ids of outer components reachable
# from delegates, model data only through `required property`); lock/ is left as it is: the
# resident lock process is never reloaded by hand (see CLAUDE.md)
while IFS= read -r f; do
  grep -q '^pragma ComponentBehavior: Bound' "$f" || bad "$f: no 'pragma ComponentBehavior: Bound'"
done < <(find . -name '*.qml' -not -type l -not -path './lock/*')
# under Bound a delegate reading modelData/index without declaring them throws when it is created
while IFS= read -r l; do bad "$l"; done < <(python3 -I "$here/qml-delegates.py" .)

# Quickshell.execDetached/env/... without `import Quickshell` is a ReferenceError when it runs, and
# only then (a button that does nothing): the backup and mixer apps had three until 2026-11-13
while IFS= read -r f; do
  grep -qE '^import Quickshell( |$)' "$f" || bad "$f: uses Quickshell.* without 'import Quickshell'"
done < <(grep -rlE '(^|[^.A-Za-z])Quickshell\.[a-z]' --include='*.qml' . | while read -r f; do [[ -L $f ]] || echo "$f"; done)

QMLLINT=/usr/lib/qt6/bin/qmllint
if [[ ! -x $QMLLINT ]]; then
  echo "  qmllint (Qt 6) not installed (pacman -S qt6-declarative): only the qmldir checks"
  exit "$fail"
fi
out=$(mktemp)
trap 'rm -f "$out"' EXIT
mapfile -t files < <(find . -name '*.qml' -not -xtype l | sort)
"$QMLLINT" --json "$out" "${files[@]}" >/dev/null 2>&1
if ((verbose)); then
  jq -r '.files[] | .filename as $f | .warnings[] | "\(.type) \(.id // "-") \($f):\(.line // 0): \(.message)"' "$out"
fi
while IFS= read -r l; do bad "$l"; done < <(jq -r '
  .files[] | (.filename | sub(".*/quickshell/"; "")) as $f | .warnings[]
  | select(.type == "critical"
           or (.id == "unqualified" and (.message | startswith("Unqualified access")) and ($f | startswith("lock/") | not))
           or (.id | IN("syntax", "duplicate-property-binding", "property-override", "id-shadows-member", "alias-cycle", "duplicate-inline-component"))
           or (.message | test("does not exist|Failed to open file|was not found. Did you add all imports")))
  | select(.message | test("^Note: ") | not)
  | "\($f):\(.line // 0): \(.message) [\(.id // .type)]"' "$out")
exit "$fail"
