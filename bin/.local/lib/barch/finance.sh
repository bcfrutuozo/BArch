# shellcheck shell=bash
# barch: finance: C6 Bank statements into Firefly III (finance/import.py).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

cmd_finance() {
  [[ ${1:-} == import ]] || usage_error "finance import [--dry-run] [--keep] [--yes] [--dir DIR] [--seed]"
  shift
  need python3
  exec python3 "$REPO/finance/import.py" "$@"
}
