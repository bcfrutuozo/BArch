#!/usr/bin/env bash
# QML checks for quickshell/ (check.sh runs it; on its own: ./scripts/qml-check.sh [-v]).
# - every qmldir lists each component of its folder, and lists nothing that is missing (a component
#   left out of an app's qmldir only fails when the app opens)
# - no broken symlink (the shared controls are linked from ui/ into each app)
# - qmllint (Qt 6) on every file, failing only on what it gets right here: syntax errors, files it
#   cannot open, duplicate bindings, a property or function shadowing one of the base type (state,
#   children, palette...) and ids shadowing a property. The rest of its output is mostly about the
#   Quickshell types it cannot see (unqualified, missing-property, PanelWindow not creatable,
#   singletons declared without a version), so it is not checked; -v prints all of it.
set -uo pipefail
cd "$(dirname "$0")/../quickshell/.config/quickshell" || exit 1
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
           or (.id | IN("syntax", "duplicate-property-binding", "property-override", "id-shadows-member", "alias-cycle", "duplicate-inline-component"))
           or (.message | test("does not exist|Failed to open file")))
  | select(.message | test("^Note: ") | not)
  | "\($f):\(.line // 0): \(.message) [\(.id // .type)]"' "$out")
exit "$fail"
