load_openvpn_tcp6_ports() {
	local config proto port server_dir
	server_dir="${OPENVPN_SERVER_DIR:-/etc/openvpn/server}"
	OPENVPN_TCP6_PORTS=
	for config in \
		"$server_dir/antizapret-tcp.conf" \
		"$server_dir/vpn-tcp.conf"; do
		[[ -f "$config" ]] || continue
		proto="$(awk '$1 == "proto" { print tolower($2); exit }' "$config")"
		case "$proto" in
			tcp6|tcp6-server) ;;
			*) continue ;;
		esac
		port="$(awk '$1 == "port" { print $2; exit }' "$config")"
		if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
			echo "Invalid OpenVPN TCP port in $config: ${port:-missing}" >&2
			return 1
		fi
		port=$((10#$port))
		case ",$OPENVPN_TCP6_PORTS," in
			*",$port,"*) ;;
			*) OPENVPN_TCP6_PORTS="${OPENVPN_TCP6_PORTS:+$OPENVPN_TCP6_PORTS,}$port" ;;
		esac
	done
}

add_attack_protection_for_ipv6_interface() {
	[[ "${ATTACK_PROTECTION:-n}" == 'y' ]] || return 0
	[[ -n "$PUBLIC_INTERFACE6" ]] || return 0
	[[ "$PUBLIC_INTERFACE6" != "${DEFAULT_INTERFACE:-}" ]] || return 0

	ipset create antizapret-block6 hash:ip family inet6 timeout 600 -exist
	ipset create antizapret-watch6 hash:ip,port family inet6 timeout 600 -exist
	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m set --match-set antizapret-allow6 src -j ACCEPT
	if [[ "${OPENVPN_TCP_ENABLE:-n}" == 'y' && "${DISABLE_IPV6:-n}" != 'y' ]]; then
		load_openvpn_tcp6_ports
		if [[ -n "$OPENVPN_TCP6_PORTS" ]]; then
			ipset create antizapret-openvpn-scanner6 hash:ip family inet6 timeout 86400 -exist
			# u32 ниже считает TCP сразу после IPv6. Необычные extension headers
			# запоминаем как тот же сканер; следующее set-правило сразу его отбросит.
			ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -p tcp -m multiport --dports "$OPENVPN_TCP6_PORTS" -m conntrack --ctstate ESTABLISHED -m ipv6header ! --header prot -m comment --comment antizapret-openvpn-scanner6-extension-detect -j SET --add-set antizapret-openvpn-scanner6 src --exist --timeout 86400
			ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -p tcp -m multiport --dports "$OPENVPN_TCP6_PORTS" -m conntrack --ctstate ESTABLISHED -m u32 --u32 '52>>26&0x3C@40>>16&0xFFFF=0x1603' -m comment --comment antizapret-openvpn-scanner6-detect -j SET --add-set antizapret-openvpn-scanner6 src --exist --timeout 86400
			ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -p tcp -m multiport --dports "$OPENVPN_TCP6_PORTS" -m set --match-set antizapret-openvpn-scanner6 src -m comment --comment antizapret-openvpn-scanner6-drop -j DROP
		fi
	fi
	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch6 src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-scan6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m conntrack --ctstate NEW -m set --match-set antizapret-block6 src -j DROP
	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m conntrack --ctstate NEW -j SET --add-set antizapret-watch6 src,dst --exist
}

add_scan_protection_for_ipv6_interface() {
	[[ "${SCAN_PROTECTION:-n}" == 'y' ]] || return 0
	[[ -n "$PUBLIC_INTERFACE6" ]] || return 0
	[[ "$PUBLIC_INTERFACE6" != "${DEFAULT_INTERFACE:-}" ]] || return 0

	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -p icmpv6 --icmpv6-type echo-request -j DROP
	ip6t -t filter -A "$OUTPUT_CHAIN" -o "$PUBLIC_INTERFACE6" -p tcp --tcp-flags RST RST -j DROP
	ip6t -t filter -A "$OUTPUT_CHAIN" -o "$PUBLIC_INTERFACE6" -p icmpv6 --icmpv6-type port-unreachable -j DROP
}

add_nat66() {
	local mark=$1 interface=$2 address="${3%%/*}"
	[[ -n "$interface" ]] || return 0
	if [[ -n "$address" ]]; then
		ip6t -t nat -A "$POSTROUTING_CHAIN" -m mark --mark "$mark" -o "$interface" -j SNAT --to-source "$address"
	else
		ip6t -t nat -A "$POSTROUTING_CHAIN" -m mark --mark "$mark" -o "$interface" -j MASQUERADE
	fi
}
