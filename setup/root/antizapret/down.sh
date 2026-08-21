#!/bin/bash
exec 2>/dev/null

cd /root/antizapret

CUTOVER_HOOK_MARKER=/run/antizapret-setup.defer-custom-hooks
CUTOVER_HOOK_ENV=/run/antizapret-setup.custom-hook.env
CUTOVER_HOOK_LOCK=/run/antizapret-setup.custom-hook.lock
CUTOVER_LOCK=/run/antizapret-setup.lock
CUTOVER_RUN_CUSTOM_DOWN=y

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

write_cutover_hook_state() {
	local state=$1 temporary

	temporary="$(mktemp "${CUTOVER_HOOK_MARKER}.XXXXXX")" || return 1
	if ! printf '%s\n' "$state" > "$temporary" ||
		! chmod 600 "$temporary" ||
		! chown root:root "$temporary" ||
		! mv -f -- "$temporary" "$CUTOVER_HOOK_MARKER"
	then
		rm -f -- "$temporary"
		return 1
	fi
}

handle_cutover_hook_state() {
	local hook_state install_active=n lock_fd=

	[[ -f "$CUTOVER_HOOK_MARKER" ]] || return 0
	if ! exec {lock_fd}>> "$CUTOVER_HOOK_LOCK"; then
		echo 'Cannot open custom hook cutover lock' >&2
		return 1
	fi
	chmod 600 "$CUTOVER_HOOK_LOCK" || return 1
	flock "$lock_fd" || return 1

	# Marker мог убрать commit, пока ждали custom-up.
	if [[ ! -f "$CUTOVER_HOOK_MARKER" ]]; then
		exec {lock_fd}>&-
		return 0
	fi
	cutover_lock_active && install_active=y
	hook_state="$(< "$CUTOVER_HOOK_MARKER")"
	case "$hook_state" in
		applied)
			# custom-up был запущен. Во время установки фиксируем падение,
			# чтобы restart не спрятал его от проверки setup.
			if [[ "$install_active" == 'y' ]]; then
				write_cutover_hook_state stopped || return 1
				rm -f -- "$CUTOVER_HOOK_ENV"
			else
				rm -f -- "$CUTOVER_HOOK_MARKER" "$CUTOVER_HOOK_ENV" || return 1
			fi
			;;
		deferred|ready)
			CUTOVER_RUN_CUSTOM_DOWN=n
			if [[ "$hook_state" == 'deferred' &&
				"${ANTIZAPRET_INTERNAL_PRECLEANUP:-n}" == 'y' &&
				"$install_active" == 'y' ]]
			then
				# up.sh чистит старые правила до нового custom-up.
				:
			elif [[ "$install_active" == 'y' ]]; then
				# Unit остановлен до custom-up. Запрещаем поздний запуск hook
				# на уже мёртвом runtime.
				write_cutover_hook_state stopped || return 1
			else
				rm -f -- "$CUTOVER_HOOK_MARKER" "$CUTOVER_HOOK_ENV"
			fi
			;;
		stopped)
			CUTOVER_RUN_CUSTOM_DOWN=n
			if [[ "$install_active" != 'y' ]]; then
				rm -f -- "$CUTOVER_HOOK_MARKER" "$CUTOVER_HOOK_ENV"
			fi
			;;
		*)
			echo 'Invalid custom hook cutover state' >&2
			exec {lock_fd}>&-
			return 1
			;;
	esac
	exec {lock_fd}>&-
}

handle_cutover_hook_state || exit 1

source setup

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

WARP_ANTIZAPRET_INTERFACE=warp-antizapret
WARP_ANTIZAPRET_PATH="/etc/wireguard/$WARP_ANTIZAPRET_INTERFACE.conf"
WARP_ANTIZAPRET_IP=$(awk -F'= ' '/^Address/{split($2, addresses, ","); print addresses[1]; exit}' "$WARP_ANTIZAPRET_PATH")
WARP_ANTIZAPRET_IP="${WARP_ANTIZAPRET_IP%%/*}"
WARP_ANTIZAPRET_IP="${WARP_ANTIZAPRET_IP:-172.16.0.2}"

WARP_VPN_INTERFACE=warp-vpn
WARP_VPN_PATH="/etc/wireguard/$WARP_VPN_INTERFACE.conf"
WARP_VPN_IP=$(awk -F'= ' '/^Address/{split($2, addresses, ","); print addresses[1]; exit}' "$WARP_VPN_PATH")
WARP_VPN_IP="${WARP_VPN_IP%%/*}"
WARP_VPN_IP="${WARP_VPN_IP:-172.16.0.2}"

# filter
# INPUT connection tracking
iptables -w -D INPUT -m conntrack --ctstate INVALID -j DROP
ip6tables -w -D INPUT -m conntrack --ctstate INVALID -j DROP
# FORWARD connection tracking
iptables -w -D FORWARD -m conntrack --ctstate INVALID -j DROP
ip6tables -w -D FORWARD -m conntrack --ctstate INVALID -j DROP
# OUTPUT connection tracking
iptables -w -D OUTPUT -m conntrack --ctstate INVALID -j DROP
ip6tables -w -D OUTPUT -m conntrack --ctstate INVALID -j DROP
# Torrent guard
iptables -w -D FORWARD -s $IP.28.0.0/16 -p tcp -m string --string 'GET ' --algo kmp --to 100 -m string --string 'info_hash=' --algo bm -m string --string 'peer_id=' --algo bm -m string --string 'port=' --algo bm -j SET --add-set antizapret-torrent src --exist
iptables -w -D FORWARD -s $IP.28.0.0/16 -p udp -m string --string 'BitTorrent protocol' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
iptables -w -D FORWARD -s $IP.28.0.0/16 -p udp -m string --string 'd1:ad2:id20:' --algo kmp --to 100 -j SET --add-set antizapret-torrent src --exist
iptables -w -D FORWARD -s $IP.28.0.0/16 -m set --match-set antizapret-torrent src -j DROP
# Restrict forwarding
iptables -w -D FORWARD -s $IP.29.0.0/16 -m connmark --mark 0x1 -m set ! --match-set antizapret-forward dst -j DROP
# Drop forwarding
iptables -w -D FORWARD -s $IP.28.0.0/15 -m set --match-set antizapret-drop dst -j DROP
# Client and server isolation
iptables -w -D FORWARD ! -i $ANTIZAPRET_OUT_INTERFACE -d $IP.28.0.0/15 -j DROP
iptables -w -D FORWARD ! -i $ANTIZAPRET_OUT_INTERFACE -d $IP.29.0.0/16 -j DROP
iptables -w -D FORWARD ! -i $WARP_ANTIZAPRET_INTERFACE -d $IP.29.0.0/16 -j DROP
iptables -w -D FORWARD ! -i $VPN_OUT_INTERFACE -d $IP.28.0.0/16 -j DROP
iptables -w -D FORWARD ! -i $WARP_VPN_INTERFACE -d $IP.28.0.0/16 -j DROP
iptables -w -D INPUT -s $IP.28.0.0/15 -p tcp ! --dport 53 -j DROP
iptables -w -D INPUT -s $IP.28.0.0/15 -p udp ! --dport 53 -j DROP
# SSH protection
iptables -w -D INPUT -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-ssh --hashlimit-htable-expire 60000 -j DROP
ip6tables -w -D INPUT -p tcp --dport ssh -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 5/hour --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-ssh6 --hashlimit-htable-expire 60000 -j DROP
# Attack protection
iptables -w -D INPUT -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow src -j ACCEPT
# Новые правила помечены, поэтому удаляются независимо от текущих портов в
# OpenVPN-конфигурации. Следующие команды очищают старые варианты правил.
while OPENVPN_SCANNER_RULE_NUMBER="$(iptables -w -L INPUT --line-numbers -n | awk '/antizapret-openvpn-scanner/ { print $1; exit }')" && [[ -n "$OPENVPN_SCANNER_RULE_NUMBER" ]]; do
	iptables -w -D INPUT "$OPENVPN_SCANNER_RULE_NUMBER"
done
while OPENVPN_SCANNER_RULE_NUMBER6="$(ip6tables -w -L INPUT --line-numbers -n | awk '/antizapret-openvpn-scanner6/ { print $1; exit }')" && [[ -n "$OPENVPN_SCANNER_RULE_NUMBER6" ]]; do
	ip6tables -w -D INPUT "$OPENVPN_SCANNER_RULE_NUMBER6"
done
iptables -w -D INPUT -i $DEFAULT_INTERFACE -p tcp -m multiport --dports 50443,50080 -m conntrack --ctstate ESTABLISHED -m u32 --u32 '0>>22&0x3C@12>>26&0x3C@0>>16&0xFFFF=0x1603' -j SET --add-set antizapret-openvpn-scanner src --exist --timeout 86400
iptables -w -D INPUT -i $DEFAULT_INTERFACE -p tcp -m multiport --dports 50443,50080 -m conntrack --ctstate ESTABLISHED -m u32 --u32 '0>>22&0x3C@12>>26&0x3C@0>>16&0xFFFF=0x1603' -j SET --add-set antizapret-openvpn-scanner src --exist --timeout 3600
iptables -w -D INPUT -i $DEFAULT_INTERFACE -p tcp -m multiport --dports 50443,50080 -m conntrack --ctstate ESTABLISHED -m u32 --u32 '0>>22&0x3C@12>>26&0x3C@0>>16&0xFFFF=0x1603' -j SET --add-set antizapret-openvpn-scanner src --exist
iptables -w -D INPUT -i $DEFAULT_INTERFACE -p tcp -m multiport --dports 50443,50080 -m set --match-set antizapret-openvpn-scanner src -j DROP
if [[ "${ATTACK_PROTECTION:-n}" != 'y' || "${OPENVPN_TCP_ENABLE:-n}" != 'y' ]]; then
	ipset destroy antizapret-openvpn-scanner
	ipset destroy antizapret-openvpn-scanner6
fi
iptables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 24 --hashlimit-name antizapret-scan --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
iptables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block src --exist
iptables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block src -j DROP
iptables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch src,dst --exist
ip6tables -w -D INPUT -i $DEFAULT_INTERFACE -m set --match-set antizapret-allow6 src -j ACCEPT
ip6tables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set ! --match-set antizapret-watch6 src,dst -m hashlimit --hashlimit-above 20/hour --hashlimit-burst 20 --hashlimit-mode srcip --hashlimit-srcmask 64 --hashlimit-name antizapret-scan6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
ip6tables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 100000/hour --hashlimit-burst 100000 --hashlimit-mode srcip --hashlimit-name antizapret-ddos6 --hashlimit-htable-expire 600000 -j SET --add-set antizapret-block6 src --exist
ip6tables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -m set --match-set antizapret-block6 src -j DROP
ip6tables -w -D INPUT -i $DEFAULT_INTERFACE -m conntrack --ctstate NEW -j SET --add-set antizapret-watch6 src,dst --exist
# Scan protection
iptables -w -D INPUT -i $DEFAULT_INTERFACE -p icmp --icmp-type echo-request -j DROP
iptables -w -D OUTPUT -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
iptables -w -D OUTPUT -o $DEFAULT_INTERFACE -p icmp --icmp-type port-unreachable -j DROP
ip6tables -w -D INPUT -i $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type echo-request -j DROP
ip6tables -w -D OUTPUT -o $DEFAULT_INTERFACE -p tcp --tcp-flags RST RST -j DROP
ip6tables -w -D OUTPUT -o $DEFAULT_INTERFACE -p icmpv6 --icmpv6-type port-unreachable -j DROP
# Deny input
iptables -w -D INPUT -i $DEFAULT_INTERFACE -m set --match-set antizapret-deny src -j DROP

# mangle
# Clamp TCP MSS
iptables -w -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -w -t mangle -D OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -w -t mangle -D OUTPUT ! -o lo -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# raw
# NOTRACK loopback
iptables -w -t raw -D PREROUTING -i lo -j NOTRACK
iptables -w -t raw -D OUTPUT -o lo -j NOTRACK
ip6tables -w -t raw -D PREROUTING -i lo -j NOTRACK
ip6tables -w -t raw -D OUTPUT -o lo -j NOTRACK

# nat
# OpenVPN TCP port redirection for backup connections
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 80 -j REDIRECT --to-ports 50080
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 443 -j REDIRECT --to-ports 50443
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 504 -j REDIRECT --to-ports 50443
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p tcp --dport 508 -j REDIRECT --to-ports 50080
# OpenVPN UDP port redirection for backup connections
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 80 -j REDIRECT --to-ports 50080
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 443 -j REDIRECT --to-ports 50443
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 504 -j REDIRECT --to-ports 50443
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 508 -j REDIRECT --to-ports 50080
# WireGuard/AmneziaWG port redirection for backup connections
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 540 -j REDIRECT --to-ports 51443
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 580 -j REDIRECT --to-ports 51080
# AmneziaWG redirection ports to WireGuard
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52080 -j REDIRECT --to-ports 51080
iptables -w -t nat -D PREROUTING -i $DEFAULT_INTERFACE -p udp --dport 52443 -j REDIRECT --to-ports 51443
# AntiZapret DNS redirection to Knot Resolver
iptables -w -t nat -D PREROUTING -s $IP.29.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.1.1.1
iptables -w -t nat -D PREROUTING -s $IP.29.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.1.1.1
# VPN DNS redirection to Knot Resolver
iptables -w -t nat -D PREROUTING -s $IP.28.0.0/16 -p udp --dport 53 -j DNAT --to-destination 127.2.2.2
iptables -w -t nat -D PREROUTING -s $IP.28.0.0/16 -p tcp --dport 53 -j DNAT --to-destination 127.2.2.2
# Restrict forwarding
iptables -w -t nat -D PREROUTING -s $IP.29.0.0/16 ! -d $FAKE_IP.0.0/15 -j CONNMARK --set-mark 0x1
# Mapping fake IP to real IP
iptables -w -t nat -D PREROUTING -s $IP.29.0.0/16 -d $FAKE_IP.0.0/15 -j ANTIZAPRET-MAPPING
# SNAT/MASQUERADE VPN
iptables -w -t nat -D POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
iptables -w -t nat -D POSTROUTING -s $IP.28.0.0/15 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
iptables -w -t nat -D POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j MASQUERADE
iptables -w -t nat -D POSTROUTING -s $IP.29.0.0/16 -o $ANTIZAPRET_OUT_INTERFACE -j SNAT --to-source $ANTIZAPRET_OUT_IP
iptables -w -t nat -D POSTROUTING -s $IP.29.0.0/16 -o $WARP_ANTIZAPRET_INTERFACE -j MASQUERADE
iptables -w -t nat -D POSTROUTING -s $IP.29.0.0/16 -o $WARP_ANTIZAPRET_INTERFACE -j SNAT --to-source $WARP_ANTIZAPRET_IP
iptables -w -t nat -D POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j MASQUERADE
iptables -w -t nat -D POSTROUTING -s $IP.28.0.0/16 -o $VPN_OUT_INTERFACE -j SNAT --to-source $VPN_OUT_IP
iptables -w -t nat -D POSTROUTING -s $IP.28.0.0/16 -o $WARP_VPN_INTERFACE -j MASQUERADE
iptables -w -t nat -D POSTROUTING -s $IP.28.0.0/16 -o $WARP_VPN_INTERFACE -j SNAT --to-source $WARP_VPN_IP

# WARP AntiZapret
if [[ -f $WARP_ANTIZAPRET_PATH ]]; then
	wg-quick down $WARP_ANTIZAPRET_PATH
fi
if ip link show dev $WARP_ANTIZAPRET_INTERFACE &>/dev/null; then
	ip link delete dev $WARP_ANTIZAPRET_INTERFACE
fi

# WARP VPN
if [[ -f $WARP_VPN_PATH ]]; then
	wg-quick down $WARP_VPN_PATH
fi
if ip link show dev $WARP_VPN_INTERFACE &>/dev/null; then
	ip link delete dev $WARP_VPN_INTERFACE
fi

if [[ "$CUTOVER_RUN_CUSTOM_DOWN" == 'y' ]]; then
	./custom-down.sh
fi
exit 0
