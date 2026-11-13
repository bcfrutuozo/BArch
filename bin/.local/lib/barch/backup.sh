# shellcheck shell=bash
# barch: backup: restic to the NAS (backup/include.txt).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

BACKUP_REPO_DEFAULT=/mnt/nasfrutuozo/organization/desktops/bcfrutuozo/restic
BACKUP_CONF=${XDG_CONFIG_HOME:-$HOME/.config}/barch/backup.conf      # optional: BACKUP_REPO=<path or restic URL>
BACKUP_PASS=${XDG_CONFIG_HOME:-$HOME/.config}/barch/backup/password  # never in the repo
BACKUP_STATE=$STATE/backup                                           # last.json, last.err, vm/*.xml

backup_env() {
  # shellcheck source=/dev/null
  [[ -r $BACKUP_CONF ]] && source "$BACKUP_CONF"
  export RESTIC_REPOSITORY=${BACKUP_REPO:-$BACKUP_REPO_DEFAULT}
  export RESTIC_PASSWORD_FILE=$BACKUP_PASS
  export RESTIC_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/restic
  mkdir -p "$BACKUP_STATE"
}
# the repository is a path on the NAS: it has to be a mounted network share, not an empty mount point
backup_mounted() {
  [[ $RESTIC_REPOSITORY == /* ]] || return 0
  findmnt -T "$(dirname "$RESTIC_REPOSITORY")" -t cifs,nfs,nfs4 >/dev/null 2>&1
}
backup_state() {   # backup_state <ok: true|false> <error> [summary json]
  jq -n --argjson ok "$1" --arg error "$2" --argjson at "$(date +%s)" --argjson summary "${3:-null}"     --arg repo "$RESTIC_REPOSITORY" '{at: $at, ok: $ok, error: $error, repo: $repo, summary: $summary}'     > "$BACKUP_STATE/last.json.tmp" && mv "$BACKUP_STATE/last.json.tmp" "$BACKUP_STATE/last.json"
}
backup_fail() { backup_state false "$1"; logger -t barch-backup -- "failed: $1"; die 1 "$1"; }
# backup_check <read-data subset>: restic check, structure plus that part of the data read back and
# hashed (a backup never read is not known to be good). Result in check.json for status and the
# health widget; a failure fails the run (so the service's OnFailure reaches `barch failure`).
backup_check() {
  local subset=$1 start err rc=0
  start=$(date +%s)
  err=$(restic check --with-cache --read-data-subset="$subset" 2>&1 >/dev/null) || rc=$?
  if ((rc)); then
    err=$(grep -vE '^(load indexes|check all packs|check snapshots|\[.*\]|$)' <<<"$err" | head -3 | paste -sd ' ' | cut -c1-300)
  else
    err=""
  fi
  jq -n --argjson ok "$([[ $rc == 0 ]] && echo true || echo false)" --arg error "$err" --arg subset "$subset" \
     --argjson at "$(date +%s)" --argjson took "$(( $(date +%s) - start ))" \
     '{at: $at, ok: $ok, error: $error, subset: $subset, took: $took}' > "$BACKUP_STATE/check.json.tmp" \
    && mv "$BACKUP_STATE/check.json.tmp" "$BACKUP_STATE/check.json"
  if ((rc)); then
    logger -t barch-backup -- "check failed ($subset): $err"
    return 1
  fi
  logger -t barch-backup -- "check ok ($subset of the data read, $(( $(date +%s) - start )) s)"
}

cmd_backup() {
  local sub=${1:-status}
  (($#)) && shift
  case $sub in
    init)
      need restic; backup_env
      [[ -s $BACKUP_PASS ]] && die 1 "already initialised: $BACKUP_PASS exists (repository: $RESTIC_REPOSITORY)"
      backup_mounted || die 1 "the NAS share for $RESTIC_REPOSITORY is not mounted"
      install -d -m 700 "$(dirname "$BACKUP_PASS")"
      (umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n' > "$BACKUP_PASS")
      restic init --quiet || { rm -f "$BACKUP_PASS"; die 1 "restic init failed"; }
      echo "Repository: $RESTIC_REPOSITORY"
      echo "Password file: $BACKUP_PASS"
      echo
      echo "Save this password in Bitwarden now. Without it the backup cannot be read:"
      echo
      echo "  $(cat "$BACKUP_PASS")"
      echo
      echo "Next: barch backup run; the timer: systemctl --user enable --now barch-backup.timer"
      ;;
    run)
      need restic; backup_env
      [[ -s $BACKUP_PASS ]] || backup_fail "not initialised: run 'barch backup init'"
      backup_mounted || backup_fail "the NAS share for $RESTIC_REPOSITORY is not mounted"
      # the VM definitions (the disk images are rebuilt; the XML is what took work)
      mkdir -p "$BACKUP_STATE/vm"
      while IFS= read -r vm; do
        [[ -n $vm ]] && virsh --connect qemu:///system dumpxml --inactive "$vm" > "$BACKUP_STATE/vm/${vm// /_}.xml" 2>/dev/null
      done < <(virsh --connect qemu:///system list --all --name 2>/dev/null)
      # include list → absolute paths that exist
      local files start summary rc
      files=$(mktemp)
      while IFS= read -r p; do
        [[ $p == /* ]] || p="$HOME/$p"
        [[ -e $p ]] && echo "$p"
      done < <(grep -vE '^\s*(#|$)' "$REPO/backup/include.txt") > "$files"
      [[ -s $files ]] || backup_fail "nothing to back up: backup/include.txt matched no existing path"
      start=$(date +%s)
      summary=$(restic backup --files-from "$files" --exclude-file "$REPO/backup/exclude.txt" --exclude-caches \
                  --tag auto --json 2>"$BACKUP_STATE/last.err" | jq -c 'select(.message_type == "summary")' | tail -1)
      rc=${PIPESTATUS[0]}; rm -f "$files"
      # 3 = some files could not be read (a socket, a file that vanished): the snapshot was still made
      [[ $rc == 0 || $rc == 3 ]] || backup_fail "restic backup failed (exit $rc): $(grep -v '^$' "$BACKUP_STATE/last.err" | tail -1)"
      if [[ ${1:-} == --prune || $(date +%u) == 7 ]]; then
        # prune needs an exclusive lock, and a lock left by an interrupted read (the Backup Browser's ls/stats,
        # a killed restic) blocks it forever; unlock only removes stale ones (dead PID here or older than 30 min)
        restic unlock --quiet 2>>"$BACKUP_STATE/last.err"
        local mark; mark=$(wc -l < "$BACKUP_STATE/last.err")
        restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune --quiet 2>>"$BACKUP_STATE/last.err" \
          || backup_fail "restic forget/prune failed: $(tail -n +"$((mark + 1))" "$BACKUP_STATE/last.err" | grep -v '^$' | head -2 | paste -sd ' ')"
      fi
      backup_state true "" "${summary:-null}"
      if [[ ${1:-} == --prune || $(date +%u) == 7 ]]; then
        # the snapshot is in (last.json says ok); now a tenth of the data is read back, a different
        # tenth each week (ISO week mod 10), so every pack is verified within ten weeks
        backup_check "$(( $(date +%-V) % 10 + 1 ))/10" || die 1 "backup ok, but restic check failed: $(jq -r .error "$BACKUP_STATE/check.json")"
      fi
      logger -t barch-backup -- "ok: $(jq -r '"\(.files_new + .files_changed) files changed, \(.data_added) bytes added, snapshot \(.snapshot_id[0:8])"' <<<"${summary:-{}}" 2>/dev/null)"
      show "$(jq -c --argjson took "$(( $(date +%s) - start ))" '. + {took: $took}' "$BACKUP_STATE/last.json")" \
        '"backup ok: \(.summary.files_new + .summary.files_changed) files changed, \(.summary.data_added / 1048576 | floor) MB added, \(.summary.total_files_processed) files in \(.took) s, snapshot \(.summary.snapshot_id[0:8])"'
      ;;
    status)
      backup_env
      local last next check
      last=$(cat "$BACKUP_STATE/last.json" 2>/dev/null || echo '{"at":0,"ok":false,"error":"","summary":null}')
      check=$(cat "$BACKUP_STATE/check.json" 2>/dev/null || echo null)
      next=$(systemctl --user show barch-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null)
      show "$(jq -c --arg next "${next:-}" --argjson configured "$([[ -s $BACKUP_PASS ]] && echo true || echo false)" \
              --arg repo "$RESTIC_REPOSITORY" --argjson check "$check" '. + {next: $next, configured: $configured, repo: $repo, check: $check}' <<<"$last")" '
        if .configured | not then "backup: not initialised (barch backup init); repository would be \(.repo)"
        elif .at == 0 then "backup: never ran (barch backup run); repository \(.repo)"
        else "backup: " + (if .ok then "ok" else "FAILED: \(.error)" end)
          + " · last \(.at | strflocaltime("%Y-%m-%d %H:%M"))"
          + (if .summary then " · \(.summary.total_files_processed) files, \(.summary.data_added / 1048576 | floor) MB added, snapshot \(.summary.snapshot_id[0:8])" else "" end)
          + "\n  repository \(.repo)"
          + (if .check then "\n  check: " + (if .check.ok then "ok" else "FAILED: \(.check.error)" end)
               + " · \(.check.at | strflocaltime("%Y-%m-%d %H:%M")) · \(.check.subset) of the data read in \(.check.took) s"
             else "\n  check: never ran (barch backup check; the Sunday run does it)" end)
          + (if .next != "" then "\n  next run \(.next)" else "\n  timer not enabled (systemctl --user enable --now barch-backup.timer)" end)
        end'
      ;;
    check)
      need restic; backup_env
      [[ -s $BACKUP_PASS ]] || die 1 "not initialised: run 'barch backup init'"
      backup_mounted || die 1 "the NAS share for $RESTIC_REPOSITORY is not mounted"
      local subset=10%
      case ${1:-} in
        --full) subset=100% ;;
        --read-data) [[ -n ${2:-} ]] || usage_error "backup check --read-data <n/t|x%|size>"; subset=$2 ;;
        "") ;;
        *) usage_error "backup check [--full|--read-data <subset>]" ;;
      esac
      echo "checking $RESTIC_REPOSITORY ($subset of the data read back)…" >&2
      backup_check "$subset" || die 1 "restic check failed: $(jq -r .error "$BACKUP_STATE/check.json")"
      show "$(cat "$BACKUP_STATE/check.json")" '"check ok: \(.subset) of the data read and verified in \(.took) s"'
      ;;
    list)
      need restic; backup_env
      [[ -s $BACKUP_PASS ]] || die 1 "not initialised: run 'barch backup init'"
      restic snapshots --compact
      ;;
    restore)
      need restic; backup_env
      [[ -s $BACKUP_PASS ]] || die 1 "not initialised: run 'barch backup init'"
      local snap=latest target="" paths=() a
      [[ ${1:-} =~ ^([0-9a-f]{8,}|latest)$ ]] && { snap=$1; shift; }
      while (($#)); do
        a=$1; shift
        case $a in
          --target) target=${1:-}; shift ;;
          *) paths+=("$a") ;;
        esac
      done
      ((${#paths[@]})) || usage_error "backup restore [SNAPSHOT] <path>... [--target DIR]"
      [[ -n $target ]] || target="$HOME/Restore/$snap-$(date +%Y%m%d-%H%M)"
      local inc=()
      for a in "${paths[@]}"; do [[ $a == /* ]] || a="$HOME/$a"; inc+=(--include "$a"); done
      restic restore "$snap" --target "$target" "${inc[@]}" && echo "restored into $target (paths keep their full names below it)"
      ;;
    browse) app_open backup BARCH_BACKUP_PAGE "${1:-}" ;;
    *) usage_error "backup init|run [--prune]|check [--full|--read-data <subset>]|status|list|restore [SNAPSHOT] <path>... [--target DIR]|browse [<page>]" ;;
  esac
}
