#!/usr/bin/env bash
# Máquinas virtuais do libvirt em JSON (usado pelo VmWidget).
# Usa a conexão do sistema (a mesma do virt-manager). Para mudar: LIBVIRT_URI=qemu:///session
URI="${LIBVIRT_URI:-qemu:///system}"

v() { timeout 5 virsh -q -c "$URI" "$@" 2>/dev/null; }

if ! command -v virsh >/dev/null; then
  echo '{"error":"virsh not found (libvirt package)","vms":[]}'
  exit 0
fi

names=$(timeout 5 virsh -q -c "$URI" list --all --name 2>&1)
if [[ $? -ne 0 ]]; then
  jq -n --arg e "$(head -n1 <<<"$names")" '{error: $e, vms: []}'
  exit 0
fi

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  info=$(v dominfo "$name")
  field() { awk -F': +' -v k="$1" '$1 == k { print $2; exit }' <<<"$info"; }

  state=$(field "State")
  vcpus=$(field "CPU(s)")
  maxmem=$(field "Max memory" | awk '{ print $1 + 0 }')    # KiB
  usedmem=$(field "Used memory" | awk '{ print $1 + 0 }')  # KiB
  autostart=$(field "Autostart")

  # sistema convidado, pela marcação do libosinfo que o virt-manager grava no XML
  os=$(v dumpxml "$name" | grep -o 'libosinfo:os id="[^"]*"' | head -n1 | sed 's/.*id="//; s/"$//')

  # IP (pela concessão do DHCP da rede do libvirt), só com a VM ligada
  ip=""
  if [[ "$state" == "running" ]]; then
    ip=$(v domifaddr "$name" | awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }')
  fi

  jq -n --arg name "$name" --arg state "$state" --arg os "$os" --arg ip "$ip" \
    --arg autostart "$autostart" \
    --argjson vcpus "${vcpus:-0}" --argjson maxmem "${maxmem:-0}" --argjson usedmem "${usedmem:-0}" \
    '{name: $name, state: $state, os: $os, ip: $ip, autostart: ($autostart == "enable"),
      vcpus: $vcpus, maxmem: $maxmem, usedmem: $usedmem}'
done <<<"$names" | jq -s '{error: "", vms: sort_by((if .state == "running" then 0 elif .state == "paused" then 1 else 2 end), .name)}'
