#!/usr/bin/env bash
# barch-audit: repo facts → $2/context.md
# Usage: barch-audit.sh prepare <rundir>
[[ $1 == prepare ]] || exit 0
cd "$BARCH_REPO" || exit 1
section() { printf '\n## %s\n\n```\n' "$1"; shift; "$@" 2>&1; printf '```\n'; }

scripts() { git ls-files | while read -r f; do
  [[ $f == *.sh || $(head -c 40 "$f" 2>/dev/null) == '#!'*sh* ]] && echo "$f"; done; }

{
  echo "# BArch audit facts — $(date '+%Y-%m-%d')"
  section "Tracked files" git ls-files
  section "Last commits" git log -15 --format='%h %cs %s'
  section "Explicit packages installed but missing in packages/*.txt" bash -c \
    'comm -23 <(pacman -Qqe | sort) <(cat packages/pacman.txt packages/aur.txt packages/aur-ignore.txt 2>/dev/null | sed "s/#.*//" | tr -s " \t" "\n" | sort -u)'
  section "Packages listed but not installed" bash -c \
    'comm -13 <(pacman -Qq | sort) <(cat packages/pacman.txt packages/aur.txt 2>/dev/null | sed "s/#.*//" | tr -s " \t" "\n" | grep . | sort -u)'
  # shellcheck disable=SC2016  # $1 is for awk
  section "Enabled user units vs packages/user-services.txt" bash -c \
    'echo "enabled:"; systemctl --user list-unit-files --state=enabled --no-legend | awk "{print \$1}"; echo; echo "listed:"; cat packages/user-services.txt'
  section "shellcheck (errors and warnings)" bash -c "$(declare -f scripts); scripts | xargs shellcheck -S warning -f gcc"
} >"$2/context.md"
