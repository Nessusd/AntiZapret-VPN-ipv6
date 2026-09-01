#!/bin/bash
set -e

ROOT_DIR="${ANTIZAPRET_ROOT:-/root/antizapret}"
CHAIN=ANTIZAPRET-BGP

# Сначала удаляем все старые привязки цепочки: повторный запуск должен давать
# тот же набор правил и не накапливать переходы в INPUT.
remove_rules() {
	while iptables -w -C INPUT -p tcp --dport 179 -j "$CHAIN" &>/dev/null; do
		iptables -w -D INPUT -p tcp --dport 179 -j "$CHAIN"
	done
	iptables -w -F "$CHAIN" &>/dev/null || true
	iptables -w -X "$CHAIN" &>/dev/null || true
	while ip6tables -w -C INPUT -p tcp --dport 179 -j "$CHAIN" &>/dev/null; do
		ip6tables -w -D INPUT -p tcp --dport 179 -j "$CHAIN"
	done
	ip6tables -w -F "$CHAIN" &>/dev/null || true
	ip6tables -w -X "$CHAIN" &>/dev/null || true
}

case "${1:-}" in
	down)
		remove_rules
		exit 0
		;;
	up) ;;
	*)
		echo "Usage: $0 {up|down}" >&2
		exit 2
		;;
esac

source "$ROOT_DIR/setup"
[[ "${BGP_ENABLE:-n}" == 'y' ]] || exit 0
[[ "${ALTERNATIVE_CLIENT_IP:-n}" == 'y' ]] && IP=172 || IP=10

# BGP разрешён только из подсетей включённых VPN-транспортов. Остальные
# подключения к TCP/179 отбрасываются отдельной цепочкой.
remove_rules
iptables -w -N "$CHAIN"
if [[ "${OPENVPN_UDP_ENABLE:-n}" == 'y' ]]; then
	iptables -w -A "$CHAIN" -i antizapret-udp -s "$IP.29.0.0/22" -j ACCEPT
fi
if [[ "${OPENVPN_TCP_ENABLE:-n}" == 'y' ]]; then
	iptables -w -A "$CHAIN" -i antizapret-tcp -s "$IP.29.4.0/22" -j ACCEPT
fi
if [[ "${WIREGUARD_ENABLE:-n}" == 'y' ]]; then
	iptables -w -A "$CHAIN" -i antizapret -s "$IP.29.8.0/24" -j ACCEPT
fi
iptables -w -A "$CHAIN" -j DROP
iptables -w -I INPUT 1 -p tcp --dport 179 -j "$CHAIN"

# AntiZapret BGP sessions use IPv4 transport. Do not expose TCP/179 over IPv6.
ip6tables -w -N "$CHAIN"
ip6tables -w -A "$CHAIN" -j DROP
ip6tables -w -I INPUT 1 -p tcp --dport 179 -j "$CHAIN"
