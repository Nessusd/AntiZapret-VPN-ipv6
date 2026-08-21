#!/bin/bash
#
# Включить/выключить DCO (Data Channel Offload) в OpenVPN 2.7
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
	local unit
	for unit in "${OPENVPN_SERVER_UNITS[@]}"; do
		if systemctl is-active --quiet "$unit"; then
			systemctl restart "$unit"
		fi
	done
}

VERSION="$(openvpn --version | head -n 1 | awk '{print $2}')"
if [[ ! "$VERSION" =~ ^2\.7 ]]; then
	echo 'Cannot turn on/off DCO because OpenVPN version 2.7 is required'
	exit 2
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
		echo -e "data-ciphers \"AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305:AES-128-CBC:AES-192-CBC:AES-256-CBC\"\ndisable-dco" >> "$f"
	done
	restart_managed_openvpn
	echo
	echo 'OpenVPN DCO turned OFF successfully!'
fi
exit 0
