#!/usr/bin/env bash
# Atualizações pendentes (repositórios + AUR) em JSON, para o UpdatesWidget.
# Repositórios: checkupdates (pacman-contrib), que usa uma cópia do banco e não mexe no sistema.
# AUR: paru -Qua.
# Uso: updates-check.sh [regex dos pacotes de kernel]

KERNEL_RE="${1:-^linux-cachyos(-headers)?$}"

# Linhas no formato "nome versão-antiga -> versão-nova [ignorado]"
to_json() {
  awk '$3 == "->" { printf "%s\t%s\t%s\t%s\n", $1, $2, $4, ($5 ~ /ignored/ ? "1" : "0") }' |
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
             | {name: .[0], old: .[1], new: .[2], ignored: (.[3] == "1")})'
}

errors=()

repo_out=$(checkupdates 2>/dev/null); rc=$?
# checkupdates: 0 = há atualizações, 2 = nenhuma, outro = erro
if [[ $rc -ne 0 && $rc -ne 2 ]]; then errors+=("checkupdates failed (no network?)"); repo_out=""; fi
repo=$(to_json <<<"$repo_out")

aur_out=$(timeout 60 paru -Qua 2>/dev/null); rc=$?
# paru -Qua: 0 = há atualizações, 1 = nenhuma ou erro (sem distinção confiável)
[[ $rc -gt 1 ]] && errors+=("paru -Qua failed")
aur=$(to_json <<<"$aur_out")

jq -n --argjson repo "$repo" --argjson aur "$aur" --arg re "$KERNEL_RE" \
  --arg error "$(IFS='; '; echo "${errors[*]}")" \
  '{
     repo: $repo,
     aur: $aur,
     kernel: ([$repo[], $aur[]] | map(select(.name | test($re))) | length > 0),
     error: $error,
     checked: (now | floor)
   }'
