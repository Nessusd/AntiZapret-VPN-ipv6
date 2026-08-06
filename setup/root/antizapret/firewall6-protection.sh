add_attack_protection_for_ipv6_interface() {
	[[ "${ATTACK_PROTECTION:-n}" == 'y' ]] || return 0
	[[ -n "$PUBLIC_INTERFACE6" ]] || return 0
	[[ "$PUBLIC_INTERFACE6" != "${DEFAULT_INTERFACE:-}" ]] || return 0

	ipset create antizapret-block6 hash:ip family inet6 timeout 600 -exist
	ipset create antizapret-watch6 hash:ip,port family inet6 timeout 600 -exist
	ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m set --match-set antizapret-allow6 src -j ACCEPT
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
