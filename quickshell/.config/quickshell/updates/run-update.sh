#!/usr/bin/env bash
# Roda dentro do terminal aberto pelo UpdatesWidget.
# Uso: run-update.sh <all|kernel|news> <script-do-kernel> <kernel-pendente: 1|0>
# Antes do paru, mostra as notícias do Arch não lidas (archnews); o hook do pacman
# bloqueia a atualização enquanto houver alguma. Depois, a revisão do AUR (barch aur review):
# o agente lê o diff do PKGBUILD de cada atualização do AUR; se algo parecer suspeito (ou a
# revisão não rodar), pergunta antes de seguir.
# Depois do paru, atualiza o Claude Code (auto-update dele fica desligado via
# DISABLE_AUTOUPDATER no ~/.claude/settings.json).
mode="$1"
kernel_script="$2"
kernel_pending="$3"

bold=$'\e[1m'; blue=$'\e[34m'; green=$'\e[32m'; red=$'\e[31m'; reset=$'\e[0m'
step() { printf '\n%s%s==> %s%s\n\n' "$bold" "$blue" "$1" "$reset"; }

run_kernel() {
  if [[ -z "$kernel_script" ]]; then
    printf '%sKernel script not set (kernelScript property of UpdatesWidget).%s\n' "$red" "$reset"
    return 1
  fi
  if [[ ! -x "$kernel_script" ]]; then
    printf '%sKernel script not found or not executable: %s%s\n' "$red" "$kernel_script" "$reset"
    return 1
  fi
  step "Kernel: $kernel_script"
  "$kernel_script"
}

# aur_review: 0 = pode seguir; 1 = o usuário preferiu parar
aur_review() {
  command -v barch >/dev/null || return 0
  step "AUR review (PKGBUILD changes)"
  barch aur review
  case $? in
    0) return 0 ;;
    4) printf '\n%sSomething above needs a look before building.%s\n' "$red" "$reset" ;;
    *) printf '\n%sThe AUR review did not run (no network or no Claude?).%s\n' "$red" "$reset" ;;
  esac
  local answer
  read -rp "Continue with the update anyway? [y/N] " answer
  [[ $answer == [yYsS]* ]]
}

unread_news() {
  command -v archnews >/dev/null || return 1
  local n; n=$(archnews check 2>/dev/null | jq '.unread | length' 2>/dev/null)
  [[ "${n:-0}" -gt 0 ]]
}

status=0
if [[ "$mode" == "news" ]]; then
  archnews || status=$?
elif [[ "$mode" == "kernel" ]]; then
  if aur_review; then run_kernel || status=$?; else status=1; fi
else
  if unread_news; then
    step "Arch news (read before updating)"
    archnews
  fi
  aur_review || status=1
fi
if [[ "$mode" != "news" && "$mode" != "kernel" && $status -eq 0 ]]; then
  step "paru -Syu"
  paru -Syu || status=$?
  if [[ $status -eq 0 ]] && command -v claude >/dev/null; then
    step "Claude Code"
    claude update || printf '%sclaude update failed (continuing).%s\n' "$red" "$reset"
  fi
  if [[ $status -eq 0 && "$kernel_pending" == "1" ]]; then
    run_kernel || status=$?
  elif [[ $status -eq 0 ]]; then
    printf '\nNo new kernel; the kernel script was not run.\n'
  fi
fi

echo
if [[ $status -eq 0 ]]; then
  printf '%s%sDone.%s\n' "$bold" "$green" "$reset"
else
  printf '%s%sFinished with an error (code %d).%s\n' "$bold" "$red" "$status" "$reset"
fi
read -rsn1 -p "Press any key to close…"
