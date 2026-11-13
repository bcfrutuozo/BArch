# shellcheck shell=bash
# barch: desktop commands through the bar: notify, theme, wallpaper, HDR/SDR, monitor, caffeine, night light, DND, VPN, Anonymous Mode, Claude usage, inbox, health.
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

onoff_text='if . then "on" else "off" end'

cmd_notify() {
  local title="" body="" urgency=normal app=barch actions='[]'
  local -a pos=()
  while (($#)); do
    case $1 in
      --critical) urgency=critical ;;
      --low) urgency=low ;;
      --app) [[ $# -ge 2 ]] || usage_error "--app needs a name"; app=$2; shift ;;
      --action)
        [[ $# -ge 2 && $2 == ?*=?* ]] || usage_error "--action needs LABEL=COMMAND"
        actions=$(jq -c --arg t "${2%%=*}" --arg c "${2#*=}" '. + [{text: $t, cmd: $c}]' <<<"$actions")
        shift ;;
      --) shift; pos+=("$@"); break ;;
      -*) usage_error "notify: unknown option '$1'" ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  ((${#pos[@]} >= 1 && ${#pos[@]} <= 2)) || usage_error "notify needs <title> [body]"
  title=${pos[0]}
  body=${pos[1]:-}
  [[ -n $title ]] || usage_error "notify: empty title"
  ipc notifs post "$title" "$body" "$urgency" "$app" "$(actions_arg "$actions")"
  show "$OUT" \
    'if .dnd then "sent (Do Not Disturb is on: history only)" else "sent" end'
}

cmd_theme() {
  local text='"appearance: \(.appearance) (now \(.mode), palette \(.flavor); dark \(.dark), light \(.light))"'
  case ${1:-} in
    dark | light)
      if [[ -n ${2:-} ]]; then ipc theme flavor "$1" "$2"; ipc theme status
      else ipc theme mode "$1"; ipc theme status; fi ;;
    auto) ipc theme mode "$1"; ipc theme status ;;
    status) ipc theme status ;;
    palettes)
      ipc theme palettes
      show "$OUT" '(["dark:"] + [.dark[] | "  \(.id)\t\(.label)" + (if .active then "  (pinned)" else "" end)]
                   + ["light:"] + [.light[] | "  \(.id)\t\(.label)" + (if .active then "  (pinned)" else "" end)]) | .[]'
      return ;;
    edit) theme_edit "${2:-}"; return ;;
    from-image) shift; theme_from_image "$@"; return ;;
    delete)
      [[ -n ${2:-} ]] || usage_error "theme delete <palette>"
      ipc theme remove "$2"; show "$OUT" '"removed \(.id)"'; return ;;
    export)
      [[ -n ${2:-} ]] || usage_error "theme export <palette>"
      ipc theme get "$2"; show "$OUT" '.palette'; return ;;
    *) usage_error "theme light|dark|auto|status | theme dark|light <palette> | theme palettes | theme edit [<palette>] | theme from-image <image> | theme delete|export <palette>" ;;
  esac
  show "$OUT" "$text"
}

# theme edit [id]: the palette editor, its own Quickshell config (quickshell/palette). One window:
# a running editor gets the request over its own IPC.
theme_edit() {
  local cfg=$HOME/.config/quickshell/palette
  need qs
  if qs -p "$cfg" ipc show >/dev/null 2>&1; then
    if [[ -n ${1:-} ]]; then qs -p "$cfg" ipc call editor open "$1" >/dev/null; fi
    return 0
  fi
  BARCH_PALETTE_EDIT=${1:-} setsid -f qs -p "$cfg" >/dev/null 2>&1
}

# theme from-image <image> [--id ID] [--label NAME] [--dark|--light]: tools/palette_from_image.py
# writes a draft (~/.local/state/quickshell/palette-draft.json) that the editor opens unsaved.
theme_from_image() {
  local img=${1:-}
  [[ -n $img ]] || usage_error "theme from-image <image> [--id ID] [--label NAME] [--dark|--light]"
  shift
  [[ -r $img ]] || die 2 "cannot read $img"
  need python3
  need qs
  local draft=${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/palette-draft.json cfg=$HOME/.config/quickshell/palette
  mkdir -p "$(dirname "$draft")"
  python3 -I "$REPO/tools/palette_from_image.py" "$img" "$@" >"$draft" || die 1 "the generator failed (python3 + Pillow)"
  if ((JSON)); then cat "$draft"; else jq -r '"\(.id) (\(if .dark then "dark" else "light" end)): base \(.base), text \(.text), accent \(.accent)  → editor"' "$draft"; fi
  if qs -p "$cfg" ipc show >/dev/null 2>&1; then
    qs -p "$cfg" ipc call editor draft "$draft" >/dev/null
  else
    BARCH_PALETTE_DRAFT=$draft setsid -f qs -p "$cfg" >/dev/null 2>&1
  fi
}

cmd_wallpaper() {
  local scene="" target=both
  for a in "$@"; do
    case $a in
      --lock) target=lock ;;
      --desktop) target=desktop ;;
      -*) usage_error "wallpaper list|status|<scene> [--lock|--desktop]" ;;
      *) if [[ $scene == render ]]; then set -- render "$a"; elif [[ -n $scene ]]; then usage_error "one scene at a time"; else scene=$a; fi ;;
    esac
  done
  case $scene in
    list)
      ipc wallpaper list
      show "$OUT" '.scenes[] | "\(.id)\t\(.label)\t\(.description)"' ;;
    status | '')
      ipc wallpaper status
      show "$OUT" '"desktop: \(.desktop), lock screen: \(.lock), palette: \(.used)"
                   + (if .available then "" else " (no \(.palette) set yet)" end)
                   + (if .rendering != "" then ", rendering \(.rendering)" else "" end)' ;;
    render)
      ipc wallpaper render "${2:-}"
      show "$OUT" '"rendering: \(.rendering) (palettes ready: \(.palettes | join(", ")))"' ;;
    *)
      ipc wallpaper set "$scene" "$target"
      show "$OUT" '"desktop: \(.desktop), lock screen: \(.lock)"' ;;
  esac
}

control_text_hdr='"hdr: \(.hdr | '"$onoff_text"')" + (if .hdr then " (SDR white \(.sdrWhite) nits)" else "" end)'

cmd_hdr() { toggle control hdr "${1:-}" "$control_text_hdr"; }

cmd_sdr() {
  local text='"SDR white: \(.sdrWhite) nits (range \(.sdrMin)–\(.sdrMax))" + (if .hdr then "" else ", HDR is off" end)'
  case ${1:-} in
    status) ipc control status ;;
    '' | *[!0-9]*) usage_error "sdr <nits>|status" ;;
    *) ipc control sdr "$1" ;;
  esac
  show "$OUT" "$text"
}

cmd_monitor() {
  [[ ${1:-} == side ]] || usage_error "monitor side on|off|status"
  toggle control side "${2:-}" '"side monitor (\(.sideOutput)): \(.side | '"$onoff_text"')"'
}

cmd_caffeine() { toggle control caffeine "${1:-}" '"caffeine: \(.caffeine | '"$onoff_text"')"'; }

cmd_nightlight() {
  local text='if .hasHyprsunset | not then "night light: hyprsunset not installed"
              else "night light: \(.nightLight | '"$onoff_text"')" + (if .nightLight then " (\(.nightTemp) K)" else "" end) end'
  toggle control nightLight "${1:-}" "$text"
}

cmd_dnd() { toggle notifs dndSet "${1:-}" '"do not disturb: \(.dnd | '"$onoff_text"')"'; }

cmd_vpn() {
  local text='"vpn: \(.state)" + (if .name != "" then " (\(.name)\(if .ip != "" then ", " + .ip else "" end))" else "" end)
              + " · region: \(.preferred)" + (if .error != "" then " · error: \(.error)" else "" end)'
  case ${1:-status} in
    on | connect) ipc vpn up "${2:-}" ;;
    off | disconnect) ipc vpn down ;;
    toggle) ipc vpn toggle ;;
    status) ipc vpn status ;;
    regions)
      ipc vpn regions
      text='.preferred as $p | .regions[] | "\(if .id == $p then "* " else "  " end)\(.id)\t\(.name)\t\(.country)\t\(if .latency then "\(.latency * 1000 | floor) ms" else "" end)"' ;;
    region) [[ -n ${2:-} ]] || usage_error "vpn region <id>|auto"; ipc vpn region "$2" ;;
    *) usage_error "vpn on [region]|off|toggle|status|regions|region <id>|auto" ;;
  esac
  show "$OUT" "$text"
}

cmd_anon() {
  local text='"anonymous mode: \(.state)"
              + (if .vpn.name != "" then " (\(.vpn.name)\(if .vpn.ip != "" then ", " + .vpn.ip else "" end))" else "" end)
              + " · browser: \(.browser)"
              + " · kill switch: \(if .killswitch.armed then "armed (\(.killswitch.endpoint))" elif .killswitch.installed then "off" else "not installed" end)"
              + (if (.missing | length) > 0 then " · not covered: " + (.missing | join("; ")) else "" end)
              + (if .error != "" then " · error: \(.error)" else "" end)'
  case ${1:-status} in
    on) ipc anon on "${2:-}" ;;
    off) ipc anon off ;;
    toggle) ipc anon toggle ;;
    status) ipc anon status ;;
    *) usage_error "anon on [region]|off|toggle|status" ;;
  esac
  show "$OUT" "$text"
}

# claude [--refresh]: the bar's ClaudeUsage widget (quickshell/claude): the plan's limits as Claude Code's
# /usage shows them, plus the agents' spend from claude-cost.log
cmd_claude() {
  case ${1:-} in
    '') ;;
    --refresh)
      local before i
      ipc claude refresh
      before=$(jq -r '.checkedAt' <<<"$OUT")
      for ((i = 0; i < 40; i++)); do
        sleep 0.5
        ipc claude status
        [[ $(jq -r '.checkedAt' <<<"$OUT") != "$before" ]] && break
      done
      ((i < 40)) || die 1 "the usage read did not finish in 20 s"
      ;;
    *) usage_error "claude [--refresh]" ;;
  esac
  ipc claude status
  show "$OUT" '
    def left(s): if s == null then "" elif s < 3600 then " (resets in \(s / 60 | floor) min)"
      elif s < 129600 then " (resets in \(s / 3600 | floor) h \((s % 3600) / 60 | floor) min)"
      else " (resets \(now + s | strflocaltime("%a %H:%M")))" end;
    if .loaded | not then "Claude: not read yet (the bar reads ~8 s after start; use --refresh)"
    elif .ok | not then "Claude: " + (.error // "no answer") + (if .plan.label then " · plan \(.plan.label)" else "" end)
    else
      "Claude · \(.plan.label) (read \(.checkedAt / 1000 | floor | strflocaltime("%H:%M")))",
      (.limits[] | "  \(.label): \(.percent // "?") %" + left(.resets_in_s)
        + (if .allowance_percent_of_weekly then "  [\(.allowance_percent_of_weekly) % of the weekly allowance]" else "" end)),
      (if (.breakdown | length) > 0 then "  this week: " + (.breakdown | map("\(.name) \(.percent) %") | join(", ")) else empty end),
      "  agents here: US$ \(.agents.today_usd) today (\(.agents.runs_today) runs), US$ \(.agents.week_usd) this week"
        + (if (.agents.by_source_today | length) > 0 then ": " + (.agents.by_source_today | to_entries | sort_by(-.value) | map("\(.key) \(.value)") | join(", ")) else "" end)
    end'
}

cmd_inbox() {
  case ${1:-} in
    '') ;;
    --refresh)
      local before i
      ipc inbox refresh
      before=$(jq -r '.checkedAt' <<<"$OUT")
      for ((i = 0; i < 60; i++)); do          # every source is asked with a timeout (the NAS, the bar)
        sleep 0.5
        ipc inbox status
        [[ $(jq -r '.checkedAt' <<<"$OUT") != "$before" ]] && break
      done
      ((i < 60)) || die 1 "the inbox read did not finish in 30 s"
      ;;
    *) usage_error "inbox [--refresh]" ;;
  esac
  ipc inbox status
  show "$OUT" '
    if .loaded | not then "Inbox: not read yet (the bar reads it ~20 s after start; use --refresh)"
    else "Waiting for you: " + (if .total == 0 then "nothing" else "\(.total)" end)
      + (.items | map("\n  \(.count | tostring | . + " " * (5 - length))\(.label): \(.text)\n        \(.cmd | join(" "))") | join(""))
      + (if (.errors | length) > 0 then "\n  not reachable: " + (.errors | join(" · ")) else "" end)
    end'
}

cmd_health() {
  case ${1:-} in
    '') ;;
    --refresh)
      local before i
      ipc health refresh
      before=$(jq -r '.checkedAt' <<<"$OUT")
      for ((i = 0; i < 60; i++)); do          # the check takes a few seconds (du, journalctl)
        sleep 0.5
        ipc health status
        [[ $(jq -r '.checkedAt' <<<"$OUT") != "$before" ]] && break
      done
      ((i < 60)) || die 1 "the health check did not finish in 30 s"
      ;;
    *) usage_error "health [--refresh]" ;;
  esac
  ipc health status
  show "$OUT" '
    def list(xs): if (xs | length) == 0 then "none" else (xs | join(", ")) end;
    def day(ms): ms / 1000 | floor | strflocaltime("%Y-%m-%d");
    if .loaded | not then "System health: not checked yet (the bar checks ~45 s after start; use --refresh)"
    else
      "System health: " + (if .issues == 0 then "ok" else "\(.issues) issue(s)" end)
        + " (checked " + (.checkedAt / 1000 | floor | strflocaltime("%Y-%m-%d %H:%M")) + ")",
      "  .pacnew/.pacsave: \(.pacnew | length)",
      (.pacnew[] | "    \(.)"),
      "  failed services: system: \(list(.failed.system)); user: \(list(.failed.user))",
      "  TPM unlock: \(.tpm)" + (if .tpm == "failed" then "  → \(.reenroll)" else "" end),
      "  cleanup: " + (if .cleanupDue then "due" else "not due" end)
        + (if .lastCleanup > 0 then " (last \(day(.lastCleanup)))" else "" end)
        + "; \(.clean.orphans) orphans, cache \(.clean.cache), journal \(.clean.journal)",
      "  backup: " + (if .backup.configured | not then "not set up (barch backup init)"
        elif .backup.at == 0 then "never ran"
        else (if .backup.ok then "ok" else "FAILED" end) + " (last \(.backup.at | strflocaltime("%Y-%m-%d %H:%M")))"
          + (if .backupLate then " · overdue" else "" end) end)
    end'
}
