# shellcheck shell=bash
# barch: voice: the voice control daemon (quickshell/voice/voice.py).
# Sourced by bin/.local/bin/barch, which defines the globals ($PROG, $JSON, $REPO, $STATE, $BARCH).

# voice: the daemon is voice.py (quickshell/voice); on/off/toggle go through systemd, pause/
# resume/say/test/reload through its socket, match runs offline, status merges both.
cmd_voice() {
  local py=$REPO/quickshell/.config/quickshell/voice/voice.py unit=barch-voice.service sub=${1:-status}
  (($#)) && shift
  need python3
  case $sub in
    on) systemctl --user start "$unit" || die 1 "could not start $unit"; cmd_voice status ;;
    off) systemctl --user stop "$unit" || die 1 "could not stop $unit"; cmd_voice status ;;
    toggle)
      if systemctl --user is-active --quiet "$unit"; then cmd_voice off; else cmd_voice on; fi ;;
    status)
      local active out
      active=$(systemctl --user is-active "$unit" 2>/dev/null)
      out=$(python3 -I "$py" status 2>/dev/null) || out='{"ok":false}'
      out=$(jq -c --arg a "$active" '. + {service: $a}' <<<"$out")
      show "$out" 'if .service != "active" then "voice: off (service \(.service))"
                   else "voice: \(.state)" + (if .paused then " (paused)" else "" end)
                     + (if .whisper then "" else " — whisper.cpp or model missing" end)
                     + (if .tts then "" else " — piper missing (no spoken answers)" end)
                     + (if .heard != "" then "\nheard: \(.heard)" else "" end)
                     + (if .said != "" then "\nsaid: \(.said)" else "" end)
                     + (if .error != "" then "\nerror: \(.error)" else "" end) end'
      [[ $active == active ]] ;;
    lang | language)
      local out
      if [[ ${1:-} == list ]]; then
        out=$(python3 -I "$py" languages)
        show "$out" '.languages[] | "\(.code)\t\(.name)\(if .native != .name then " · \(.native)" else "" end)\(if .commands then "  (commands)" elif .code == "auto" then "" elif .voice == null then "  (no voice: notifications)" elif .downloaded then "" else "  (voice downloaded when picked)" end)"'
        return
      fi
      out=$(python3 -I "$py" language ${1:+"$1"}) || {
        [[ $? == 3 ]] && die 3 "barch-voice is not running"
        die 1 "$(jq -r '.error // "failed"' <<<"$out" 2>/dev/null)"
      }
      show "$out" '"voice: listening in \(.language_name)\(if .language_native != "" and .language_native != .language_name then " (\(.language_native))" else "" end)" + (if .downloading != "" then " — downloading the voice \(.downloading)" elif .voice_ready then "" else " — no voice: answers go to notifications" end)' ;;
    pause | resume | reload)
      local out
      out=$(python3 -I "$py" "$sub") || die 1 "$(jq -r '.error // "failed"' <<<"$out" 2>/dev/null)"
      show "$out" '"voice: \(if .paused == true then "paused" elif .paused == false then "listening" else "reloaded (\(.intents) commands)" end)"' ;;
    say)
      [[ -n ${1:-} ]] || usage_error "voice say <text>"
      local out
      out=$(python3 -I "$py" say "$*") || die 1 "$(jq -r '.error // "failed"' <<<"$out" 2>/dev/null)"
      show "$out" '"said: \(.said)"' ;;
    test)
      [[ -n ${1:-} ]] || usage_error "voice test <text>"
      local out rc=0
      out=$(python3 -I "$py" run "$*") || rc=$?
      ((rc == 3)) && die 3 "$(jq -r .error <<<"$out")"
      show "$out" 'if .locked then "ignored: the session is locked" else "\(if .matched then .intent else "no command (Claude)" end)" + (if .say != "" then ": \(.say)" else "" end) end'
      return "$rc" ;;
    match)
      [[ -n ${1:-} ]] || usage_error "voice match <text>"
      local out rc=0
      out=$(python3 -I "$py" match "$*" 2>/dev/null) || rc=$?
      show "$out" 'if .matched then "\(.intent) (\(.kind))" + (if .run then ": \(.run | join(" "))" elif .dispatch then ": hyprctl dispatch \(.dispatch)" elif .app then ": app \(.app)" elif .project then ": \(.with // "terminal") in \(.project)" elif .palette then ": palette \(.palette)" elif .scene then ": scene \(.scene)" elif .region then ": \(.what) region \(.region)" elif .window then ": \(.action) window \(.window)" elif .repeats then ": \(.how) → \(.repeats)" else "" end) + (if .say != "" then "  → \"\(.say)\"" else "" end) else "no command: " + (if .intent == "claude" then "would ask Claude" else "would say it did not understand" end) + " (\(.normalized))" end'
      return "$rc" ;;
    wake)
      [[ -n ${1:-} ]] || usage_error "voice wake <text>"
      local out rc=0
      out=$(python3 -I "$py" wake "$*" 2>/dev/null) || rc=$?
      show "$out" 'if .wake then "wakes" + (if .rest != "" then ", command: \(.rest)" else " (alone: chime, waits for the sentence)" end) else "does not wake (score \(.score) against barch)" end'
      return "$rc" ;;
    misses)
      local f=$STATE/voice/wake-misses.log
      [[ -s $f ]] || { echo "nothing came close to the wake word yet ($f)"; return 0; }
      tail -n "${1:-30}" "$f" ;;
    log) journalctl --user -u "$unit" -n "${1:-60}" --no-pager -o short ;;
    setup) bash "$REPO/quickshell/.config/quickshell/voice/setup.sh" "$@" ;;
    *) usage_error "voice on|off|toggle|status|pause|resume|say|match|wake|misses|test|reload|log|setup" ;;
  esac
}
