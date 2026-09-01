firewall_up() {
	local list_mode="${1:-auto}"
	# Пересборка начинается с известного пустого состояния, а списки ipset
	# готовятся до подключения пользовательских цепочек к системным.
	firewall_down
	refresh_sets "$list_mode"

	ip6t -t filter -N "$INPUT_CHAIN"
	ip6t -t filter -N "$FORWARD_CHAIN"
	ip6t -t filter -N "$OUTPUT_CHAIN"
	ip6t -t mangle -N "$MARK_CHAIN"
	ip6t -t nat -N "$PREROUTING_CHAIN"
	ip6t -t nat -N "$POSTROUTING_CHAIN"
	ip6t -t nat -S "$MAPPING_CHAIN" &>/dev/null || ip6t -t nat -N "$MAPPING_CHAIN"
	insert_after_invalid INPUT "$INPUT_CHAIN"
	insert_after_invalid FORWARD "$FORWARD_CHAIN"
	insert_after_invalid OUTPUT "$OUTPUT_CHAIN"
	ip6t -t mangle -I PREROUTING 1 -j "$MARK_CHAIN"
	ip6t -t nat -I PREROUTING 1 -j "$PREROUTING_CHAIN"
	ip6t -t nat -I POSTROUTING 1 -j "$POSTROUTING_CHAIN"

	# Old installations receive firewall updates through doall.sh too.  Enable
	# DNS interception only after setup has installed and checked the matching
	# Knot Resolver configuration.
	if [[ -f "${DNS6_RUNTIME_MARKER:-$ROOT_DIR/state/dns6-ready}" ]]; then
		add_dns6_dnat "$ANTIZAPRET_UDP_IPV6_IN_INTERFACE" "$ANTIZAPRET_UDP_DNS6"
		add_dns6_dnat "$ANTIZAPRET_TCP_IPV6_IN_INTERFACE" "$ANTIZAPRET_TCP_DNS6"
		add_dns6_dnat "$ANTIZAPRET_WG_IPV6_IN_INTERFACE" "$ANTIZAPRET_WG_DNS6"
		if [[ "${VPN_DNS:-1}" == '1' ]]; then
			add_dns6_dnat "$VPN_UDP_IPV6_IN_INTERFACE" "$VPN_UDP_DNS6"
			add_dns6_dnat "$VPN_TCP_IPV6_IN_INTERFACE" "$VPN_TCP_DNS6"
			add_dns6_dnat "$VPN_WG_IPV6_IN_INTERFACE" "$VPN_WG_DNS6"
		fi
	fi
	ip6t -t nat -A "$PREROUTING_CHAIN" -i "$ANTIZAPRET_IPV6_IN_INTERFACE" -d "$FAKE_IPV6_NETWORK" -j "$MAPPING_CHAIN"

	if [[ -n "$PUBLIC_INTERFACE6" ]]; then
		ip6t -t filter -A "$INPUT_CHAIN" -i "$PUBLIC_INTERFACE6" -m set --match-set antizapret-deny6 src -j DROP
	fi
	# Keep the same effective order as the IPv4 rules: deny, scan, attack allow/block,
	# then client-to-server isolation.
	add_scan_protection_for_ipv6_interface
	add_attack_protection_for_ipv6_interface
	if [[ "${CLIENT_ISOLATION:-n}" == 'y' ]]; then
		for interface in "$ANTIZAPRET_IPV6_IN_INTERFACE" "$VPN_IPV6_IN_INTERFACE"; do
			ip6t -t filter -A "$INPUT_CHAIN" -i "$interface" -p tcp ! --dport 53 -j DROP
			ip6t -t filter -A "$INPUT_CHAIN" -i "$interface" -p udp ! --dport 53 -j DROP
		done
	fi

	if [[ "${TORRENT_GUARD:-n}" == 'y' ]]; then
		# Краткоживущий набор запоминает адрес клиента после обнаружения сигнатуры,
		# чтобы блокировать последующие пакеты того же соединения без повторного поиска.
		ipset create antizapret-torrent6 hash:ip family inet6 timeout 60 -exist
		ipset flush antizapret-torrent6
		ip6t -t filter -A "$FORWARD_CHAIN" -i "$VPN_IPV6_IN_INTERFACE" -p tcp -m string --string 'GET ' --algo kmp --to 100 -m string --string 'info_hash=' --algo bm -m string --string 'peer_id=' --algo bm -m string --string 'port=' --algo bm -j SET --add-set antizapret-torrent6 src --exist
		ip6t -t filter -A "$FORWARD_CHAIN" -i "$VPN_IPV6_IN_INTERFACE" -p udp -m string --string 'BitTorrent protocol' --algo kmp --to 100 -j SET --add-set antizapret-torrent6 src --exist
		ip6t -t filter -A "$FORWARD_CHAIN" -i "$VPN_IPV6_IN_INTERFACE" -p udp -m string --string 'd1:ad2:id20:' --algo kmp --to 100 -j SET --add-set antizapret-torrent6 src --exist
		ip6t -t filter -A "$FORWARD_CHAIN" -i "$VPN_IPV6_IN_INTERFACE" -m set --match-set antizapret-torrent6 src -j DROP
	fi

	if [[ "${RESTRICT_FORWARD:-n}" == 'y' ]]; then
		ip6t -t filter -A "$FORWARD_CHAIN" -i "$ANTIZAPRET_IPV6_IN_INTERFACE" -m conntrack ! --ctstate DNAT -m set ! --match-set antizapret-forward6 dst -j DROP
	fi
	ip6t -t filter -A "$FORWARD_CHAIN" -i "$ANTIZAPRET_IPV6_IN_INTERFACE" -m set --match-set antizapret-drop6 dst -j DROP
	ip6t -t filter -A "$FORWARD_CHAIN" -i "$VPN_IPV6_IN_INTERFACE" -m set --match-set antizapret-drop6 dst -j DROP

	if [[ "${CLIENT_ISOLATION:-n}" == 'y' ]]; then
		if [[ -n "$ANTIZAPRET_IPV6_OUT_INTERFACE" ]]; then
			ip6t -t filter -A "$FORWARD_CHAIN" ! -i "$ANTIZAPRET_IPV6_OUT_INTERFACE" -o "$ANTIZAPRET_IPV6_IN_INTERFACE" -j DROP
		fi
		if [[ -n "$VPN_IPV6_OUT_INTERFACE" ]]; then
			ip6t -t filter -A "$FORWARD_CHAIN" ! -i "$VPN_IPV6_OUT_INTERFACE" -o "$VPN_IPV6_IN_INTERFACE" -j DROP
		fi
	fi

	ip6t -t mangle -A "$MARK_CHAIN" -i "$ANTIZAPRET_IPV6_IN_INTERFACE" -j MARK --set-xmark "$ANTIZAPRET_MARK"
	ip6t -t mangle -A "$MARK_CHAIN" -i "$VPN_IPV6_IN_INTERFACE" -j MARK --set-xmark "$VPN_MARK"

	# Mirror the public IPv4 backup-port redirects on the IPv6 listener.
	# WireGuard and AmneziaWG use the same dual-stack UDP sockets.
	if [[ "${OPENVPN_TCP_ENABLE:-n}" == 'y' && "${OPENVPN_BACKUP_TCP:-n}" == 'y' ]]; then
		redirect_ports tcp 80:50080 443:50443 504:50443 508:50080
	fi
	if [[ "${OPENVPN_UDP_ENABLE:-n}" == 'y' && "${OPENVPN_BACKUP_UDP:-n}" == 'y' ]]; then
		redirect_ports udp 80:50080 443:50443 504:50443 508:50080
	fi
	if [[ "${WIREGUARD_ENABLE:-n}" == 'y' ]]; then
		[[ "${WIREGUARD_BACKUP:-n}" == 'y' ]] && redirect_ports udp 540:51443 580:51080
		redirect_ports udp 52080:51080 52443:51443
	fi

	# Метка выбирает независимый внешний канал для AntiZapret и полного VPN;
	# NAT66 применяется в самом конце после классификации входящего трафика.
	add_nat66 "$ANTIZAPRET_MARK" "$ANTIZAPRET_IPV6_OUT_INTERFACE" "$ANTIZAPRET_IPV6_OUT_IP"
	add_nat66 "$VPN_MARK" "$VPN_IPV6_OUT_INTERFACE" "$VPN_IPV6_OUT_IP"
	warn_without_global_ipv6 "$ANTIZAPRET_IPV6_OUT_INTERFACE"
	[[ "$VPN_IPV6_OUT_INTERFACE" == "$ANTIZAPRET_IPV6_OUT_INTERFACE" ]] || warn_without_global_ipv6 "$VPN_IPV6_OUT_INTERFACE"
}
