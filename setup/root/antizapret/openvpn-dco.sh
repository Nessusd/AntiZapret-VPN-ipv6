#!/bin/bash
#
# Включить/выключить DCO (Data Channel Offload) в установленной сборке OpenVPN.
#
# chmod +x openvpn-dco.sh && ./openvpn-dco.sh [y/n]
#
set -e
export LC_ALL=C

handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

OPENVPN_SERVER_CONFIGS=(
	/etc/openvpn/server/antizapret-udp.conf
	/etc/openvpn/server/vpn-udp.conf
	/etc/openvpn/server/antizapret-tcp.conf
	/etc/openvpn/server/vpn-tcp.conf
)
OPENVPN_SERVER_UNITS=(
	openvpn-server@antizapret-udp.service
	openvpn-server@vpn-udp.service
	openvpn-server@antizapret-tcp.service
	openvpn-server@vpn-tcp.service
)

restart_managed_openvpn() {
	local restarted=n unit
	for unit in "${OPENVPN_SERVER_UNITS[@]}"; do
		if systemctl is-active --quiet "$unit"; then
			systemctl restart "$unit"
			restarted=y
		fi
	done
	if [[ "$restarted" == 'y' ]] && systemctl is-active --quiet antizapret-bgp.service; then
		# BIRD binds its listeners to the current tunnel ifindex. OpenVPN creates
		# a new interface during restart, so BIRD must bind again afterwards.
		systemctl restart antizapret-bgp.service
	fi
}

openvpn_dco_kernel_module() {
	local version=$1
	case "$version" in
		2.6.*)
			# OpenVPN 2.6.0/2.6.1 использовали старый API, несовместимый с v2.
			[[ "$version" =~ ^2\.6\.([0-9]+)([._-]|$) ]] || return 1
			((10#${BASH_REMATCH[1]} >= 2)) || return 1
			echo ovpn_dco_v2
			;;
		2.7|2.7.*|2.7_*) echo ovpn ;;
		*) return 1 ;;
	esac
}

OPENVPN_VERSION_INFO="$(openvpn --version)"
VERSION="$(awk 'NR == 1 { print $2 }' <<< "$OPENVPN_VERSION_INFO")"
# OpenVPN штатно возвращает код 1 после вывода справки.
OPENVPN_HELP_STATUS=0
OPENVPN_HELP="$(openvpn --help)" || OPENVPN_HELP_STATUS=$?
if ((OPENVPN_HELP_STATUS > 1)); then
	echo 'Cannot turn on/off DCO because OpenVPN help is unavailable'
	exit 2
fi
if ! grep -qE -- '(^|[[:space:]])--data-ciphers([[:space:]]|$)' <<< "$OPENVPN_HELP"; then
	echo 'Cannot turn on/off DCO because this OpenVPN build does not support data-ciphers'
	exit 2
fi
DISABLE_DCO_SUPPORTED=n
if grep -qE -- '(^|[[:space:]])--disable-dco([[:space:]]|$)' <<< "$OPENVPN_HELP"; then
	DISABLE_DCO_SUPPORTED=y
fi

if [[ "$1" == [yn] ]]; then
	DCO="$1"
else
	echo
	echo 'OpenVPN DCO lowers CPU load, saves battery on mobile devices, boosts data speeds, and only supports AES-128-GCM, AES-256-GCM and CHACHA20-POLY1305 encryption protocols'
	until [[ "$DCO" =~ ^[yn]$ ]]; do
		read -rp 'Turn on OpenVPN DCO? [y/n]: ' -e -i y DCO
	done
fi

if [[ "$DCO" == 'y' ]]; then
	if [[ "$OPENVPN_VERSION_INFO" != *'[DCO]'* || "$DISABLE_DCO_SUPPORTED" != 'y' ]]; then
		echo 'Cannot turn on DCO because this OpenVPN build has no DCO support'
		exit 3
	fi
	# Для 2.6.2+ и 2.7 нужны разные модули; подменять один другим нельзя.
	if ! DCO_MODULE="$(openvpn_dco_kernel_module "$VERSION")"; then
		echo "Cannot turn on DCO because OpenVPN $VERSION has no known compatible kernel module (supported: 2.6.2+ within 2.6, or 2.7)"
		exit 2
	fi
	depmod -a
	if ! modprobe "$DCO_MODULE"; then
		echo "Cannot turn on DCO because the $DCO_MODULE kernel module is unavailable"
		exit 3
	fi
	for f in "${OPENVPN_SERVER_CONFIGS[@]}"; do
		[[ -f "$f" ]] || continue
		sed -i '/data-ciphers\|disable-dco/d' "$f"
		echo 'data-ciphers "AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305"' >> "$f"
	done
	restart_managed_openvpn
	echo
	echo 'OpenVPN DCO turned ON successfully!'
else
	for f in "${OPENVPN_SERVER_CONFIGS[@]}"; do
		[[ -f "$f" ]] || continue
		sed -i '/data-ciphers\|disable-dco/d' "$f"
		echo 'data-ciphers "AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305:AES-128-CBC:AES-192-CBC:AES-256-CBC"' >> "$f"
		# В OpenVPN 2.5 нет DCO и параметра disable-dco.
		if [[ "$DISABLE_DCO_SUPPORTED" == 'y' ]]; then
			echo 'disable-dco' >> "$f"
		fi
	done
	restart_managed_openvpn
	echo
	echo 'OpenVPN DCO turned OFF successfully!'
fi
exit 0
