#!/usr/bin/env bash
# Detalhes das interfaces de rede ativas, em JSON (usado pela barra do Quickshell).

# Converte prefixo (24) em máscara (255.255.255.0)
prefix_to_mask() {
  local p=$1 out=() b
  for _ in 1 2 3 4; do
    b=$(( p >= 8 ? 8 : (p > 0 ? p : 0) ))
    out+=( $(( 256 - (1 << (8 - b)) )) )
    p=$(( p - 8 ))
  done
  local IFS=.; echo "${out[*]}"
}

# IP externo (uma consulta só, com limite de 3 s)
external=$(curl -4 -s --max-time 3 https://api.ipify.org || true)

# Interfaces ativas com IPv4, ignorando loopback e as virtuais do Docker/VMs
ip -j addr show up | jq -c '.[]
  | select(.ifname != "lo" and (.ifname | test("^(veth|docker|br-|virbr)") | not))
  | select(any(.addr_info[]?; .family == "inet"))' |
while read -r link; do
  iface=$(jq -r '.ifname' <<<"$link")
  mac=$(jq -r '.address // ""' <<<"$link")
  ipv4=$(jq -r '[.addr_info[] | select(.family == "inet")][0].local' <<<"$link")
  prefix=$(jq -r '[.addr_info[] | select(.family == "inet")][0].prefixlen' <<<"$link")
  ipv6=$(jq -r '[.addr_info[] | select(.family == "inet6" and .scope == "global")][0].local // ""' <<<"$link")
  gateway=$(ip -j route show default dev "$iface" | jq -r '.[0].gateway // ""')

  # Tipo de conexão: Wi-Fi (com SSID) ou cabo (com velocidade do link)
  if [[ -d /sys/class/net/$iface/wireless ]]; then
    type="wifi"; speed=""
    ssid=$(command -v iw >/dev/null && iw dev "$iface" link | awk -F': ' '/SSID/ {print $2}')
  else
    type="ethernet"; ssid=""
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
    [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )) && speed="$speed Mb/s" || speed=""
  fi

  # DNS: por interface via systemd-resolved; senão, o /etc/resolv.conf
  dns=""
  if command -v resolvectl >/dev/null && resolvectl status >/dev/null 2>&1; then
    dns=$(resolvectl dns "$iface" 2>/dev/null | cut -d: -f2- | xargs)
  fi
  [[ -z "$dns" ]] && dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)

  jq -n --arg iface "$iface" --arg type "$type" --arg ssid "$ssid" --arg mac "$mac" \
    --arg ipv4 "$ipv4" --arg prefix "$prefix" --arg mask "$(prefix_to_mask "$prefix")" \
    --arg gateway "$gateway" --arg dns "$dns" --arg ipv6 "$ipv6" \
    --arg speed "$speed" --arg external "$external" '$ARGS.named'
done | jq -s .
