#!/usr/bin/env bash
# health-check.sh — saúde do sistema em JSON, para o HealthWidget.
#   pacnew:  arquivos .pacnew/.pacsave em /etc (configs novas que o pacman não aplicou)
#   failed:  serviços com falha (sistema e usuário)
#   tpm:     o disco pediu senha neste boot em vez de destravar pelo TPM?
#   clean:   órfãos, cache do pacman, tamanho do journal (para a limpeza mensal)
# Não precisa de root (o journal é legível para o grupo wheel).

pacnew=$(find /etc \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | sort | jq -R . | jq -s .)

failed_sys=$(systemctl --failed --plain --no-legend 2>/dev/null | awk '{print $1}' | jq -R . | jq -s 'map(select(length>0))')
failed_usr=$(systemctl --user --failed --plain --no-legend 2>/dev/null | awk '{print $1}' | jq -R . | jq -s 'map(select(length>0))')

# TPM: o systemd-cryptsetup do initramfs só escreve no journal quando o TPM não destrava; quando
# destrava, fica quieto. Então: mensagem de falha = failed; disco aberto neste boot sem falha = ok;
# nenhum dos dois (sem LUKS, ou o journal do initramfs não chegou) = unknown.
tpm_log=$(journalctl -b -o cat --no-pager -t systemd-cryptsetup 2>/dev/null)
unlocked=$(journalctl -b -o cat --no-pager -u 'systemd-cryptsetup@*' -g '^Finished ' 2>/dev/null)
if grep -qiE "Failed to unseal|unsealing.*failed|TPM2 operation failed|No TPM2 metadata matching|policy.*does not match|PCR.*mismatch" <<<"$tpm_log"; then
  tpm=failed
elif [[ -n "$unlocked" ]]; then
  tpm=ok
else
  tpm=unknown
fi

orphans=$(pacman -Qdtq 2>/dev/null | wc -l)
cache=$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)
journal=$(journalctl --disk-usage 2>/dev/null | sed -nE 's/.*take up ([0-9.]+ ?[KMGTB]+).*/\1/p')

jq -n --argjson pacnew "$pacnew" --argjson fs "$failed_sys" --argjson fu "$failed_usr" \
  --arg tpm "$tpm" --argjson orphans "$orphans" --arg cache "${cache:-?}" --arg journal "${journal:-?}" \
  '{pacnew: $pacnew, failed: {system: $fs, user: $fu}, tpm: $tpm,
    clean: {orphans: $orphans, cache: $cache, journal: $journal}}'
