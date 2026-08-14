#!/bin/bash
set -e

SECONDS=0
ROOT_DIR="${ANTIZAPRET_ROOT:-/root/antizapret}"
SYSTEMD_DIR="${ANTIZAPRET_SYSTEMD_DIR:-/etc/systemd/system}"
cd "$ROOT_DIR"
source setup
export DISABLE_IPV6 VPN_IPV6_PREFIX BGP_ENABLE

FIREWALL6_CHANGED=n
FIREWALL6_BASE=https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main
FIREWALL6_PROXY=https://api.codetabs.com/v1/proxy?quest=

sync_firewall6_file() {
	local relative=$1 destination=$2 mode=${3:-644}
	local link="$FIREWALL6_BASE/$relative" temporary="${destination}.tmp"
	mkdir -p "$(dirname "$destination")"
	if ! curl -fL --connect-timeout 30 "$link" -o "$temporary"; then
		if ! curl -fL --connect-timeout 30 "$FIREWALL6_PROXY$link" -o "$temporary"; then
			rm -f "$temporary"
			if [[ -f "$destination" ]]; then
				echo "Warning: failed to update $destination; keeping installed version"
				chmod "$mode" "$destination"
				return 0
			fi
			return 1
		fi
	fi
	if [[ -f "$destination" ]] && cmp -s "$temporary" "$destination"; then
		rm -f "$temporary"
	else
		mv -f "$temporary" "$destination"
		FIREWALL6_CHANGED=y
	fi
	chmod "$mode" "$destination"
}

sync_firewall6() {
	sync_firewall6_file setup/root/antizapret/firewall6.sh firewall6.sh 755
	sync_firewall6_file setup/root/antizapret/firewall6-protection.sh firewall6-protection.sh 755
	sync_firewall6_file setup/root/antizapret/firewall6-apply.sh firewall6-apply.sh 755
	sync_firewall6_file setup/root/antizapret/firewall6-lists.py firewall6-lists.py 755
	sync_firewall6_file setup/etc/systemd/system/antizapret.service.d/ipv6-firewall.conf "$SYSTEMD_DIR/antizapret.service.d/ipv6-firewall.conf" 644
	if [[ "${BGP_ENABLE:-n}" == 'y' ]]; then
		sync_firewall6_file setup/root/antizapret/bgp-update.py bgp-update.py 755
		sync_firewall6_file setup/root/antizapret/bgp-firewall.sh bgp-firewall.sh 755
		sync_firewall6_file setup/etc/systemd/system/antizapret-bgp.service "$SYSTEMD_DIR/antizapret-bgp.service" 644
	fi
	if [[ "$FIREWALL6_CHANGED" == 'y' ]]; then
		systemctl daemon-reload
	fi
}

sync_firewall6

[[ -d /etc/openvpn/server/logs ]] && find /etc/openvpn/server/logs -type f -size +100M -exec truncate -s 0 {} +
SUM1="$(sha256sum update.sh)"
cat update.sh | bash -s "$1"
SUM2="$(sha256sum update.sh)"
if [[ "$SUM1" != "$SUM2" ]]; then
	echo 'Restarting update.sh'
	cat update.sh | bash -s "$1"
fi
./parse.sh "$1"

if [[ "${DISABLE_IPV6:-n}" == 'y' ]]; then
	./firewall6-lists.py --disable-openvpn
fi

case "${1:-}" in
	''|ip|ips|noclear|noclean) IPV6_LIST_MODE=download ;;
	*) IPV6_LIST_MODE=auto ;;
esac

if systemctl is-active --quiet antizapret; then
	if [[ "$FIREWALL6_CHANGED" == 'y' ]] || ! ip6tables -w -t filter -S ANTIZAPRET6-INPUT &>/dev/null; then
		./firewall6.sh up "$IPV6_LIST_MODE"
	else
		./firewall6.sh refresh "$IPV6_LIST_MODE"
	fi
else
	./firewall6.sh refresh "$IPV6_LIST_MODE"
fi

if [[ "${BGP_ENABLE:-n}" == 'y' ]]; then
	./bgp-update.py
fi

./custom-doall.sh "$1" || true

echo "Execution time: $SECONDS seconds"
exit 0
