#!/bin/bash
set -e
shopt -s nullglob

cd /root/antizapret

CUTOVER_HOOK_MARKER=/run/antizapret-setup.defer-custom-hooks
CUTOVER_HOOK_ENV=/run/antizapret-setup.custom-hook.env
CUTOVER_HOOK_LOCK=/run/antizapret-setup.custom-hook.lock
CUTOVER_LOCK=/run/antizapret-setup.lock

cutover_lock_active() {
	local lock_fd

	[[ -e "$CUTOVER_LOCK" ]] || return 1
	if ! exec {lock_fd}>> "$CUTOVER_LOCK"; then
		return 0
	fi
	if flock -n "$lock_fd"; then
		flock -u "$lock_fd" >/dev/null 2>&1 || true
		exec {lock_fd}>&-
		return 1
	fi
	exec {lock_fd}>&-
	return 0
}

save_cutover_hook_environment() {
	local temporary

	temporary="$(mktemp "${CUTOVER_HOOK_ENV}.XXXXXX")"
	if ! export -p > "$temporary" ||
		! chmod 600 "$temporary" ||
		! chown root:root "$temporary" ||
		! mv -f -- "$temporary" "$CUTOVER_HOOK_ENV"
	then
		rm -f -- "$temporary"
		return 1
	fi
}

write_cutover_hook_state() {
	local state=$1 temporary

	temporary="$(mktemp "${CUTOVER_HOOK_MARKER}.XXXXXX")"
	if ! printf '%s\n' "$state" > "$temporary" ||
		! chmod 600 "$temporary" ||
		! chown root:root "$temporary" ||
		! mv -f -- "$temporary" "$CUTOVER_HOOK_MARKER"
	then
		rm -f -- "$temporary"
		return 1
	fi
}

if [[ "${1:-}" == '--complete-cutover' ]]; then
	(
		CUTOVER_HOOK_LOCK_FD=
		if ! exec {CUTOVER_HOOK_LOCK_FD}>> "$CUTOVER_HOOK_LOCK"; then
			echo 'Cannot open custom hook cutover lock' >&2
			exit 1
		fi
		chmod 600 "$CUTOVER_HOOK_LOCK"
		flock "$CUTOVER_HOOK_LOCK_FD"

		if [[ -f "$CUTOVER_HOOK_MARKER" ]] && ! cutover_lock_active; then
			case "$(< "$CUTOVER_HOOK_MARKER")" in
				deferred|ready|applied|stopped)
					rm -f -- "$CUTOVER_HOOK_MARKER" "$CUTOVER_HOOK_ENV"
					echo 'Custom hook cutover is stale' >&2
					exit 1
					;;
				*)
					echo 'Invalid custom hook cutover state' >&2
					exit 1
					;;
			esac
		fi
		if [[ ! -f "$CUTOVER_HOOK_MARKER" ]]; then
			echo 'Custom hooks are not deferred' >&2
			exit 1
		fi
		if [[ "$(< "$CUTOVER_HOOK_MARKER")" != 'ready' ]] || [[ ! -f "$CUTOVER_HOOK_ENV" ]]; then
			echo 'Custom-up cannot be completed in the current cutover state' >&2
			exit 1
		fi

		# applied означает, что custom-down уже обязателен. ExecStopPost
		# дождётся этого lock, если основной unit упадёт прямо во время hook.
		write_cutover_hook_state applied
		source "$CUTOVER_HOOK_ENV"
		rm -f -- "$CUTOVER_HOOK_ENV"
		(
			# Фоновый процесс из custom-up не должен держать cutover lock.
			exec {CUTOVER_HOOK_LOCK_FD}>&-
			./custom-up.sh
		)
	)
	exit 0
elif (( $# != 0 )); then
	echo "Unsupported argument: $1" >&2
	exit 1
fi

# Это внутренняя уборка перед применением новых правил. При install-cutover
# marker=deferred ещё не означает падение службы.
if [[ -f "$CUTOVER_HOOK_MARKER" ]] &&
	[[ "$(< "$CUTOVER_HOOK_MARKER")" == 'deferred' ]] && cutover_lock_active
then
	ANTIZAPRET_INTERNAL_PRECLEANUP=y ./down.sh
else
	./down.sh
fi

source setup

load_openvpn_tcp_ports() {
	local config proto port server_dir
	server_dir="${OPENVPN_SERVER_DIR:-/etc/openvpn/server}"
	OPENVPN_TCP_PORTS=
	OPENVPN_TCP6_PORTS=
	for config in \
		"$server_dir/antizapret-tcp.conf" \
		"$server_dir/vpn-tcp.conf"; do
		[[ -f "$config" ]] || continue
		proto="$(awk '$1 == "proto" { print tolower($2); exit }' "$config")"
		[[ "$proto" == tcp* ]] || continue
		port="$(awk '$1 == "port" { print $2; exit }' "$config")"
		if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
			echo "Invalid OpenVPN TCP port in $config: ${port:-missing}" >&2
			return 1
		fi
		port=$((10#$port))
		case ",$OPENVPN_TCP_PORTS," in
			*",$port,"*) ;;
			*) OPENVPN_TCP_PORTS="${OPENVPN_TCP_PORTS:+$OPENVPN_TCP_PORTS,}$port" ;;
		esac
		case "$proto" in
			tcp6|tcp6-server)
				case ",$OPENVPN_TCP6_PORTS," in
					*",$port,"*) ;;
					*) OPENVPN_TCP6_PORTS="${OPENVPN_TCP6_PORTS:+$OPENVPN_TCP6_PORTS,}$port" ;;
				esac
				;;
		esac
	done
	if [[ -z "$OPENVPN_TCP_PORTS" ]]; then
		echo 'No enabled OpenVPN TCP server ports found!' >&2
		return 1
	fi
}

if [[ -z "$DEFAULT_INTERFACE" ]]; then
	DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
	if [[ -z "$DEFAULT_INTERFACE" ]]; then
		echo 'Default network interface not found!'
		exit 1
	fi
	DEFAULT_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
	if [[ -z "$DEFAULT_IP" ]]; then
		echo 'Default IPv4 address not found!'
		exit 2
	fi
fi

if [[ -z "$ANTIZAPRET_OUT_INTERFACE" ]]; then
	ANTIZAPRET_OUT_INTERFACE=$DEFAULT_INTERFACE
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		ANTIZAPRET_OUT_IP=$DEFAULT_IP
	fi
fi

if [[ -z "$VPN_OUT_INTERFACE" ]]; then
	VPN_OUT_INTERFACE=$DEFAULT_INTERFACE
	if [[ -z "$VPN_OUT_IP" ]]; then
		VPN_OUT_IP=$DEFAULT_IP
	fi
fi

[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP="${CLIENT_IP:-172}" || IP=10
[[ "$ALTERNATIVE_FAKE_IP" == 'y' ]] && FAKE_IP="${FAKE_IP:-198.18}" || FAKE_IP="$IP.30"
MTU="${MTU:-1420}"

warp_ipv6_stack_available() {
	[[ "${DISABLE_IPV6:-n}" != 'y' ]] || return 1
	[[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || return 1
	[[ -r /proc/sys/net/ipv6/conf/default/disable_ipv6 ]] || return 1
	[[ "$(< /proc/sys/net/ipv6/conf/all/disable_ipv6)" == '0' ]] || return 1
	[[ "$(< /proc/sys/net/ipv6/conf/default/disable_ipv6)" == '0' ]]
}

warp_ipv6_parameters() {
	python3 - "$1" "${VPN_IPV6_PREFIX:-fd3a:c9bc:6bcb::/48}" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1].split("/", 1)[0])
    prefix = ipaddress.ip_network(sys.argv[2], strict=True)
except ValueError:
    raise SystemExit(1)

if not isinstance(address, ipaddress.IPv6Address) or not address.is_global:
    raise SystemExit(1)
if not isinstance(prefix, ipaddress.IPv6Network) or prefix.prefixlen != 48:
    raise SystemExit(1)
if not prefix.subnet_of(ipaddress.IPv6Network("fc00::/7")):
    raise SystemExit(1)

print(address.compressed, prefix.with_prefixlen)
PY
}

write_warp_config() {
	local mode=$1 path=$2 private_key=$3 address4=$4 address6=$5
	local public_key=$6 endpoint=$7 table=$8
	local client_network mark address_line allowed_ips

	if [[ "$mode" == 'antizapret' ]]; then
		client_network="$IP.29.0.0/16"
		mark='0x10000000/0x30000000'
	else
		client_network="$IP.28.0.0/16"
		mark='0x20000000/0x30000000'
	fi

	address_line="$address4/32"
	allowed_ips='0.0.0.0/0'
	if [[ -n "$address6" ]]; then
		address_line+=", $address6/128"
		allowed_ips+=', ::/0'
	fi

	{
		printf '[Interface]\n'
		printf 'PrivateKey = %s\n' "$private_key"
		printf 'Address = %s\n' "$address_line"
		printf 'MTU = %s\n' "$MTU"
		printf 'Table = %s\n' "$table"
		printf 'PostUp = ip rule add from %s to %s lookup main priority 5000 || true\n' "$client_network" "$client_network"
		if [[ "$mode" == 'antizapret' ]]; then
			printf 'PostUp = ip rule add from %s to %s lookup main priority 5000 || true\n' "$client_network" "$FAKE_IP.0.0/15"
		fi
		printf 'PostUp = ip rule add from %s lookup %s priority 10000 || true\n' "$client_network" "$table"
		printf 'PostDown = ip rule del from %s to %s priority 5000\n' "$client_network" "$client_network"
		if [[ "$mode" == 'antizapret' ]]; then
			printf 'PostDown = ip rule del from %s to %s priority 5000\n' "$client_network" "$FAKE_IP.0.0/15"
		fi
		printf 'PostDown = ip rule del from %s lookup %s priority 10000\n' "$client_network" "$table"
		if [[ -n "$address6" ]]; then
			printf 'PostUp = ip -6 rule add fwmark %s to %s lookup main priority 5000 || true\n' "$mark" "$WARP_IPV6_PREFIX"
			printf 'PostUp = ip -6 rule add fwmark %s lookup %s priority 10000 || true\n' "$mark" "$table"
			printf 'PostDown = ip -6 rule del fwmark %s to %s lookup main priority 5000 || true\n' "$mark" "$WARP_IPV6_PREFIX"
			printf 'PostDown = ip -6 rule del fwmark %s lookup %s priority 10000 || true\n' "$mark" "$table"
		fi
		printf '\n[Peer]\n'
		printf 'PublicKey = %s\n' "$public_key"
		printf 'AllowedIPs = %s\n' "$allowed_ips"
		printf 'PersistentKeepalive = 15\n'
		printf 'Endpoint = %s\n' "$endpoint"
	} > "$path"
}

start_warp() {
	local mode=$1 interface=$2 path=$3 table=$4 ipv6_requested=$5
	local private_key key reg public_key endpoint address4 address6 ipv6_data

	echo "Starting $interface..."
	private_key=$(wg genkey)
	key=$(echo "$private_key" | wg pubkey)
	reg=$(curl -sSfL --connect-timeout 10 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
		-H 'Content-Type: application/json' \
		-d "{\"key\": \"$key\"}")

	public_key=$(echo "$reg" | jq -r '.config.peers[0].public_key')
	endpoint=$(echo "$reg" | jq -r '.config.peers[0].endpoint.host')
	address4=$(echo "$reg" | jq -r '.config.interface.addresses.v4')
	address6=
	WARP_IPV6_PREFIX=
	if [[ "$ipv6_requested" == 'y' ]] && warp_ipv6_stack_available; then
		ipv6_data=$(warp_ipv6_parameters "$(echo "$reg" | jq -r '.config.interface.addresses.v6 // empty')" 2>/dev/null)
		if [[ $? -eq 0 ]]; then
			read -r address6 WARP_IPV6_PREFIX <<< "$ipv6_data"
		fi
	fi

	write_warp_config "$mode" "$path" "$private_key" "$address4" "$address6" "$public_key" "$endpoint" "$table"
	wg-quick up "$path" 2>/dev/null
	WARP_START_STATUS=$?

	# IPv6 must never make the established IPv4 WARP path unavailable.
	if [[ $WARP_START_STATUS -ne 0 && -n "$address6" ]]; then
		echo "Starting $interface with IPv6 failed! Retrying IPv4-only..."
		wg-quick down "$path" &>/dev/null || true
		ip link delete dev "$interface" &>/dev/null || true
		address6=
		WARP_IPV6_PREFIX=
		write_warp_config "$mode" "$path" "$private_key" "$address4" "$address6" "$public_key" "$endpoint" "$table"
		wg-quick up "$path" 2>/dev/null
		WARP_START_STATUS=$?
	fi

	WARP_START_ENDPOINT="$endpoint"
	WARP_START_ADDRESS4="$address4"
	WARP_START_ADDRESS6="$address6"
}

# WARP AntiZapret
WARP_ANTIZAPRET_INTERFACE=warp-antizapret
WARP_ANTIZAPRET_PATH="/etc/wireguard/$WARP_ANTIZAPRET_INTERFACE.conf"

if [[ "$ANTIZAPRET_WARP" == 'y' ]]; then
	set +e
	WARP_IPV6_REQUESTED=y
	if [[ -n "${ANTIZAPRET_IPV6_OUT_INTERFACE:-${ANTIZAPRET_OUT_INTERFACE6:-}}" || -n "${ANTIZAPRET_IPV6_OUT_IP:-${ANTIZAPRET_OUT_IP6:-}}" ]]; then
		WARP_IPV6_REQUESTED=n
	fi
	start_warp antizapret "$WARP_ANTIZAPRET_INTERFACE" "$WARP_ANTIZAPRET_PATH" 13335 "$WARP_IPV6_REQUESTED"

	if [[ $WARP_START_STATUS -eq 0 ]]; then
		echo "Started $WARP_ANTIZAPRET_INTERFACE: $WARP_START_ENDPOINT connected"
		ANTIZAPRET_OUT_INTERFACE=$WARP_ANTIZAPRET_INTERFACE
		ANTIZAPRET_OUT_IP=$WARP_START_ADDRESS4
	else
		echo "Starting $WARP_ANTIZAPRET_INTERFACE failed! Use $DEFAULT_INTERFACE"
	fi
	set -e
else
	rm -f $WARP_ANTIZAPRET_PATH
fi

# WARP VPN
WARP_VPN_INTERFACE=warp-vpn
WARP_VPN_PATH="/etc/wireguard/$WARP_VPN_INTERFACE.conf"

if [[ "$VPN_WARP" == 'y' ]]; then
	set +e
	WARP_IPV6_REQUESTED=y
	if [[ -n "${VPN_IPV6_OUT_INTERFACE:-${VPN_OUT_INTERFACE6:-}}" || -n "${VPN_IPV6_OUT_IP:-${VPN_OUT_IP6:-}}" ]]; then
		WARP_IPV6_REQUESTED=n
	fi
	start_warp vpn "$WARP_VPN_INTERFACE" "$WARP_VPN_PATH" 13336 "$WARP_IPV6_REQUESTED"

	if [[ $WARP_START_STATUS -eq 0 ]]; then
		echo "Started $WARP_VPN_INTERFACE: $WARP_START_ENDPOINT connected"
		VPN_OUT_INTERFACE=$WARP_VPN_INTERFACE
		VPN_OUT_IP=$WARP_START_ADDRESS4
	else
		echo "Starting $WARP_VPN_INTERFACE failed! Use $DEFAULT_INTERFACE"
	fi
	set -e
else
	rm -f $WARP_VPN_PATH
fi

# filter
# Default policy
iptables -w -P INPUT ACCEPT
iptables -w -P FORWARD ACCEPT
iptables -w -P OUTPUT ACCEPT
ip6tables -w -P INPUT ACCEPT
ip6tables -w -P FORWARD ACCEPT
ip6tables -w -P OUTPUT ACCEPT
# INPUT connection tracking
iptables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
# FORWARD connection tracking
iptables -w -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
# OUTPUT connection tracking
iptables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
ip6tables -w -I OUTPUT 1 -m conntrack --ctstate INVALID -j DROP
# Torrent guard
if [[ "$TORRENT_GUARD" == 'y' ]]; then
	ipset create antizapret-torrent hash:ip timeout 60 -exist
	iptables -w -I FORWARD 2 -s $IP.28.0.0/16 -p tcp -m string --string 'GET ' --algo kmp --to 100 -m string --string 'info_hash=' --algo bm -m string --string 'peer_id=' --algo bm -m string --string 'port=' --algo bm -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 3 -s $IP.28.0.0/16 -p udp -m string --string 'BitTorrent protocol' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 4 -s $IP.28.0.0/16 -p udp -m string --string 'd1:ad2:id20:' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
	iptables -w -I FORWARD 5 -s $IP.28.0.0/16 -m set --match-set antizapret-torrent src -j DROP
fi
# Restrict forwarding
if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
	{
		echo 'create antizapret-forward hash:net -exist'
		echo 'flush antizapret-forward'
		if [[ -f result/forward-ips.txt ]]; then
			while read -r line; do
				echo "add antizapret-forward $line"
			done < result/forward-ips.txt
		fi
	} | ipset restore
	iptables -w -I FORWARD 2 -s $IP.29.0.0/16 -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP
fi
# Drop forwarding
{
	echo 'create antizapret-drop hash:net -exist'
	echo 'flush antizapret-drop'
	if [[ -f result/drop-ips.txt ]]; then
		while read -r cidr; do
			echo "add antizapret-drop $cidr"
		done < result/drop-ips.txt
	fi
} | ipset restore
iptables -w -I FORWARD 2 -s $IP.28.0.0/15 -m set --match-set antizapret-drop dst -j DROP
# Client and server isolation
if [[ "$CLIENT_ISOLATION" == 'y' ]]; then
	if [[ "$ANTIZAPRET_OUT_INTERFACE" == "$VPN_OUT_INTERFACE" ]]; then
		iptables -w -I FORWARD 2 ! -i $ANTIZAPRET_OUT_INTERFACE -d $IP.28.0.0/15 -j DROP
	else
		iptables -w -I FORWARD 2 ! -i $ANTIZAPRET_OUT_INTERFACE -d $IP.29.0.0/16 -j DROP
		iptables -w -I FORWARD 3 ! -i $VPN_OUT_INTERFACE -d $IP.28.0.0/16 -j DROP
	fi
	iptables -w -I INPUT 2 -s $IP.28.0.0/15 -p tcp ! --dport 53 -j DROP
	iptables -w -I INPUT 3 -s $IP.28.0.0/15 -p udp ! --dport 53 -j DROP
fi
# SSH protection
if [[ "$SSH_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-ssh --hashlimit-htable-expire 60000 -j DROP
	ip6tables -w -I INPUT 2 -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-ssh6 --hashlimit-htable-expire 60000 -j DROP
fi
# Attack protection
if [[ "$ATTACK_PROTECTION" == 'y' ]]; then
	{
		echo 'create antizapret-allow hash:net -exist'
		echo 'flush antizapret-allow'
		if [[ -f result/allow-ips.txt ]]; then
			while read -r line; do
				echo "add antizapret-allow $line"
			done < result/allow-ips.txt
		fi
	} | ipset restore
	ipset create antizapret-block hash:ip timeout 600 -exist
	ipset create antizapret-watch hash:ip,port timeout 600 -exist
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow src -j ACCEPT
	ATTACK_INPUT_RULE=3
	if [[ "${OPENVPN_TCP_ENABLE:-n}" == 'y' ]]; then
		load_openvpn_tcp_ports
		ipset create antizapret-openvpn-scanner hash:ip timeout 86400 -exist
		if [[ "${DISABLE_IPV6:-n}" != 'y' && -n "$OPENVPN_TCP6_PORTS" ]]; then
			ipset create antizapret-openvpn-scanner6 hash:ip family inet6 timeout 86400 -exist
		fi
		# Обычный OpenVPN TCP-кадр начинается с двухбайтовой длины пакета. Значение
		# 0x1603 вместо неё отправляют HTTPS/TLS-сканеры в начале TLS ClientHello.
		iptables -w -I INPUT "$ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -p tcp -m multiport --dports "$OPENVPN_TCP_PORTS" -m conntrack --ctstate ESTABLISHED -m u32 --u32 '0>>22&0x3C@12>>26&0x3C@0>>16&0xFFFF=0x1603' -m comment --comment antizapret-openvpn-scanner-detect -j SET --add-set antizapret-openvpn-scanner src --exist --timeout 86400
		ATTACK_INPUT_RULE=$((ATTACK_INPUT_RULE + 1))
		iptables -w -I INPUT "$ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -p tcp -m multiport --dports "$OPENVPN_TCP_PORTS" -m set --match-set antizapret-openvpn-scanner src -m comment --comment antizapret-openvpn-scanner-drop -j DROP
		ATTACK_INPUT_RULE=$((ATTACK_INPUT_RULE + 1))
	else
		ipset destroy antizapret-openvpn-scanner 2>/dev/null || true
	fi
	iptables -w -I INPUT "$ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-scan --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
	ATTACK_INPUT_RULE=$((ATTACK_INPUT_RULE + 1))
	iptables -w -I INPUT "$ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
	ATTACK_INPUT_RULE=$((ATTACK_INPUT_RULE + 1))
	iptables -w -I INPUT "$ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block src -j DROP
	ATTACK_INPUT_RULE=$((ATTACK_INPUT_RULE + 1))
	iptables -w -I INPUT "$ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch src,dst --exist
	ipset create antizapret-allow6 hash:net family inet6 -exist
	ipset create antizapret-block6 hash:ip timeout 600 family inet6 -exist
	ipset create antizapret-watch6 hash:ip,port timeout 600 family inet6 -exist
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow6 src -j ACCEPT
	IPV6_ATTACK_INPUT_RULE=3
	if [[ "${OPENVPN_TCP_ENABLE:-n}" == 'y' && "${DISABLE_IPV6:-n}" != 'y' && -n "$OPENVPN_TCP6_PORTS" ]]; then
		# u32 ниже считает TCP сразу после IPv6. Необычные extension headers
		# запоминаем как тот же сканер; следующее set-правило сразу его отбросит.
		ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -p tcp -m multiport --dports "$OPENVPN_TCP6_PORTS" -m conntrack --ctstate ESTABLISHED -m ipv6header ! --header prot -m comment --comment antizapret-openvpn-scanner6-extension-detect -j SET --add-set antizapret-openvpn-scanner6 src --exist --timeout 86400
		IPV6_ATTACK_INPUT_RULE=$((IPV6_ATTACK_INPUT_RULE + 1))
		ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -p tcp -m multiport --dports "$OPENVPN_TCP6_PORTS" -m conntrack --ctstate ESTABLISHED -m u32 --u32 '52>>26&0x3C@40>>16&0xFFFF=0x1603' -m comment --comment antizapret-openvpn-scanner6-detect -j SET --add-set antizapret-openvpn-scanner6 src --exist --timeout 86400
		IPV6_ATTACK_INPUT_RULE=$((IPV6_ATTACK_INPUT_RULE + 1))
		ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -p tcp -m multiport --dports "$OPENVPN_TCP6_PORTS" -m set --match-set antizapret-openvpn-scanner6 src -m comment --comment antizapret-openvpn-scanner6-drop -j DROP
		IPV6_ATTACK_INPUT_RULE=$((IPV6_ATTACK_INPUT_RULE + 1))
	else
		ipset destroy antizapret-openvpn-scanner6 2>/dev/null || true
	fi
	ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch6 src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-scan6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	IPV6_ATTACK_INPUT_RULE=$((IPV6_ATTACK_INPUT_RULE + 1))
	ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	IPV6_ATTACK_INPUT_RULE=$((IPV6_ATTACK_INPUT_RULE + 1))
	ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block6 src -j DROP
	IPV6_ATTACK_INPUT_RULE=$((IPV6_ATTACK_INPUT_RULE + 1))
	ip6tables -w -I INPUT "$IPV6_ATTACK_INPUT_RULE" -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch6 src,dst --exist
fi
# Scan protection
if [[ "$SCAN_PROTECTION" == 'y' ]]; then
	iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmp --icmp-type echo-request -j DROP
	iptables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	iptables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmp --icmp-type port-unreachable -j DROP
	ip6tables -w -I INPUT 2 -i $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type echo-request -j DROP
	ip6tables -w -I OUTPUT 2 -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
	ip6tables -w -I OUTPUT 3 -o $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type port-unreachable -j DROP
fi
# Deny input
{
	echo 'create antizapret-deny hash:net -exist'
	echo 'flush antizapret-deny'
	if [[ -f result/deny-ips.txt ]]; then
		while read -r cidr; do
			echo "add antizapret-deny $cidr"
		done < result/deny-ips.txt
	fi
} | ipset restore
iptables -w -I INPUT 2 -i $DEFAULT_INTERFACE -m set --match-set antizapret-deny src -j DROP

# mangle
# Clamp TCP MSS
iptables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -A OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# raw
# NOTRACK loopback
iptables -w -t raw -A PREROUTING -i lo -j NOTRACK
iptables -w -t raw -A OUTPUT -o lo -j NOTRACK
ip6tables -w -t raw -A PREROUTING -i lo -j NOTRACK
ip6tables -w -t raw -A OUTPUT -o lo -j NOTRACK

# nat
# OpenVPN TCP port redirection for backup connections
if [[ "${OPENVPN_TCP_ENABLE:-n}" == 'y' && "${OPENVPN_BACKUP_TCP:-n}" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 80 -j REDIRECT --to-ports 50080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 443 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 504 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 508 -j REDIRECT --to-ports 50080
fi
# OpenVPN UDP port redirection for backup connections
if [[ "${OPENVPN_UDP_ENABLE:-n}" == 'y' && "${OPENVPN_BACKUP_UDP:-n}" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 80 -j REDIRECT --to-ports 50080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 443 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 504 -j REDIRECT --to-ports 50443
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 508 -j REDIRECT --to-ports 50080
fi
# WireGuard/AmneziaWG port redirection for backup connections
if [[ "${WIREGUARD_ENABLE:-n}" == 'y' ]]; then
	if [[ "${WIREGUARD_BACKUP:-n}" == 'y' ]]; then
		iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 540 -j REDIRECT --to-ports 51443
		iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 580 -j REDIRECT --to-ports 51080
	fi
	# AmneziaWG redirection ports to WireGuard
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52080 -j REDIRECT --to-ports 51080
	iptables -w -t nat -A PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52443 -j REDIRECT --to-ports 51443
fi
# AntiZapret DNS redirection to Knot Resolver
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
# VPN DNS redirection to Knot Resolver
if [[ "$VPN_DNS" == '1' ]]; then
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
	iptables -w -t nat -A PREROUTING -s $IP.28.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
fi
# Restrict forwarding
if [[ "$RESTRICT_FORWARD" == 'y' ]]; then
	iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 ! -d $FAKE_IP.0.0/15 -j CONNMARK --set-mark 0x1
fi
# Mapping fake IP to real IP
iptables -w -t nat -S ANTIZAPRET-MAPPING &>/dev/null || iptables -w -t nat -N ANTIZAPRET-MAPPING
iptables -w -t nat -A PREROUTING -s $IP.29.0.0/16 -d $FAKE_IP.0.0/15 -j ANTIZAPRET-MAPPING
# SNAT/MASQUERADE VPN
if [[ "$ANTIZAPRET_OUT_INTERFACE" == "$VPN_OUT_INTERFACE" && "$ANTIZAPRET_OUT_IP" == "$VPN_OUT_IP" ]]; then
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
else
	if [[ -z "$ANTIZAPRET_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
	fi
	if [[ -z "$VPN_OUT_IP" ]]; then
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j MASQUERADE
	else
		iptables -w -t nat -A POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j SNAT --to-source $VPN_OUT_IP
	fi
fi

# Network tuning
TXQUEUELEN="${TXQUEUELEN:-1000}"
SEGMENTATION_OFFLOAD="${SEGMENTATION_OFFLOAD:-off}"
CPU_MASK=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
for dev in $(ls /sys/class/net); do
	[[ "$dev" == "lo" || "$dev" == *docker* ]] && continue
	# Set TX queue length
	ip link set "$dev" txqueuelen "$TXQUEUELEN"
	# Packet segmentation offload
	ethtool -K "$dev" tso "$SEGMENTATION_OFFLOAD" gso "$SEGMENTATION_OFFLOAD" gro "$SEGMENTATION_OFFLOAD" rx-udp-gro-forwarding "$SEGMENTATION_OFFLOAD"
	if [[ -e "/sys/class/net/$dev/device" ]]; then
		# Enable SoftIRQ CPU balance
		echo "$CPU_MASK" | tee /sys/class/net/$dev/queues/rx-*/rps_cpus >/dev/null
	else
		# Set MTU
		ip link set "$dev" mtu "$MTU"
	fi
done

# Clear Knot Resolver cache
if [[ "$(iptables -w -t nat -S ANTIZAPRET-MAPPING | wc -l)" -eq 1 ]]; then
	count="$(echo 'cache.clear()' | socat - /run/knot-resolver/control/1 | grep -oE '[0-9]+' || echo 0)"
	echo "AntiZapret DNS cache cleared: $count entries"
fi

# При повторном запуске основной службы вернём узкое BGP-правило перед
# правилами изоляции клиентов. При первой загрузке его установит BGP-служба.
if [[ "${BGP_ENABLE:-n}" == 'y' ]] && systemctl is-active --quiet antizapret-bgp.service; then
	./bgp-firewall.sh up
fi

if [[ ! -f "$CUTOVER_HOOK_MARKER" ]]; then
	./custom-up.sh
else
	case "$(< "$CUTOVER_HOOK_MARKER")" in
		deferred)
			save_cutover_hook_environment
			write_cutover_hook_state ready
			;;
		ready|applied) ;;
		stopped)
			echo 'Custom hook cutover was stopped' >&2
			exit 1
			;;
		*)
			echo 'Invalid custom hook cutover state' >&2
			exit 1
			;;
	esac
fi
exit 0
