#!/bin/bash
set -eu

state_file=/run/admin-antizapret-certbot-redirect.state
lock_file=/run/admin-antizapret-certbot-redirect.lock

exec 9>"$lock_file"
flock -x 9

[[ -f "$state_file" ]] || exit 0

read_state_value() {
	local key=$1
	sed -n "s/^${key}=//p" "$state_file" | tail -n 1
}

restore_redirects() {
	local tool=$1 chain=$2 interface=$3 count=$4 index
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	(( count == 0 )) && return 0
	[[ "$interface" =~ ^[[:alnum:]_.:@-]+$ ]] || return 1
	command -v "$tool" >/dev/null 2>&1 || return 1
	while "$tool" -w -t nat -C "$chain" -i "$interface" -p tcp \
		--dport 80 -j REDIRECT --to-ports 50080 2>/dev/null
	do
		"$tool" -w -t nat -D "$chain" -i "$interface" -p tcp \
			--dport 80 -j REDIRECT --to-ports 50080 || return 1
	done
	for ((index = 0; index < count; index++)); do
		"$tool" -w -t nat -A "$chain" -i "$interface" -p tcp \
			--dport 80 -j REDIRECT --to-ports 50080 || return 1
	done
}

v4_interface="$(read_state_value v4_interface)"
v4_count="$(read_state_value v4_count)"
v6_interface="$(read_state_value v6_interface)"
v6_count="$(read_state_value v6_count)"

restore_redirects iptables PREROUTING "$v4_interface" "$v4_count"
restore_redirects ip6tables ANTIZAPRET6-PREROUTING "$v6_interface" "$v6_count"
rm -f -- "$state_file"
