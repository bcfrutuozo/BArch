#!/usr/bin/env bash
# Roda dentro do terminal aberto pelo UpdatesWidget.
# Uso: run-update.sh <all|kernel> <script-do-kernel> <kernel-pendente: 1|0>
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

status=0
if [[ "$mode" == "kernel" ]]; then
  run_kernel || status=$?
else
  step "paru -Syu"
  paru -Syu || status=$?
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
