#!/bin/bash
set -eu

state_file=/run/admin-antizapret-certbot-redirect.state
lock_file=/run/admin-antizapret-certbot-redirect.lock
setup_file=/root/antizapret/setup
script_dir="$(cd "$(dirname "$0")" && pwd)"

# A killed certbot process may leave a state file behind. Restore that state
# before taking a fresh snapshot of the redirect rules.
if [[ -f "$state_file" ]]; then
	"$script_dir/certbot_standalone_post.sh"
fi

exec 9>"$lock_file"
flock -x 9

remove_redirects() {
	local tool=$1 chain=$2 interface=$3 count_variable=$4 count=0
	[[ -n "$interface" ]] || {
		printf -v "$count_variable" '%s' 0
		return 0
	}
	while "$tool" -w -t nat -C "$chain" -i "$interface" -p tcp \
		--dport 80 -j REDIRECT --to-ports 50080 2>/dev/null
	do
		if ! "$tool" -w -t nat -D "$chain" -i "$interface" -p tcp \
			--dport 80 -j REDIRECT --to-ports 50080
		then
			printf -v "$count_variable" '%s' "$count"
			return 1
		fi
		count=$((count + 1))
	done
	printf -v "$count_variable" '%s' "$count"
}

restore_redirects() {
	local tool=$1 chain=$2 interface=$3 count=$4 index
	[[ -n "$interface" ]] || return 0
	for ((index = 0; index < count; index++)); do
		"$tool" -w -t nat -A "$chain" -i "$interface" -p tcp \
			--dport 80 -j REDIRECT --to-ports 50080 || return 1
	done
}

v4_interface="$(sed -n 's/^DEFAULT_INTERFACE=//p' "$setup_file" 2>/dev/null | tail -n 1)"
v6_interface="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null |
	awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
if [[ -z "$v6_interface" ]]; then
	v6_interface="$(ip -6 route show default 2>/dev/null |
		awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
fi
v4_count=0
v6_count=0

if [[ -n "$v4_interface" ]] && command -v iptables >/dev/null 2>&1; then
	if ! remove_redirects iptables PREROUTING "$v4_interface" v4_count; then
		restore_redirects iptables PREROUTING "$v4_interface" "$v4_count" || true
		exit 1
	fi
fi
if [[ -n "$v6_interface" ]] && command -v ip6tables >/dev/null 2>&1; then
	if ! remove_redirects ip6tables ANTIZAPRET6-PREROUTING "$v6_interface" v6_count; then
		restore_redirects iptables PREROUTING "$v4_interface" "$v4_count" || true
		restore_redirects ip6tables ANTIZAPRET6-PREROUTING "$v6_interface" "$v6_count" || true
		exit 1
	fi
fi

temporary="$(mktemp /run/.admin-antizapret-certbot-redirect.XXXXXX)"
if ! printf 'v4_interface=%s\nv4_count=%s\nv6_interface=%s\nv6_count=%s\n' \
	"$v4_interface" "$v4_count" "$v6_interface" "$v6_count" > "$temporary" ||
	! chmod 600 "$temporary" ||
	! mv -f -- "$temporary" "$state_file"
then
	rm -f -- "$temporary"
	restore_redirects iptables PREROUTING "$v4_interface" "$v4_count" || true
	restore_redirects ip6tables ANTIZAPRET6-PREROUTING "$v6_interface" "$v6_count" || true
	exit 1
fi
