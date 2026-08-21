#!/bin/bash
#
# Добавление/удаление клиента
#
# chmod +x client.sh && ./client.sh [1-9] [имя_клиента] [срок_действия_сертификата] [маршрутизируемый_IPv6-префикс] [static|bgp]
#
# Срок действия сертификата в днях - только для OpenVPN
#
set -e
export LC_ALL=C
shopt -s nullglob

handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

ARGUMENT_COUNT=$#
if (( ARGUMENT_COUNT > 5 )); then
	echo 'Too many parameters! Usage: ./client.sh [1-9] [client_name] [cert_expire_days] [routed_ipv6_prefix] [static|bgp]'
	exit 2
fi

SERVER_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
if [[ -z "$SERVER_IP" ]]; then
	echo 'Default IPv4 address not found!'
	exit 3
fi

export EASYRSA_PKI=/etc/openvpn/easyrsa3/pki
cd /root/antizapret
source setup
export DISABLE_IPV6 BGP_ENABLE
umask 022
OPTION="$1"
CLIENT_NAME="$2"
CLIENT_CERT_EXPIRE="$3"
CLIENT_IPV6_PREFIX="${4-}"
CLIENT_IPV6_PREFIX_SET=n
(( ARGUMENT_COUNT >= 4 )) && CLIENT_IPV6_PREFIX_SET=y
CLIENT_ROUTE_MODE="${5-}"
CLIENT_ROUTE_MODE_SET=n
(( ARGUMENT_COUNT == 5 )) && CLIENT_ROUTE_MODE_SET=y
if [[ "$OPTION" == '4' && "$ARGUMENT_COUNT" == '4' && "$CLIENT_IPV6_PREFIX" =~ ^(static|bgp)$ ]]; then
	CLIENT_ROUTE_MODE=$CLIENT_IPV6_PREFIX
	CLIENT_ROUTE_MODE_SET=y
	CLIENT_IPV6_PREFIX=
	CLIENT_IPV6_PREFIX_SET=n
fi
VPN_IPV6_PREFIX="${VPN_IPV6_PREFIX:-${WIREGUARD_IPV6_PREFIX:-fd3a:c9bc:6bcb::/48}}"
WIREGUARD_IPV6_PREFIX="$VPN_IPV6_PREFIX"
WIREGUARD_IPV6_HELPER="${WIREGUARD_IPV6_HELPER:-/root/antizapret/wireguard-ipv6.py}"
OPENVPN_IPV6_HELPER="${OPENVPN_IPV6_HELPER:-/root/antizapret/openvpn-ipv6.py}"
OPENVPN_LISTS_HELPER="${OPENVPN_LISTS_HELPER:-/root/antizapret/firewall6-lists.py}"

set_vpn_key_permissions() {
	local easyrsa_dir=$1
	local wireguard_dir=$2
	local pki_dir
	local private_dir

	# Some old backups contain the PKI both directly in easyrsa3 and in pki/.
	# Keep both layouts private while they pass through restore staging.
	for pki_dir in "$easyrsa_dir" "$easyrsa_dir/pki"; do
		for private_dir in \
			"$pki_dir/private" \
			"$pki_dir/inline" \
			"$pki_dir/renewed/private" \
			"$pki_dir/renewed/private_by_serial" \
			"$pki_dir/revoked/private" \
			"$pki_dir/revoked/private_by_serial"
		do
			[[ -d "$private_dir" ]] || continue
			find "$private_dir" -type d -exec chmod 700 {} + || return 1
			find "$private_dir" -type f -exec chmod 600 {} + || return 1
		done
		if [[ -d "$pki_dir" ]]; then
			find "$pki_dir" -maxdepth 1 -type f -name '*.creds' -exec chmod 600 {} + || return 1
		fi
	done
	if [[ -d "$wireguard_dir" ]]; then
		find "$wireguard_dir" -type d -exec chmod 700 {} + || return 1
		find "$wireguard_dir" -type f -exec chmod 600 {} + || return 1
	fi
}

require_vpn_key_permissions() {
	if ! set_vpn_key_permissions "$1" "$2"; then
		echo "Cannot secure VPN private keys under $1 or $2"
		exit 13
	fi
}

askClientName(){
	if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
		echo
		echo 'Enter client name: 1–32 alphanumeric characters (a-z, A-Z, 0-9) with underscore (_) or dash (-)'
		until [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; do
			read -rp 'Client name: ' -e CLIENT_NAME
		done
	fi
}

askClientCertExpire(){
	if ! [[ "$CLIENT_CERT_EXPIRE" =~ ^[0-9]+$ ]] || (( CLIENT_CERT_EXPIRE <= 0 )) || (( CLIENT_CERT_EXPIRE > 3650 )); then
		echo
		echo 'Enter client certificate expiration days (1-3650):'
		until [[ "$CLIENT_CERT_EXPIRE" =~ ^[0-9]+$ ]] && (( CLIENT_CERT_EXPIRE > 0 )) && (( CLIENT_CERT_EXPIRE <= 3650 )); do
			read -rp 'Certificate expiration days: ' -e -i 3650 CLIENT_CERT_EXPIRE
		done
	fi
}

askOpenVPNClientIPv6Prefix(){
	local current_prefix
	if [[ ! -f "$OPENVPN_LISTS_HELPER" ]]; then
		echo "OpenVPN lists helper not found: $OPENVPN_LISTS_HELPER"
		exit 11
	fi
	current_prefix="$(python3 "$OPENVPN_LISTS_HELPER" --get-client-prefix "$CLIENT_NAME")"
	echo
	echo 'Enter the global IPv6 prefix routed behind this OpenVPN client.'
	echo 'Leave empty for a phone, computer, or another endpoint device.'
	read -rp 'Routed IPv6 prefix (for example 2001:db8:1234::/64): ' -e -i "$current_prefix" CLIENT_IPV6_PREFIX
	CLIENT_IPV6_PREFIX_SET=y
}

validateClientRouteMode(){
	if [[ "$CLIENT_ROUTE_MODE" != 'static' && "$CLIENT_ROUTE_MODE" != 'bgp' ]]; then
		echo "Invalid route mode '$CLIENT_ROUTE_MODE'; use static or bgp"
		exit 12
	fi
	if [[ "$CLIENT_ROUTE_MODE" == 'bgp' && "${BGP_ENABLE:-n}" != 'y' ]]; then
		echo 'BGP route delivery is disabled in the AntiZapret setup'
		exit 12
	fi
}

askClientRouteMode(){
	local current_mode=${1:-static}
	if [[ "${BGP_ENABLE:-n}" != 'y' ]]; then
		CLIENT_ROUTE_MODE=static
		CLIENT_ROUTE_MODE_SET=y
		return
	fi
	echo
	echo 'Choose how this router receives AntiZapret routes: static or bgp.'
	echo 'Use static for endpoint devices and existing client configurations.'
	read -rp 'Route mode [static/bgp]: ' -e -i "$current_mode" CLIENT_ROUTE_MODE
	validateClientRouteMode
	CLIENT_ROUTE_MODE_SET=y
}

disconnectOpenVPNClient(){
	local socket
	for socket in \
		/run/openvpn-server/antizapret-udp.sock \
		/run/openvpn-server/antizapret-tcp.sock \
		/run/openvpn-server/vpn-udp.sock \
		/run/openvpn-server/vpn-tcp.sock
	do
		[[ -S "$socket" ]] || continue
		printf 'kill %s\n' "$CLIENT_NAME" | socat - UNIX-CONNECT:"$socket" &>/dev/null || true
	done
}

configureOpenVPNClientIPv6(){
	[[ "$CLIENT_IPV6_PREFIX_SET" == 'y' ]] || return 0
	if [[ ! -f "$OPENVPN_LISTS_HELPER" ]]; then
		echo "OpenVPN lists helper not found: $OPENVPN_LISTS_HELPER"
		exit 11
	fi
	case "$CLIENT_IPV6_PREFIX" in
		''|'-'|'none')
			python3 "$OPENVPN_LISTS_HELPER" --clear-client-prefix "$CLIENT_NAME"
			echo "OpenVPN client '$CLIENT_NAME' configured as an endpoint device"
			;;
		*)
			python3 "$OPENVPN_LISTS_HELPER" --set-client-prefix "$CLIENT_NAME" "$CLIENT_IPV6_PREFIX"
			echo "OpenVPN client '$CLIENT_NAME' configured as a router for $CLIENT_IPV6_PREFIX"
			if [[ "${OPENVPN_DCO:-n}" != 'y' ]]; then
				echo 'Warning: routed IPv6 prefixes require OpenVPN DCO for automatic kernel routes'
			fi
			;;
	esac
	disconnectOpenVPNClient
}

configureOpenVPNClientRouteMode(){
	[[ "$CLIENT_ROUTE_MODE_SET" == 'y' ]] || return 0
	validateClientRouteMode
	if [[ ! -f "$OPENVPN_LISTS_HELPER" ]]; then
		echo "OpenVPN lists helper not found: $OPENVPN_LISTS_HELPER"
		exit 11
	fi
	python3 "$OPENVPN_LISTS_HELPER" --set-client-route-mode "$CLIENT_NAME" "$CLIENT_ROUTE_MODE"
	echo "OpenVPN client '$CLIENT_NAME' route mode: $CLIENT_ROUTE_MODE"
	disconnectOpenVPNClient
}

setServerHost_FileName(){
	if [[ -z "$1" ]]; then
		SERVER_HOST="$SERVER_IP"
	else
		SERVER_HOST="$1"
	fi
	# OpenVPN expects an IPv6 literal without URI brackets.  WireGuard templates
	# prepare their Endpoint value separately.
	if [[ "$SERVER_HOST" == \[*\] ]]; then
		SERVER_HOST="${SERVER_HOST#[}"
		SERVER_HOST="${SERVER_HOST%]}"
	fi

	FILE_NAME="${CLIENT_NAME#antizapret-}"
	FILE_NAME="${FILE_NAME#vpn-}"
	FILE_NAME="${FILE_NAME}-(${SERVER_HOST//:/_})"
}

prepareWireGuardServerHost(){
	local ipv4

	WIREGUARD_SERVER_HOST="$SERVER_HOST"
	if [[ "${DISABLE_IPV6:-n}" == 'y' ]]; then
		# WireGuard has no udp4 switch. Pin the configured public hostname to
		# its A record so an added AAAA cannot break an IPv4-only installation.
		if [[ -n "${WIREGUARD_HOST:-}" ]]; then
			ipv4="$(getent ahostsv4 "$SERVER_HOST" 2>/dev/null | awk 'NF && $1 !~ /:/ && !seen[$1]++ { print $1; exit }')"
			if [[ -z "$ipv4" ]]; then
				echo "WireGuard/AmneziaWG endpoint $SERVER_HOST has no IPv4 address"
				exit 14
			fi
			WIREGUARD_SERVER_HOST="$ipv4"
		else
			WIREGUARD_SERVER_HOST="$SERVER_IP"
		fi
	elif [[ "$WIREGUARD_SERVER_HOST" == *:* ]]; then
		WIREGUARD_SERVER_HOST="[$WIREGUARD_SERVER_HOST]"
	fi
}

render() {
	local IFS=
	while read -r line; do
		while [[ "$line" =~ (\$\{[a-zA-Z_][a-zA-Z_0-9]*\}) ]]; do
			local LHS="${BASH_REMATCH[1]}"
			local RHS="$(eval echo "\"$LHS\"")"
			line="${line//$LHS/$RHS}"
		done
		echo "$line"
	done < "$1"
}

prepareWireGuardIPv6(){
	local route
	WIREGUARD_SERVER_IPV6=
	WIREGUARD_CLIENT_IPV6=
	WIREGUARD_IPV6_ROUTES=
	[[ "${DISABLE_IPV6:-n}" == 'y' ]] && return

	if [[ ! -f "$WIREGUARD_IPV6_HELPER" ]]; then
		echo "WireGuard IPv6 helper not found: $WIREGUARD_IPV6_HELPER"
		exit 9
	fi
	WIREGUARD_IPV6_NETWORK="$(python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" network "$1")"
	WIREGUARD_SERVER_IPV6=", $(python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" server-address "$1")"
	if [[ "$1" == 'vpn' ]]; then
		WIREGUARD_IPV6_ROUTES=', ::/0'
	else
		WIREGUARD_IPV6_ROUTES=", $WIREGUARD_IPV6_NETWORK"
		WIREGUARD_IPV6_ROUTES+=", $(python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" fake-network)"
		if [[ -f /root/antizapret/result/route-ips6.txt ]]; then
			while IFS= read -r route; do
				[[ -n "$route" ]] && WIREGUARD_IPV6_ROUTES+=", $route"
			done < /root/antizapret/result/route-ips6.txt
		fi
	fi
}

prepareWireGuardRouteMode(){
	local mode=${1:-static} client_base=10
	[[ "${ALTERNATIVE_CLIENT_IP:-n}" == 'y' ]] && client_base=172
	WIREGUARD_TABLE=
	WIREGUARD_CLIENT_PREFIX=32
	if [[ "$mode" == 'bgp' ]]; then
		WIREGUARD_ALLOWED_IPS='0.0.0.0/0'
		WIREGUARD_CLIENT_PREFIX=24
		if [[ "${DISABLE_IPV6:-n}" != 'y' ]]; then
			WIREGUARD_ALLOWED_IPS+=', ::/0'
			WIREGUARD_CLIENT_IPV6="${WIREGUARD_CLIENT_IPV6%/128}/64"
		fi
		WIREGUARD_TABLE='Table = off'
	else
		WIREGUARD_ALLOWED_IPS="$client_base.29.8.0/24${WIREGUARD_IPV6_ROUTES}${IPS}"
	fi
}

wireGuardRouteMode(){
	local block=$1 mode=static
	if grep -q '^# RouteMode = bgp$' <<< "$block"; then
		mode=bgp
	fi
	if [[ "$CLIENT_ROUTE_MODE_SET" == 'y' ]]; then
		validateClientRouteMode
		mode=$CLIENT_ROUTE_MODE
	fi
	if [[ "${BGP_ENABLE:-n}" != 'y' ]]; then
		mode=static
	fi
	echo "$mode"
}

setWireGuardRouteModeMarker(){
	local config=$1 mode=$2
	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs =/ {/^[#] RouteMode = /d;}" "$config"
	if [[ "$mode" == 'bgp' ]]; then
		sed -i "/^# Client = ${CLIENT_NAME}$/a# RouteMode = bgp" "$config"
	fi
}

setWireGuardClientIPv6(){
	WIREGUARD_CLIENT_IPV6=
	[[ "${DISABLE_IPV6:-n}" == 'y' ]] && return
	WIREGUARD_CLIENT_IPV6=", $(python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" client-address "$1" "$2")"
}

migrateWireGuardIPv6(){
	local mode config result server_address action=migrate
	[[ "${DISABLE_IPV6:-n}" == 'y' ]] && action=strip
	if [[ ! -f "$WIREGUARD_IPV6_HELPER" ]]; then
		echo "WireGuard IPv6 helper not found: $WIREGUARD_IPV6_HELPER"
		exit 9
	fi
	# Validate the whole pair before changing either configuration.
	for mode in antizapret vpn; do
		config="/etc/wireguard/$mode.conf"
		[[ -f "$config" ]] || continue
		python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" "$action" "$mode" "$config" --check >/dev/null
	done
	for mode in antizapret vpn; do
		config="/etc/wireguard/$mode.conf"
		[[ -f "$config" ]] || continue
		result="$(python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" "$action" "$mode" "$config")"
		[[ "$result" == 'updated' ]] || continue
		server_address="$(python3 "$WIREGUARD_IPV6_HELPER" --prefix "$WIREGUARD_IPV6_PREFIX" server-address "$mode")"
		if ip link show dev "$mode" &>/dev/null; then
			if [[ "$action" == 'migrate' ]]; then
				ip -6 address show dev "$mode" | grep -Fq "${server_address%/*}/" || ip -6 address add "$server_address" dev "$mode"
			else
				ip -6 address show dev "$mode" | grep -Fq "${server_address%/*}/" && ip -6 address del "$server_address" dev "$mode"
			fi
			wg syncconf "$mode" <(wg-quick strip "$mode" 2>/dev/null) &>/dev/null || true
		fi
	done
}

migrateOpenVPNIPv6(){
	local mode config action=migrate
	[[ "${DISABLE_IPV6:-n}" == 'y' ]] && action=strip
	if [[ ! -f "$OPENVPN_IPV6_HELPER" ]]; then
		echo "OpenVPN IPv6 helper not found: $OPENVPN_IPV6_HELPER"
		exit 10
	fi
	for mode in antizapret-udp antizapret-tcp vpn-udp vpn-tcp; do
		config="/etc/openvpn/server/$mode.conf"
		[[ -f "$config" ]] || continue
		python3 "$OPENVPN_IPV6_HELPER" --prefix "$VPN_IPV6_PREFIX" "$action" "$mode" "$config" --check >/dev/null
	done
	for mode in antizapret-udp antizapret-tcp vpn-udp vpn-tcp; do
		config="/etc/openvpn/server/$mode.conf"
		[[ -f "$config" ]] || continue
		python3 "$OPENVPN_IPV6_HELPER" --prefix "$VPN_IPV6_PREFIX" "$action" "$mode" "$config" >/dev/null
	done
}

prepareOpenVPNClientTransport(){
	if [[ "${DISABLE_IPV6:-n}" == 'y' ]]; then
		OPENVPN_UDP_PROTO=udp4
		OPENVPN_TCP_PROTO=tcp4
	else
		OPENVPN_UDP_PROTO=udp
		OPENVPN_TCP_PROTO=tcp
	fi
}

initOpenVPN(){
	mkdir -p /etc/openvpn/easyrsa3
	mkdir -p /etc/openvpn/server/ccd
	mkdir -p /etc/openvpn/server/ccd2
	mkdir -p /etc/openvpn/server/logs

	if [[ ! -f /etc/openvpn/easyrsa3/pki/ca.crt ]] || \
	   [[ ! -f /etc/openvpn/easyrsa3/pki/issued/antizapret-server.crt ]] || \
	   [[ ! -f /etc/openvpn/easyrsa3/pki/private/antizapret-server.key ]]; then
		rm -rf /etc/openvpn/easyrsa3/pki
		/usr/share/easy-rsa/easyrsa init-pki
		EASYRSA_CA_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch --req-cn='AntiZapret CA' build-ca nopass
		EASYRSA_CERT_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch build-server-full 'antizapret-server' nopass
	fi

	migrateOpenVPNIPv6

	EASYRSA_CRL_DAYS=3650 /usr/share/easy-rsa/easyrsa gen-crl
	chmod 644 /etc/openvpn/easyrsa3/pki/crl.pem
	require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard
}

addOpenVPN(){
	setServerHost_FileName "$OPENVPN_HOST"
	prepareOpenVPNClientTransport

	if [[ ! -f /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt ]] || \
	   [[ ! -f /etc/openvpn/easyrsa3/pki/private/"$CLIENT_NAME".key ]]; then
		askClientCertExpire
		echo
		EASYRSA_CERT_EXPIRE="$CLIENT_CERT_EXPIRE" /usr/share/easy-rsa/easyrsa --batch build-client-full "$CLIENT_NAME" nopass
	else
		echo
		echo 'Client with that name already exists! Please enter different name for new client'
		echo
		if [[ "$CLIENT_CERT_EXPIRE" != "0" ]]; then
			echo 'Current client certificate expiration period:'
			openssl x509 -in /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt -noout -dates
			echo
			echo "Attention! Certificate renewal is NOT possible after 'notAfter' date"
			askClientCertExpire
			echo
			rm -f /etc/openvpn/easyrsa3/pki/issued/"$CLIENT_NAME".crt
			/usr/share/easy-rsa/easyrsa --batch --days="$CLIENT_CERT_EXPIRE" sign client "$CLIENT_NAME"
		fi
	fi

	CA_CERT="$(grep -A 999 'BEGIN CERTIFICATE' -- "/etc/openvpn/easyrsa3/pki/ca.crt")"
	CLIENT_CERT="$(grep -A 999 'BEGIN CERTIFICATE' -- "/etc/openvpn/easyrsa3/pki/issued/$CLIENT_NAME.crt")"
	CLIENT_KEY="$(cat -- "/etc/openvpn/easyrsa3/pki/private/$CLIENT_NAME.key")"
	if [[ ! "$CA_CERT" ]] || [[ ! "$CLIENT_CERT" ]] || [[ ! "$CLIENT_KEY" ]]; then
		echo 'Cannot load client keys!'
		exit 4
	fi

	configureOpenVPNClientRouteMode
	configureOpenVPNClientIPv6

	render "/etc/openvpn/client/templates/antizapret-udp.conf" > "/root/antizapret/client/openvpn/antizapret-udp/antizapret-$FILE_NAME-udp.ovpn"
	render "/etc/openvpn/client/templates/antizapret-tcp.conf" > "/root/antizapret/client/openvpn/antizapret-tcp/antizapret-$FILE_NAME-tcp.ovpn"
	render "/etc/openvpn/client/templates/antizapret.conf" > "/root/antizapret/client/openvpn/antizapret/antizapret-$FILE_NAME.ovpn"
	render "/etc/openvpn/client/templates/vpn-udp.conf" > "/root/antizapret/client/openvpn/vpn-udp/vpn-$FILE_NAME-udp.ovpn"
	render "/etc/openvpn/client/templates/vpn-tcp.conf" > "/root/antizapret/client/openvpn/vpn-tcp/vpn-$FILE_NAME-tcp.ovpn"
	render "/etc/openvpn/client/templates/vpn.conf" > "/root/antizapret/client/openvpn/vpn/vpn-$FILE_NAME.ovpn"

	echo "OpenVPN profile files (re)created for client '$CLIENT_NAME' at /root/antizapret/client/openvpn"
}

deleteOpenVPN(){
	setServerHost_FileName "$OPENVPN_HOST"
	echo

	/usr/share/easy-rsa/easyrsa --batch revoke "$CLIENT_NAME"
	EASYRSA_CRL_DAYS=3650 /usr/share/easy-rsa/easyrsa gen-crl
	chmod 644 /etc/openvpn/easyrsa3/pki/crl.pem

	rm -f /root/antizapret/client/openvpn/antizapret/antizapret-"$FILE_NAME".ovpn
	rm -f /root/antizapret/client/openvpn/antizapret-udp/antizapret-"$FILE_NAME"-udp.ovpn
	rm -f /root/antizapret/client/openvpn/antizapret-tcp/antizapret-"$FILE_NAME"-tcp.ovpn
	rm -f /root/antizapret/client/openvpn/vpn/vpn-"$FILE_NAME".ovpn
	rm -f /root/antizapret/client/openvpn/vpn-udp/vpn-"$FILE_NAME"-udp.ovpn
	rm -f /root/antizapret/client/openvpn/vpn-tcp/vpn-"$FILE_NAME"-tcp.ovpn
	if [[ -f "$OPENVPN_LISTS_HELPER" ]]; then
		python3 "$OPENVPN_LISTS_HELPER" --delete-client-config "$CLIENT_NAME"
	else
		rm -f "/etc/openvpn/server/ccd/$CLIENT_NAME" "/etc/openvpn/server/ccd2/$CLIENT_NAME"
	fi

	disconnectOpenVPNClient

	echo "OpenVPN client '$CLIENT_NAME' successfully deleted"
}

listOpenVPN(){
	[[ -n "$CLIENT_NAME" ]] && return
	echo
	echo 'OpenVPN client names:'
	ls /etc/openvpn/easyrsa3/pki/issued | sed 's/\.crt$//' | grep -v "^antizapret-server$" | sort
}

initWireGuard(){
	prepareWireGuardIPv6 antizapret
	if [[ ! -f /etc/wireguard/key ]]; then
		echo
		echo 'Generating WireGuard/AmneziaWG server keys'
		PRIVATE_KEY="$(wg genkey)"
		PUBLIC_KEY="$(echo "${PRIVATE_KEY}" | wg pubkey)"
		echo "PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}" > /etc/wireguard/key
		render "/etc/wireguard/templates/antizapret.conf" > "/etc/wireguard/antizapret.conf"
		prepareWireGuardIPv6 vpn
		render "/etc/wireguard/templates/vpn.conf" > "/etc/wireguard/vpn.conf"
	fi
	migrateWireGuardIPv6
	require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard
}

addWireGuard(){
	setServerHost_FileName "$WIREGUARD_HOST"
	prepareWireGuardServerHost
	echo
	migrateWireGuardIPv6

	source /etc/wireguard/key
	IPS="$(cat /etc/wireguard/ips)"

	# AntiZapret

	CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/antizapret.conf)"
	WIREGUARD_ROUTE_MODE="$(wireGuardRouteMode "$CLIENT_BLOCK")"

	if [[ -n "$CLIENT_BLOCK" ]]; then
		CLIENT_PRIVATE_KEY="$(echo "$CLIENT_BLOCK" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PUBLIC_KEY="$(echo "$CLIENT_BLOCK" | grep 'PublicKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PRESHARED_KEY="$(echo "$CLIENT_BLOCK" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_IP="$(echo "$CLIENT_BLOCK" | grep 'AllowedIPs =' | cut -d '=' -f 2- | sed 's/ //g' | cut -d ',' -f 1 | cut -d '/' -f 1)"
		echo 'Client (AntiZapret) with that name already exists! Please enter different name for new client'
	else
		CLIENT_PRIVATE_KEY="$(wg genkey)"
		CLIENT_PUBLIC_KEY="$(echo "${CLIENT_PRIVATE_KEY}" | wg pubkey)"
		CLIENT_PRESHARED_KEY="$(wg genpsk)"
		BASE_CLIENT_IP="$(grep "^Address" /etc/wireguard/antizapret.conf | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)"
		for i in {2..255}; do
			CLIENT_IP="${BASE_CLIENT_IP}.$i"
			if ! grep -q "$CLIENT_IP" /etc/wireguard/antizapret.conf; then
				break
			fi
			if [[ "$i" == 255 ]]; then
				echo 'The WireGuard/AmneziaWG subnet can support only 253 clients!'
				exit 5
			fi
		done
		setWireGuardClientIPv6 antizapret "$CLIENT_IP"
		{
			echo "# Client = ${CLIENT_NAME}"
			[[ "$WIREGUARD_ROUTE_MODE" == 'bgp' ]] && echo '# RouteMode = bgp'
			echo "# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32${WIREGUARD_CLIENT_IPV6}
"
		} >> "/etc/wireguard/antizapret.conf"
		wg syncconf antizapret <(wg-quick strip antizapret 2>/dev/null) &>/dev/null || true
	fi
	setWireGuardRouteModeMarker /etc/wireguard/antizapret.conf "$WIREGUARD_ROUTE_MODE"

	prepareWireGuardIPv6 antizapret
	setWireGuardClientIPv6 antizapret "$CLIENT_IP"
	prepareWireGuardRouteMode "$WIREGUARD_ROUTE_MODE"
	render "/etc/wireguard/templates/antizapret-client-wg.conf" > "/root/antizapret/client/wireguard/antizapret/antizapret-$FILE_NAME-wg.conf"
	render "/etc/wireguard/templates/antizapret-client-am.conf" > "/root/antizapret/client/amneziawg/antizapret/antizapret-$FILE_NAME-am.conf"

	# VPN

	CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/vpn.conf)"
	if [[ -n "$CLIENT_BLOCK" ]]; then
		CLIENT_PRIVATE_KEY="$(echo "$CLIENT_BLOCK" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PUBLIC_KEY="$(echo "$CLIENT_BLOCK" | grep 'PublicKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_PRESHARED_KEY="$(echo "$CLIENT_BLOCK" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')"
		CLIENT_IP="$(echo "$CLIENT_BLOCK" | grep 'AllowedIPs =' | cut -d '=' -f 2- | sed 's/ //g' | cut -d ',' -f 1 | cut -d '/' -f 1)"
		echo 'Client (VPN) with that name already exists! Please enter different name for new client'
	else
		CLIENT_PRIVATE_KEY="$(wg genkey)"
		CLIENT_PUBLIC_KEY="$(echo "${CLIENT_PRIVATE_KEY}" | wg pubkey)"
		CLIENT_PRESHARED_KEY="$(wg genpsk)"
		BASE_CLIENT_IP="$(grep "^Address" /etc/wireguard/vpn.conf | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)"
		for i in {2..255}; do
			CLIENT_IP="${BASE_CLIENT_IP}.$i"
			if ! grep -q "$CLIENT_IP" /etc/wireguard/vpn.conf; then
				break
			fi
			if [[ "$i" == 255 ]]; then
				echo 'The WireGuard/AmneziaWG subnet can support only 253 clients!'
				exit 6
			fi
		done
		setWireGuardClientIPv6 vpn "$CLIENT_IP"
		echo "# Client = ${CLIENT_NAME}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32${WIREGUARD_CLIENT_IPV6}
" >> "/etc/wireguard/vpn.conf"
		wg syncconf vpn <(wg-quick strip vpn 2>/dev/null) &>/dev/null || true
	fi

	prepareWireGuardIPv6 vpn
	setWireGuardClientIPv6 vpn "$CLIENT_IP"
	render "/etc/wireguard/templates/vpn-client-wg.conf" > "/root/antizapret/client/wireguard/vpn/vpn-$FILE_NAME-wg.conf"
	render "/etc/wireguard/templates/vpn-client-am.conf" > "/root/antizapret/client/amneziawg/vpn/vpn-$FILE_NAME-am.conf"

	echo "WireGuard/AmneziaWG profile files (re)created for client '$CLIENT_NAME' at /root/antizapret/client/wireguard and /root/antizapret/client/amneziawg"
	echo
	echo 'Attention! If import fails, shorten profile filename to 32 chars (Windows) or 15 (Linux/Android/iOS), remove parentheses'
}

deleteWireGuard(){
	setServerHost_FileName "$WIREGUARD_HOST"
	echo

	if ! grep -q "# Client = ${CLIENT_NAME}" "/etc/wireguard/antizapret.conf" && ! grep -q "# Client = ${CLIENT_NAME}" "/etc/wireguard/vpn.conf"; then
		echo "Failed to delete client '$CLIENT_NAME'! Please check if client exists"
		exit 7
	fi

	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/d" /etc/wireguard/antizapret.conf
	sed -i "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/d" /etc/wireguard/vpn.conf

	sed -i '/^$/N;/^\n$/D' /etc/wireguard/antizapret.conf
	sed -i '/^$/N;/^\n$/D' /etc/wireguard/vpn.conf

	rm -f /root/antizapret/client/{wireguard,amneziawg}/antizapret/antizapret-"$FILE_NAME"-*.conf
	rm -f /root/antizapret/client/{wireguard,amneziawg}/vpn/vpn-"$FILE_NAME"-*.conf

	wg syncconf antizapret <(wg-quick strip antizapret 2>/dev/null) &>/dev/null || true
	wg syncconf vpn <(wg-quick strip vpn 2>/dev/null) &>/dev/null || true

	echo "WireGuard/AmneziaWG client '$CLIENT_NAME' successfully deleted"
}

listWireGuard(){
	[[ -n "$CLIENT_NAME" ]] && return
	echo
	echo 'WireGuard/AmneziaWG client names:'
	grep -hE "^# Client" /etc/wireguard/antizapret.conf /etc/wireguard/vpn.conf | cut -d '=' -f 2 | sed 's/ //g' | sort -u
}

recreate(){
	echo

	rm -rf /root/antizapret/client
	mkdir -p /root/antizapret/client/{openvpn/{antizapret,antizapret-tcp,antizapret-udp,vpn,vpn-tcp,vpn-udp},wireguard/{antizapret,vpn},amneziawg/{antizapret,vpn}}

	# OpenVPN
	if [[ -d /etc/openvpn/easyrsa3/pki/issued ]]; then
		initOpenVPN
		CLIENT_CERT_EXPIRE=0
		ls /etc/openvpn/easyrsa3/pki/issued | sed 's/\.crt$//' | grep -v "^antizapret-server$" | sort | while read -r CLIENT_NAME; do
			if [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
				addOpenVPN >/dev/null
				echo "OpenVPN profile files recreated for client '$CLIENT_NAME'"
			else
				echo "OpenVPN client name '$CLIENT_NAME' is invalid! No profile files recreated"
			fi
		done
	else
		CLIENT_NAME=antizapret-client
		CLIENT_CERT_EXPIRE=3650
		echo "Creating OpenVPN server keys and first OpenVPN client: '$CLIENT_NAME'"
		initOpenVPN
		addOpenVPN >/dev/null
	fi

	# WireGuard/AmneziaWG
	if [[ -f /etc/wireguard/key && -f /etc/wireguard/antizapret.conf && -f /etc/wireguard/vpn.conf ]]; then
		grep -hE "^# Client" /etc/wireguard/antizapret.conf /etc/wireguard/vpn.conf | cut -d '=' -f 2 | sed 's/ //g' | sort -u | while read -r CLIENT_NAME; do
			if [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
				addWireGuard >/dev/null
				echo "WireGuard/AmneziaWG profile files recreated for client '$CLIENT_NAME'"
			else
				echo "WireGuard/AmneziaWG client name '$CLIENT_NAME' is invalid! No profile files recreated"
			fi
		done
	else
		CLIENT_NAME=antizapret-client
		echo "Creating WireGuard/AmneziaWG server keys and first WireGuard/AmneziaWG client: '$CLIENT_NAME'"
		initWireGuard
		addWireGuard >/dev/null
	fi
	require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard
}

create_backup_archive(){
	local backup_file=$1
	local backup_source=$2
	local backup_tmp

	backup_tmp="$(mktemp "${backup_file}.tmp.XXXXXX")" || return 1
	if ! (umask 077; tar -czf "$backup_tmp" -C "$backup_source" easyrsa3 openvpn-ccd wireguard config knot-resolver custom) || \
	   ! tar -tzf "$backup_tmp" >/dev/null; then
		rm -f -- "$backup_tmp"
		return 1
	fi
	if ! chmod 600 "$backup_tmp" || ! mv -f -- "$backup_tmp" "$backup_file"; then
		rm -f -- "$backup_tmp"
		return 1
	fi
}

backup(){
	echo
	require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard

	rm -rf /root/antizapret/backup
	mkdir -p /root/antizapret/backup/wireguard
	mkdir -p /root/antizapret/backup/config
	mkdir -p /root/antizapret/backup/knot-resolver
	mkdir -p /root/antizapret/backup/custom
	mkdir -p /root/antizapret/backup/openvpn-ccd/ccd
	mkdir -p /root/antizapret/backup/openvpn-ccd/ccd2

	cp -a -- /etc/openvpn/easyrsa3 /root/antizapret/backup/
	find /etc/openvpn/server/ccd -maxdepth 1 -type f ! -name DEFAULT -exec cp -a -t /root/antizapret/backup/openvpn-ccd/ccd -- {} +
	find /etc/openvpn/server/ccd2 -maxdepth 1 -type f ! -name DEFAULT -exec cp -a -t /root/antizapret/backup/openvpn-ccd/ccd2 -- {} +
	cp -a -- /etc/wireguard/antizapret.conf /root/antizapret/backup/wireguard/
	cp -a -- /etc/wireguard/vpn.conf /root/antizapret/backup/wireguard/
	cp -a -- /etc/wireguard/key /root/antizapret/backup/wireguard/
	cp -r /root/antizapret/config/*.txt /root/antizapret/backup/config || true
	cp -r /etc/knot-resolver/*.lua /root/antizapret/backup/knot-resolver || true
	cp -r /root/antizapret/custom*.sh /root/antizapret/backup/custom || true

	BACKUP_FILE="/root/antizapret/backup-$SERVER_IP.tar.gz"
	if ! create_backup_archive "$BACKUP_FILE" /root/antizapret/backup; then
		rm -rf /root/antizapret/backup
		echo 'Cannot create a valid backup archive'
		return 1
	fi

	rm -rf /root/antizapret/backup

	echo "Backup configuration and clients (re)created at $BACKUP_FILE"
}

restore(){
	echo

	local backup_archives=(/root/backup*.tar.gz)
	local backup_archive=
	local restore_root=/root
	local restore_staging=
	if (( ${#backup_archives[@]} > 1 )); then
		echo 'Multiple backup*.tar.gz archives found in /root. Leave exactly one archive:'
		printf '  %s\n' "${backup_archives[@]}"
		exit 8
	fi
	if (( ${#backup_archives[@]} == 1 )); then
		backup_archive="${backup_archives[0]}"
		if ! tar -tzf "$backup_archive" >/dev/null; then
			echo "Invalid or unreadable backup archive: $backup_archive"
			exit 8
		fi
		restore_staging="$(mktemp -d /tmp/antizapret-restore.XXXXXX)"
		trap '[[ -z "${restore_staging:-}" ]] || rm -rf -- "$restore_staging"' EXIT
		if ! tar -xzf "$backup_archive" -C "$restore_staging" --no-same-owner --no-same-permissions; then
			rm -rf -- "$restore_staging"
			restore_staging=
			echo "Cannot extract backup archive: $backup_archive"
			exit 8
		fi
		restore_root="$restore_staging"
	fi

	require_vpn_key_permissions "$restore_root/easyrsa3" "$restore_root/wireguard"
	if [[ ! -d "$restore_root/easyrsa3" && ! -d "$restore_root/openvpn-ccd" && ! -d "$restore_root/wireguard" && ! -d "$restore_root/config" && ! -d "$restore_root/knot-resolver" && ! -d "$restore_root/custom" ]]; then
		if [[ -n "$restore_staging" ]]; then
			rm -rf -- "$restore_staging"
			restore_staging=
		fi
		echo 'Backup not found! Upload backup*.tar.gz to /root, or extract folders to /root: easyrsa3, openvpn-ccd, wireguard, config, knot-resolver, custom'
		exit 8
	fi

	if [[ -d "$restore_root/easyrsa3/pki" ]]; then
		rm -rf /etc/openvpn/easyrsa3/*
	fi

	mkdir -p /etc/openvpn/server/ccd /etc/openvpn/server/ccd2
	if [[ -d "$restore_root/easyrsa3" ]]; then
		cp -a "$restore_root/easyrsa3/." /etc/openvpn/easyrsa3/
	fi
	if [[ -d "$restore_root/openvpn-ccd/ccd" ]]; then
		cp -a "$restore_root/openvpn-ccd/ccd/." /etc/openvpn/server/ccd/
	fi
	if [[ -d "$restore_root/openvpn-ccd/ccd2" ]]; then
		cp -a "$restore_root/openvpn-ccd/ccd2/." /etc/openvpn/server/ccd2/
	fi
	if [[ -d "$restore_root/wireguard" ]]; then
		cp -a "$restore_root/wireguard/." /etc/wireguard/
	fi
	if [[ -d "$restore_root/config" ]]; then
		cp -a "$restore_root/config/." /root/antizapret/config/
	fi
	if [[ -d "$restore_root/knot-resolver" ]]; then
		cp -a "$restore_root/knot-resolver/." /etc/knot-resolver/
	fi
	if [[ -d "$restore_root/custom" ]]; then
		cp -a "$restore_root/custom/." /root/antizapret/
	fi
	require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard

	# После успешного копирования удаляем и заранее распакованные источники.
	# Иначе следующий запуск без архива может принять их за актуальный backup.
	rm -rf /root/easyrsa3
	rm -rf /root/wireguard
	rm -rf /root/config
	rm -rf /root/knot-resolver
	rm -rf /root/custom
	rm -rf /root/openvpn-ccd
	if [[ "$restore_root" != /root ]]; then
		rm -rf -- "$restore_staging"
		restore_staging=
		trap - EXIT
	fi

	./doall.sh ip
	initWireGuard
	initOpenVPN
	recreate
	[[ -n "$backup_archive" ]] && rm -f -- "$backup_archive"

	echo "Configuration and clients restored from backup"
	echo 'Rebooting...'
	reboot -f
}

if ! [[ "$OPTION" =~ ^[1-9]$ ]]; then
	echo
	echo 'Please choose option:'
	echo '    1) OpenVPN - Add client/Renew client certificate'
	echo '    2) OpenVPN - Delete client'
	echo '    3) OpenVPN - List clients'
	echo '    4) WireGuard/AmneziaWG - Add client'
	echo '    5) WireGuard/AmneziaWG - Delete client'
	echo '    6) WireGuard/AmneziaWG - List clients'
	echo '    7) (Re)create client profile files'
	echo '    8) Backup configuration and clients'
	echo '    9) Restore configuration and clients from backup'
	until [[ "$OPTION" =~ ^[1-9]$ ]]; do
		read -rp 'Option choice [1-9]: ' -e OPTION
	done
fi

case "$OPTION" in
	1)
		echo "OpenVPN - Add client/Renew client certificate $CLIENT_NAME $CLIENT_CERT_EXPIRE"
		askClientName
		initOpenVPN
		if [[ "$CLIENT_IPV6_PREFIX_SET" != 'y' && -t 0 ]]; then
			askOpenVPNClientIPv6Prefix
		fi
		if [[ "$CLIENT_ROUTE_MODE_SET" != 'y' && -t 0 ]]; then
			CURRENT_ROUTE_MODE="$(python3 "$OPENVPN_LISTS_HELPER" --get-client-route-mode "$CLIENT_NAME")"
			askClientRouteMode "$CURRENT_ROUTE_MODE"
		fi
		addOpenVPN
		;;
	2)
		echo "OpenVPN - Delete client $CLIENT_NAME"
		listOpenVPN
		askClientName
		deleteOpenVPN
		;;
	3)
		echo 'OpenVPN - List clients'
		listOpenVPN
		;;
	4)
		echo "WireGuard/AmneziaWG - Add client $CLIENT_NAME"
		askClientName
		initWireGuard
		if [[ "$CLIENT_ROUTE_MODE_SET" != 'y' && -t 0 ]]; then
			CLIENT_BLOCK="$(sed -n "/^# Client = ${CLIENT_NAME}$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/antizapret.conf)"
			CURRENT_ROUTE_MODE="$(wireGuardRouteMode "$CLIENT_BLOCK")"
			askClientRouteMode "$CURRENT_ROUTE_MODE"
		fi
		addWireGuard
		;;
	5)
		echo "WireGuard/AmneziaWG - Delete client $CLIENT_NAME"
		listWireGuard
		askClientName
		deleteWireGuard
		;;
	6)
		echo 'WireGuard/AmneziaWG - List clients'
		listWireGuard
		;;
	7)
		echo '(Re)create client profile files'
		recreate
		;;
	8)
		echo 'Backup configuration and clients'
		backup
		;;
	9)
		echo 'Restore configuration and clients from backup'
		restore
		;;
esac
exit 0
