#!/bin/bash
set -e
export LC_ALL=C

ROOT_DIR="${ANTIZAPRET_ROOT:-/root/antizapret}"
cd "$ROOT_DIR"
source setup
export DISABLE_IPV6 VPN_IPV6_PREFIX

DISABLE_IPV6="${DISABLE_IPV6:-n}"
ANTIZAPRET_IPV6_IN_INTERFACE="${ANTIZAPRET_IPV6_IN_INTERFACE:-antizapret+}"
VPN_IPV6_IN_INTERFACE="${VPN_IPV6_IN_INTERFACE:-vpn+}"

if [[ -z "${DEFAULT_INTERFACE:-}" ]]; then
	DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+' || true)"
fi

IPV6_ROUTE="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)"
DEFAULT_INTERFACE6="${DEFAULT_INTERFACE6:-$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$IPV6_ROUTE")}"
DEFAULT_IP6="${DEFAULT_IP6:-$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$IPV6_ROUTE")}"
if [[ -z "$DEFAULT_INTERFACE6" ]]; then
	DEFAULT_INTERFACE6="$(ip -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
fi
PUBLIC_INTERFACE6="${DEFAULT_INTERFACE6:-${DEFAULT_INTERFACE:-}}"

ANTIZAPRET_IPV6_OUT_INTERFACE="${ANTIZAPRET_IPV6_OUT_INTERFACE:-${ANTIZAPRET_OUT_INTERFACE6:-}}"
ANTIZAPRET_IPV6_OUT_IP="${ANTIZAPRET_IPV6_OUT_IP:-${ANTIZAPRET_OUT_IP6:-}}"
if [[ -z "$ANTIZAPRET_IPV6_OUT_INTERFACE" ]]; then
	ANTIZAPRET_IPV6_OUT_INTERFACE="$DEFAULT_INTERFACE6"
	[[ -n "$ANTIZAPRET_IPV6_OUT_IP" ]] || ANTIZAPRET_IPV6_OUT_IP="$DEFAULT_IP6"
fi

VPN_IPV6_OUT_INTERFACE="${VPN_IPV6_OUT_INTERFACE:-${VPN_OUT_INTERFACE6:-}}"
VPN_IPV6_OUT_IP="${VPN_IPV6_OUT_IP:-${VPN_OUT_IP6:-}}"
if [[ -z "$VPN_IPV6_OUT_INTERFACE" ]]; then
	VPN_IPV6_OUT_INTERFACE="$DEFAULT_INTERFACE6"
	[[ -n "$VPN_IPV6_OUT_IP" ]] || VPN_IPV6_OUT_IP="$DEFAULT_IP6"
fi

INPUT_CHAIN=ANTIZAPRET6-INPUT
FORWARD_CHAIN=ANTIZAPRET6-FORWARD
OUTPUT_CHAIN=ANTIZAPRET6-OUTPUT
MARK_CHAIN=ANTIZAPRET6-MARK
PREROUTING_CHAIN=ANTIZAPRET6-PREROUTING
POSTROUTING_CHAIN=ANTIZAPRET6-POSTROUTING
MAPPING_CHAIN=ANTIZAPRET6-MAPPING
ANTIZAPRET_MARK=0x10000000/0x30000000
VPN_MARK=0x20000000/0x30000000
FAKE_IPV6_NETWORK="$(python3 - "${VPN_IPV6_PREFIX:-fd3a:c9bc:6bcb::/48}" <<'PY'
import ipaddress
import sys

prefix = ipaddress.ip_network(sys.argv[1], strict=True)
if not isinstance(prefix, ipaddress.IPv6Network) or prefix.prefixlen != 48:
    raise SystemExit("VPN_IPV6_PREFIX must be an IPv6 /48 network")
if not prefix.subnet_of(ipaddress.IPv6Network("fc00::/7")):
    raise SystemExit("VPN_IPV6_PREFIX must be a private ULA /48 network")
print(ipaddress.IPv6Network((int(prefix.network_address) | (0x29FF << 64), 96)))
PY
)"

ip6t() { ip6tables -w "$@"; }

remove_jump() {
	local table=$1 chain=$2 target=$3
	while ip6t -t "$table" -C "$chain" -j "$target" 2>/dev/null; do
		ip6t -t "$table" -D "$chain" -j "$target" 2>/dev/null || break
	done
}

delete_chain() {
	ip6t -t "$1" -F "$2" 2>/dev/null || true
	ip6t -t "$1" -X "$2" 2>/dev/null || true
}

firewall_down() {
	set +e
	remove_jump filter INPUT "$INPUT_CHAIN"
	remove_jump filter FORWARD "$FORWARD_CHAIN"
	remove_jump filter OUTPUT "$OUTPUT_CHAIN"
	remove_jump mangle PREROUTING "$MARK_CHAIN"
	remove_jump nat PREROUTING "$PREROUTING_CHAIN"
	remove_jump nat POSTROUTING "$POSTROUTING_CHAIN"
	delete_chain filter "$INPUT_CHAIN"
	delete_chain filter "$FORWARD_CHAIN"
	delete_chain filter "$OUTPUT_CHAIN"
	delete_chain mangle "$MARK_CHAIN"
	delete_chain nat "$PREROUTING_CHAIN"
	delete_chain nat "$POSTROUTING_CHAIN"
	ipset destroy antizapret-torrent6 2>/dev/null
	set -e
}

load_set() {
	local live=$1 file=$2 temporary="${1}-new"
	ipset create "$live" hash:net family inet6 -exist
	ipset destroy "$temporary" 2>/dev/null || true
	ipset create "$temporary" hash:net family inet6
	if [[ -s "$file" ]]; then
		awk -v set="$temporary" '{print "add " set " " $0 " -exist"}' "$file" | ipset restore
	fi
	ipset swap "$temporary" "$live"
	ipset destroy "$temporary"
}

refresh_sets() {
	local mode="${1:-auto}"
	local args=()
	[[ "$mode" == 'download' ]] && args+=(--refresh-download)
	./firewall6-lists.py "${args[@]}"
	load_set antizapret-allow6 result/allow-ips6.txt
	load_set antizapret-deny6 result/deny-ips6.txt
	load_set antizapret-drop6 result/drop-ips6.txt
	load_set antizapret-forward6 result/forward-ips6.txt
}

insert_after_invalid() {
	local chain=$1 target=$2 position=1
	if ip6t -t filter -C "$chain" -m conntrack --ctstate INVALID -j DROP 2>/dev/null; then
		position=2
	fi
	ip6t -t filter -I "$chain" "$position" -j "$target"
}

redirect_ports() {
	local protocol=$1 pair source destination
	shift
	[[ -n "$PUBLIC_INTERFACE6" ]] || return 0
	for pair in "$@"; do
		source=${pair%%:*}
		destination=${pair##*:}
		ip6t -t nat -A "$PREROUTING_CHAIN" -i "$PUBLIC_INTERFACE6" -p "$protocol" --dport "$source" -j REDIRECT --to-ports "$destination"
	done
}

warn_without_global_ipv6() {
	[[ -n "$1" ]] || return 0
	ip -6 address show dev "$1" scope global 2>/dev/null | grep -q 'inet6 ' || \
		echo "Warning: no global IPv6 address found on $1; NAT66 will not provide Internet access"
}

source "$ROOT_DIR/firewall6-protection.sh"
source "$ROOT_DIR/firewall6-apply.sh"

case "${1:-up}" in
	up)
		[[ "$DISABLE_IPV6" == 'y' ]] && firewall_down || firewall_up "${2:-auto}"
		;;
	down)
		firewall_down
		;;
	refresh)
		[[ "$DISABLE_IPV6" == 'y' ]] || refresh_sets "${2:-auto}"
		;;
	*)
		echo "Usage: $0 {up|down|refresh} [auto|download]"
		exit 2
		;;
esac
