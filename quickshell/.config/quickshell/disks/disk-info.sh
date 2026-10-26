#!/usr/bin/env bash
# Pontos de montagem reais, agrupados por sistema de arquivos, em JSON (usado pelo DiskWidget).
# Subvolumes btrfs do mesmo disco viram um item só, com cada subvolume e seu ponto de montagem.
# Para btrfs, inclui também alocação (dados/metadados/sistema), compressão, erros e snapshots,
# tudo lido do /sys sem precisar de root.
# Montagens de rede (SMB/NFS) que não respondem em 3 s aparecem como "stale", sem travar a lista.

# 1. Lista as montagens sem consultar o espaço (isso não trava em compartilhamento caído)
findmnt -J -l --real -o TARGET,SOURCE,FSTYPE,OPTIONS,FSROOT,UUID 2>/dev/null | jq -c '
  [.filesystems[]
   | select(.fstype != "autofs" and (.target | startswith("/run/") | not))
   | . + {dev: (.source | sub("\\[.*\\]$"; ""))}]
  | group_by(.dev)
  | map({
      dev: .[0].dev,
      fstype: .[0].fstype,
      uuid: (.[0].uuid // ""),
      targets: (map(.target) | sort_by(length)),
      readonly: (.[0].options | split(",") | index("ro") != null),
      compression: ((.[0].options | capture("compress(-force)?=(?<c>[^,]+)").c) // ""),
      subvolumes: (map({target: .target, subvol: (.fsroot // "/")}) | sort_by(.target | length))
    })
  | .[]' |
while read -r fs; do
  dev=$(jq -r '.dev' <<<"$fs")
  fstype=$(jq -r '.fstype' <<<"$fs")
  target=$(jq -r '.targets[0]' <<<"$fs")

  # 2. Espaço, com limite de tempo por montagem
  stale=false
  read -r size used avail < <(timeout 3 df -B1 --output=size,used,avail "$target" 2>/dev/null | tail -n1)
  if ! [[ "$size" =~ ^[0-9]+$ ]]; then
    stale=true; size=0; used=0; avail=0
  fi

  # 3. Disco físico por trás (modelo, conexão, criptografia)
  network=false; disk=""; tran=""; encrypted=false
  case "$fstype" in
    cifs|smb3|nfs|nfs4|fuse.sshfs|sshfs) network=true; disk="$dev" ;;
  esac
  if [[ $network == false && -b "$dev" ]]; then
    info=$(lsblk -J -s -o NAME,TYPE,MODEL,TRAN "$dev" 2>/dev/null)
    disk=$(jq -r '[.. | objects | select(.type? == "disk")][0].model // "" | gsub("^\\s+|\\s+$"; "")' <<<"$info")
    tran=$(jq -r '[.. | objects | select(.type? == "disk")][0].tran // ""' <<<"$info")
    encrypted=$(jq '[.. | objects | select(.type? == "crypt")] | length > 0' <<<"$info")
  fi

  # 4. Detalhes do btrfs (via /sys/fs/btrfs/<UUID>)
  btrfs=null
  uuid=$(jq -r '.uuid' <<<"$fs")
  base="/sys/fs/btrfs/$uuid"
  if [[ "$fstype" == btrfs && -n "$uuid" && -d "$base/allocation" ]]; then
    alloc() {
      local dir="$base/allocation/$1" prof="" p
      for p in "$dir"/*/; do [[ -d "$p" ]] && { prof=$(basename "$p"); break; }; done
      jq -n --arg profile "$prof" \
        --argjson total "$(cat "$dir/total_bytes" 2>/dev/null || echo 0)" \
        --argjson used "$(cat "$dir/bytes_used" 2>/dev/null || echo 0)" \
        --argjson disk "$(cat "$dir/disk_total" 2>/dev/null || echo 0)" \
        '{profile: $profile, total: $total, used: $used, disk: $disk}'
    }
    data=$(alloc data); meta=$(alloc metadata); sys=$(alloc system)

    # tamanho bruto dos dispositivos (setores de 512 bytes)
    devsize=0
    for d in "$base"/devices/*; do
      s=$(cat "$d/size" 2>/dev/null || echo 0)
      devsize=$(( devsize + s * 512 ))
    done

    # erros acumulados (leitura, escrita, corrupção…); -1 se o kernel não expõe
    errors=-1
    if compgen -G "$base/devinfo/*/error_stats" >/dev/null; then
      errors=$(cat "$base"/devinfo/*/error_stats | awk '{ s += $2 } END { print s + 0 }')
    fi

    # snapshots em /.snapshots, se a pasta for legível para o usuário; -1 se não for
    snapshots=-1
    if jq -e '.targets | index("/.snapshots")' <<<"$fs" >/dev/null && [[ -r /.snapshots && -x /.snapshots ]]; then
      snapshots=$(find /.snapshots -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi

    label=$(cat "$base/label" 2>/dev/null)

    btrfs=$(jq -n --argjson data "$data" --argjson metadata "$meta" --argjson system "$sys" \
      --argjson devsize "$devsize" --argjson errors "$errors" --argjson snapshots "$snapshots" \
      --arg label "$label" \
      '{label: $label, data: $data, metadata: $metadata, system: $system,
        unallocated: ([$devsize - ($data.disk + $metadata.disk + $system.disk), 0] | max),
        errors: $errors, snapshots: $snapshots}')
  fi

  jq -n --argjson fs "$fs" --arg disk "$disk" --arg tran "$tran" \
    --argjson size "$size" --argjson used "$used" --argjson avail "$avail" \
    --argjson network "$network" --argjson encrypted "$encrypted" --argjson stale "$stale" \
    --argjson btrfs "$btrfs" \
    '$fs + {disk: $disk, tran: $tran, size: $size, used: $used, avail: $avail,
            network: $network, encrypted: $encrypted, stale: $stale, btrfs: $btrfs}'
done | jq -s 'sort_by((if .targets[0] == "/" then 0 elif .network then 2 else 1 end), .targets[0])'
