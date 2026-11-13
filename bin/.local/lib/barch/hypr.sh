# shellcheck shell=bash
# barch: hypr: Hyprland Settings (settings.json applied by conf/settings.lua).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# The settings app keeps its changes in ~/.config/hypr/settings.json (conf/settings.lua applies
# them over the hand-written files); these commands edit that file the same way and apply through
# `hyprctl eval`, so they work with or without the app open (it watches the file).
HYPR_SETTINGS=$HOME/.config/hypr/settings.json
hypr_settings() { [[ -s $HYPR_SETTINGS ]] && cat "$HYPR_SETTINGS" || echo '{}'; }
hypr_write() { local tmp; tmp=$(mktemp "$HYPR_SETTINGS.XXXXXX") && jq . >"$tmp" && mv "$tmp" "$HYPR_SETTINGS"; }
hypr_desc() { hyprctl -j descriptions 2>/dev/null | jq -e --arg n "$1" '.[] | select(.name == $n)' 2>/dev/null; }
hypr_report() { hyprctl eval 'BArch.settings.report()' 2>&1 | sed 's/^error: //'; }

hypr_edit() {
  local cfg=$HOME/.config/quickshell/hypr
  if qs -p "$cfg" ipc show >/dev/null 2>&1; then
    qs -p "$cfg" ipc call app open "${1:-}" >/dev/null
    return
  fi
  BARCH_HYPR_PAGE=${1:-} setsid -f qs -p "$cfg" >/dev/null 2>&1
}

cmd_hypr() {
  command -v hyprctl >/dev/null || die 3 "hyprctl not found"
  case "${1:-edit}" in
    edit) hypr_edit "${2:-}" ;;
    get)
      [[ -n ${2:-} ]] || usage_error "hypr get <option>"
      local d; d=$(hypr_desc "$2") || die 1 "unknown option: $2 (hyprctl descriptions)"
      local out; out=$(jq -n --argjson d "$d" --argjson s "$(hypr_settings)" \
        '{ok: true, name: $d.name, current: $d.current, default: $d.default, saved: ($s.options[$d.name] // null), description: $d.description}')
      show "$out" '"\(.name) = \(.current | tojson)  (default \(.default | tojson)\(if .saved != null then ", saved by the app: " + (.saved | tojson) else "" end))\n  \(.description)"' ;;
    set)
      [[ -n ${2:-} && -n ${3:-} ]] || usage_error "hypr set <option> <value>"
      hypr_desc "$2" >/dev/null || die 1 "unknown option: $2 (hyprctl descriptions)"
      local v; v=$(jq -c . <<<"$3" 2>/dev/null) || v=$(jq -Rc . <<<"$3")    # not JSON: a string
      hypr_settings | jq --arg n "$2" --argjson v "$v" '.options[$n] = $v' | hypr_write || die 1 "cannot write $HYPR_SETTINGS"
      hyprctl eval "BArch.settings.apply(\"options\", \"$2\")" >/dev/null 2>&1
      local rep; rep=$(hypr_report)
      if [[ $rep == *" 0 error(s)"* ]]; then show "$(jq -n --arg n "$2" --argjson v "$v" '{ok: true, name: $n, value: $v}')" '"\(.name) = \(.value | tojson)"'
      else die 1 "applied with errors: $rep"; fi ;;
    reset)
      [[ -n ${2:-} ]] || usage_error "hypr reset <option>|all"
      if [[ $2 == all ]]; then hypr_settings | jq 'del(.options)' | hypr_write
      else hypr_settings | jq --arg n "$2" 'del(.options[$n]) | if .options == {} then del(.options) else . end' | hypr_write; fi
      hyprctl reload >/dev/null 2>&1
      show "$(jq -n --arg n "$2" '{ok: true, reset: $n}')" '"\(.reset): back to the files (reloaded)"' ;;
    list) show "$(hypr_settings)" '(.options // {}) | to_entries[] | "\(.key) = \(.value | tojson)"' ;;
    status)
      local n; n=$(hyprctl -j descriptions | jq 'length')
      local out; out=$(jq -n --arg v "$(hyprctl -j version | jq -r '.tag // .version')" --argjson n "$n" --argjson s "$(hypr_settings)" \
        --arg errors "$(hyprctl configerrors 2>/dev/null)" --arg report "$(hypr_report)" \
        '{ok: true, version: $v, options: $n, saved: (($s.options // {}) | length), monitors: (($s.monitors // {}) | keys), binds: (($s.binds // []) | length), configErrors: $errors, report: $report}')
      show "$out" '"Hyprland \(.version): \(.options) options, \(.saved) saved by the app, \(.binds) binds added; \(.report)" + (if .configErrors != "" then "\nconfig errors:\n" + .configErrors else "" end)' ;;
    *) usage_error "hypr [edit] [<page>] | get <option> | set <option> <value> | reset <option>|all | list | status" ;;
  esac
}
