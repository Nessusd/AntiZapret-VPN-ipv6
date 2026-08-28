#!/bin/bash
#
# Скрипт для установки на своём сервере AntiZapret VPN + полный VPN
#
# https://github.com/Nessusd/AntiZapret-VPN-ipv6
#
export LC_ALL=C

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
		echo "Error: Cannot secure VPN private keys under $1 or $2"
		exit 15
	fi
}

# Snapshot managed configuration and unit state before the maintenance window.
# A fatal install error restores that snapshot and restarts the old stack.
INSTALL_TRANSACTION_ROOT=
INSTALL_TRANSACTION_COMMITTED=n
INSTALL_TRANSACTION_STARTED=n
INSTALL_TRANSACTION_LATE_SNAPSHOT=n
INSTALL_TRANSACTION_MAINTENANCE_STOPPED=n
INSTALL_LOCK_PATH=/run/antizapret-setup.lock
INSTALL_LOCK_FD=
INSTALL_CUSTOM_HOOK_MARKER=/run/antizapret-setup.defer-custom-hooks
INSTALL_CUSTOM_HOOK_ENV=/run/antizapret-setup.custom-hook.env
INSTALL_CUSTOM_HOOK_LOCK=/run/antizapret-setup.custom-hook.lock
INSTALL_CUSTOM_HOOK_LOCK_FD=
INSTALL_ROLLBACK_GUARD_COMMENT_PREFIX=antizapret-install-rollback-vpn-guard
INSTALL_ROLLBACK_GUARD_COMMENT=
INSTALL_ROLLBACK_SETUP_FILE=/root/antizapret/setup
INSTALL_ROLLBACK_GUARD_REQUIRED=n
INSTALL_ROLLBACK_TCP4_PORTS=
INSTALL_ROLLBACK_UDP4_PORTS=
INSTALL_ROLLBACK_TCP6_PORTS=
INSTALL_ROLLBACK_UDP6_PORTS=
INSTALL_TRANSACTION_PATHS=(
	/root/easyrsa3
	/root/wireguard
	/root/config
	/root/knot-resolver
	/root/custom
	/root/openvpn-ccd
	/root/antizapret
	/etc/openvpn
	/etc/wireguard
	/etc/knot-resolver
	/etc/apt/sources.list.d/cznic-labs-knot-resolver.list
	/etc/apt/sources.list.d/openvpn-aptrepo.list
	/etc/apt/sources.list.d/backports.list
	/etc/apt/keyrings/cznic-labs-pkg.gpg
	/etc/apt/keyrings/openvpn-repo-public.gpg
	/etc/apt/apt.conf.d/20auto-upgrades
	/etc/apt/apt.conf.d/50unattended-upgrades
	/etc/sysctl.conf
	/etc/sysctl.d/99-disable-ipv6.conf
	/etc/sysctl.d/99-proxy-ipv6.conf
	/etc/sysctl.d/99-antizapret-ipv6.conf
	/etc/sysctl.d/99-antizapret.conf
	/etc/modules-load.d/nf_conntrack.conf
	/etc/logrotate.d/antizapret-openvpn
	/etc/antizapret-bgp
	/var/lib/antizapret-bgp
	/etc/systemd/system/antizapret-bgp.service
	/etc/systemd/system/antizapret-update.service
	/etc/systemd/system/antizapret-update.timer
	/etc/systemd/system/antizapret.service
	/etc/systemd/system/antizapret.service.d
	/etc/systemd/system/logrotate.timer.d/antizapret.conf
	/etc/systemd/system/kresd@.service.d
	/etc/systemd/system/openvpn-server@.service.d
	/etc/systemd/system/wg-quick@.service.d
	/etc/systemd/journald.conf.d/zz-antizapret.conf
	/usr/local/src/openvpn
	/usr/local/src/openvpn.tar.gz
	/usr/local/sbin/openvpn
	/usr/local/lib/systemd/system/openvpn-client@.service
	/usr/local/lib/systemd/system/openvpn-server@.service
	/usr/local/lib/tmpfiles.d/openvpn.conf
	/usr/local/lib/tmpfiles.d/tmpfiles-openvpn.conf
	/usr/local/libexec/openvpn
	/usr/local/include/openvpn-msg.h
	/usr/local/include/openvpn-plugin.h
	/usr/local/lib/openvpn
	/usr/local/share/doc/openvpn
	/usr/local/share/man/man5/openvpn-examples.5
	/usr/local/share/man/man8/openvpn.8
)
INSTALL_TRANSACTION_LATE_PATHS=(
	/usr/lib/knot-resolver/kres_modules/fallback.lua
	/usr/lib/knot-resolver/kres_modules/policy.lua
)
INSTALL_TRANSACTION_UNITS=(
	kresd.target
	kres-cache-gc.service
	kresd@1.service
	kresd@2.service
	antizapret.service
	antizapret-update.timer
	antizapret-update.service
	unattended-upgrades.service
	apt-daily.timer
	apt-daily-upgrade.timer
	apt-daily.service
	apt-daily-upgrade.service
	logrotate.timer
	logrotate.service
	openvpn-server@antizapret-udp.service
	openvpn-server@vpn-udp.service
	openvpn-server@antizapret-tcp.service
	openvpn-server@vpn-tcp.service
	wg-quick@antizapret.service
	wg-quick@vpn.service
	antizapret-bgp.service
)
INSTALL_STOP_UNITS=(
	apt-daily.timer
	apt-daily-upgrade.timer
	logrotate.timer
	antizapret-update.timer
	unattended-upgrades.service
	apt-daily.service
	apt-daily-upgrade.service
	logrotate.service
	antizapret-update.service
	antizapret-bgp.service
	antizapret.service
	openvpn-server@antizapret-udp.service
	openvpn-server@vpn-udp.service
	openvpn-server@antizapret-tcp.service
	openvpn-server@vpn-tcp.service
	wg-quick@antizapret.service
	wg-quick@vpn.service
	kresd.target
	kres-cache-gc.service
	kresd@1.service
	kresd@2.service
)
INSTALL_MAINTENANCE_STOP_UNITS=(
	apt-daily.timer
	apt-daily-upgrade.timer
	logrotate.timer
	antizapret-update.timer
	apt-daily.service
	apt-daily-upgrade.service
	logrotate.service
	unattended-upgrades.service
	antizapret-update.service
	antizapret-bgp.service
)
INSTALL_START_UNITS=(
	kresd.target
	kresd@1.service
	kresd@2.service
	kres-cache-gc.service
	openvpn-server@antizapret-udp.service
	openvpn-server@vpn-udp.service
	openvpn-server@antizapret-tcp.service
	openvpn-server@vpn-tcp.service
	wg-quick@antizapret.service
	wg-quick@vpn.service
	antizapret.service
	antizapret-bgp.service
	antizapret-update.timer
	antizapret-update.service
	logrotate.timer
	apt-daily.timer
	apt-daily-upgrade.timer
	apt-daily.service
	apt-daily-upgrade.service
	logrotate.service
	unattended-upgrades.service
)
declare -A INSTALL_TRANSACTION_ACTIVE=()
declare -A INSTALL_TRANSACTION_ENABLED=()
declare -A INSTALL_TRANSACTION_SYSCTL=()
declare -A INSTALL_ROLLBACK_CURRENT_ACTIVE=()

acquire_install_lock() {
	local hook_state=

	if ! exec {INSTALL_LOCK_FD}>> "$INSTALL_LOCK_PATH"; then
		echo "Error: Cannot open installation lock: $INSTALL_LOCK_PATH"
		return 1
	fi
	chmod 600 "$INSTALL_LOCK_PATH" || return 1
	if ! flock -n "$INSTALL_LOCK_FD"; then
		echo 'Error: Another AntiZapret installation is already running'
		exec {INSTALL_LOCK_FD}>&-
		INSTALL_LOCK_FD=
		return 1
	fi
	if ! lock_install_custom_hooks; then
		echo 'Error: Cannot lock custom hook cutover state'
		return 1
	fi
	if [[ -f "$INSTALL_CUSTOM_HOOK_MARKER" ]]; then
		if ! hook_state="$(< "$INSTALL_CUSTOM_HOOK_MARKER")"; then
			echo 'Error: Cannot read custom hook cutover state'
			unlock_install_custom_hooks
			return 1
		fi
		case "$hook_state" in
			applied)
				if ! rm -f -- "$INSTALL_CUSTOM_HOOK_MARKER" "$INSTALL_CUSTOM_HOOK_ENV"; then
					echo 'Error: Cannot clear completed custom hook cutover state'
					unlock_install_custom_hooks
					return 1
				fi
				;;
			deferred|ready|stopped) ;;
			*)
				echo "Error: Invalid custom hook cutover state: ${hook_state:-empty}"
				unlock_install_custom_hooks
				return 1
				;;
		esac
	fi
	unlock_install_custom_hooks
}

lock_install_custom_hooks() {
	if ! exec {INSTALL_CUSTOM_HOOK_LOCK_FD}>> "$INSTALL_CUSTOM_HOOK_LOCK"; then
		return 1
	fi
	if ! chmod 600 "$INSTALL_CUSTOM_HOOK_LOCK" || ! flock "$INSTALL_CUSTOM_HOOK_LOCK_FD"; then
		exec {INSTALL_CUSTOM_HOOK_LOCK_FD}>&-
		INSTALL_CUSTOM_HOOK_LOCK_FD=
		return 1
	fi
}

unlock_install_custom_hooks() {
	[[ -n "$INSTALL_CUSTOM_HOOK_LOCK_FD" ]] || return 0
	flock -u "$INSTALL_CUSTOM_HOOK_LOCK_FD" >/dev/null 2>&1 || true
	exec {INSTALL_CUSTOM_HOOK_LOCK_FD}>&-
	INSTALL_CUSTOM_HOOK_LOCK_FD=
}

write_install_custom_hook_state() {
	local state=$1 temporary

	temporary="$(mktemp "${INSTALL_CUSTOM_HOOK_MARKER}.XXXXXX")" || return 1
	if ! printf '%s\n' "$state" > "$temporary" ||
		! chmod 600 "$temporary" ||
		! chown root:root "$temporary" ||
		! mv -f -- "$temporary" "$INSTALL_CUSTOM_HOOK_MARKER"
	then
		rm -f -- "$temporary"
		return 1
	fi
}

read_install_unit_enabled_state() {
	local load_state state unit=$1

	state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
	if [[ -n "$state" ]]; then
		printf '%s\n' "$state"
		return 0
	fi
	load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null || true)"
	if [[ "$load_state" == 'not-found' ]]; then
		printf '%s\n' not-found
		return 0
	fi
	return 1
}

install_unit_enabled_state_matches() {
	local actual=$1 expected=$2

	[[ "$actual" == "$expected" ]] && return 0
	if [[ "$expected" == 'not-found' ]]; then
		case "$actual" in
			disabled|static|indirect|generated|transient|linked|linked-runtime|alias|masked|masked-runtime|not-found) return 0 ;;
		esac
	fi
	return 1
}

wait_install_unit_active() {
	local deadline state unit=$1 timeout=${2:-90}

	deadline=$((SECONDS + timeout))
	while (( SECONDS < deadline )); do
		state="$(systemctl is-active "$unit" 2>/dev/null || true)"
		case "$state" in
			active) return 0 ;;
			activating|reloading) sleep 1 ;;
			*)
				systemctl status --no-pager --full "$unit" || true
				echo "Error: $unit failed during cutover (state: ${state:-unavailable})"
				return 1
				;;
		esac
	done

	systemctl status --no-pager --full "$unit" || true
	echo "Error: $unit did not become active within ${timeout}s"
	return 1
}

restore_install_maintenance_units_before_snapshot() {
	local failed=0 unit

	[[ "$INSTALL_TRANSACTION_MAINTENANCE_STOPPED" == 'y' ]] || return 0
	for unit in "${INSTALL_MAINTENANCE_STOP_UNITS[@]}"; do
		case "${INSTALL_TRANSACTION_ACTIVE[$unit]:-unknown}" in
			active|activating|reloading)
				if ! systemctl start "$unit"; then
					echo "Error: Cannot restore $unit after snapshot failure"
					failed=1
				fi
				;;
		esac
	done
	if (( failed == 0 )); then
		INSTALL_TRANSACTION_MAINTENANCE_STOPPED=n
	fi
	return "$failed"
}

stop_and_verify_install_maintenance_units() {
	local failed=0 state unit

	for unit in "${INSTALL_MAINTENANCE_STOP_UNITS[@]}"; do
		systemctl stop "$unit" >/dev/null 2>&1 || true
	done
	for unit in "${INSTALL_MAINTENANCE_STOP_UNITS[@]}"; do
		state="$(systemctl is-active "$unit" 2>/dev/null || true)"
		case "$state" in
			inactive|failed|unknown) ;;
			*)
				echo "Error: Cannot confirm that $unit stopped for the installation maintenance window (state: ${state:-unavailable})"
				failed=1
				;;
		esac
	done
	return "$failed"
}

stop_install_maintenance_units_before_snapshot() {
	INSTALL_TRANSACTION_MAINTENANCE_STOPPED=y
	if ! stop_and_verify_install_maintenance_units; then
		restore_install_maintenance_units_before_snapshot || true
		return 1
	fi
}

abort_install_transaction_before_snapshot() {
	local message=$1

	[[ -z "$INSTALL_TRANSACTION_ROOT" ]] || rm -rf -- "$INSTALL_TRANSACTION_ROOT" || true
	INSTALL_TRANSACTION_ROOT=
	echo "$message"
	if ! restore_install_maintenance_units_before_snapshot; then
		echo 'Error: Maintenance units were not fully restored after snapshot failure'
	fi
	return 1
}

begin_install_transaction() {
	local copy_failed=n path state unit value
	local old_umask

	# Capture state before stopping writers. A failed pre-snapshot phase must be
	# able to put timers and services back exactly as they were found.
	for unit in "${INSTALL_TRANSACTION_UNITS[@]}"; do
		state="$(systemctl is-active "$unit" 2>/dev/null || true)"
		if [[ -z "$state" ]]; then
			echo "Error: Cannot read the active state of $unit before installation"
			return 1
		fi
		INSTALL_TRANSACTION_ACTIVE["$unit"]="$state"
		if ! state="$(read_install_unit_enabled_state "$unit")"; then
			echo "Error: Cannot read the enablement state of $unit before installation"
			return 1
		fi
		INSTALL_TRANSACTION_ENABLED["$unit"]="$state"
	done
	if ! stop_install_maintenance_units_before_snapshot; then
		return 1
	fi

	old_umask="$(umask)"
	umask 077
	INSTALL_TRANSACTION_ROOT="$(mktemp -d /root/.antizapret-install-rollback.XXXXXX)" || {
		umask "$old_umask"
		abort_install_transaction_before_snapshot \
			'Error: Cannot create installation rollback directory'
		return 1
	}
	INSTALL_ROLLBACK_GUARD_COMMENT="${INSTALL_ROLLBACK_GUARD_COMMENT_PREFIX}-${INSTALL_TRANSACTION_ROOT##*.}"
	chmod 700 "$INSTALL_TRANSACTION_ROOT" || {
		umask "$old_umask"
		abort_install_transaction_before_snapshot \
			"Error: Cannot secure installation rollback directory: $INSTALL_TRANSACTION_ROOT"
		return 1
	}
	mkdir -p "$INSTALL_TRANSACTION_ROOT/files" || {
		umask "$old_umask"
		abort_install_transaction_before_snapshot \
			"Error: Cannot prepare installation rollback directory: $INSTALL_TRANSACTION_ROOT"
		return 1
	}

	for path in "${INSTALL_TRANSACTION_PATHS[@]}"; do
		if [[ -e "$path" || -L "$path" ]]; then
			if ! mkdir -p "$INSTALL_TRANSACTION_ROOT/files${path%/*}" || \
				! cp -a -- "$path" "$INSTALL_TRANSACTION_ROOT/files$path"
			then
				copy_failed=y
				break
			fi
		fi
	done
	if [[ "$copy_failed" == 'y' ]]; then
		umask "$old_umask"
		abort_install_transaction_before_snapshot \
			"Error: Cannot preserve the current installation under $INSTALL_TRANSACTION_ROOT"
		return 1
	fi

	# sysctl files are restored with the other paths. Preserve the live values
	# changed before commit too.
	for path in \
		/proc/sys/net/ipv4/ip_forward \
		/proc/sys/net/ipv4/conf/all/route_localnet \
		/proc/sys/net/ipv4/conf/default/route_localnet \
		/proc/sys/net/ipv6/conf/*/disable_ipv6 \
		/proc/sys/net/ipv6/conf/*/forwarding \
		/proc/sys/net/ipv6/conf/*/accept_ra
	do
		[[ -r "$path" ]] || continue
		if ! value="$(< "$path")"; then
			copy_failed=y
			break
		fi
		INSTALL_TRANSACTION_SYSCTL["$path"]="$value"
	done
	if [[ "$copy_failed" == 'y' ]]; then
		umask "$old_umask"
		abort_install_transaction_before_snapshot \
			'Error: Cannot preserve the current network sysctl state'
		return 1
	fi

	umask "$old_umask"
	INSTALL_TRANSACTION_STARTED=y
	# From this point a complete snapshot exists and the regular rollback owns
	# restoration of unit state.
	INSTALL_TRANSACTION_MAINTENANCE_STOPPED=n
	trap 'finish_install_transaction $?' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

snapshot_install_transaction_late_paths() {
	local path staging="$INSTALL_TRANSACTION_ROOT/late-files"

	[[ "$INSTALL_TRANSACTION_STARTED" == 'y' ]] || return 1
	rm -rf -- "$staging" || return 1
	mkdir -p "$staging" || return 1
	for path in "${INSTALL_TRANSACTION_LATE_PATHS[@]}"; do
		if [[ -e "$path" || -L "$path" ]]; then
			if ! mkdir -p "$staging${path%/*}" || ! cp -a -- "$path" "$staging$path"; then
				rm -rf -- "$staging" || true
				return 1
			fi
		fi
	done
	INSTALL_TRANSACTION_LATE_SNAPSHOT=y
}

install_transaction_unit_was_active() {
	case "${INSTALL_TRANSACTION_ACTIVE[$1]:-unknown}" in
		active|activating|reloading) return 0 ;;
		*) return 1 ;;
	esac
}

capture_install_rollback_current_vpn_units() {
	local state unit

	INSTALL_ROLLBACK_CURRENT_ACTIVE=()
	for unit in \
		openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service \
		openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service \
		wg-quick@antizapret.service wg-quick@vpn.service
	do
		state="$(systemctl is-active "$unit" 2>/dev/null || true)"
		case "$state" in
			active|activating|reloading) INSTALL_ROLLBACK_CURRENT_ACTIVE["$unit"]=y ;;
			inactive|failed|unknown) INSTALL_ROLLBACK_CURRENT_ACTIVE["$unit"]=n ;;
			*)
				echo "Rollback error: Cannot read the current state of $unit (state: ${state:-unavailable})"
				return 1
				;;
		esac
	done
}

install_rollback_vpn_unit_was_active() {
	local source=$1 unit=$2

	if [[ "$source" == 'current' ]]; then
		[[ "${INSTALL_ROLLBACK_CURRENT_ACTIVE[$unit]:-n}" == 'y' ]]
	else
		install_transaction_unit_was_active "$unit"
	fi
}

read_install_rollback_openvpn_value() {
	local file=$1 name=$2

	[[ -f "$file" ]] || return 1
	awk -v name="${name,,}" '
		/^[[:space:]]*[#;]/ { next }
		tolower($1) == name { value = $2; count++ }
		END {
			if (count != 1 || value == "") exit 1
			print value
		}
	' "$file"
}

read_install_rollback_wireguard_port() {
	local file=$1

	[[ -f "$file" ]] || return 1
	awk -F= '
		{
			key = $1
			gsub(/[[:space:]]/, "", key)
		}
		tolower(key) == "listenport" {
			value = $2
			gsub(/[[:space:]]/, "", value)
			count++
		}
		END {
			if (count != 1 || value == "") exit 1
			print value
		}
	' "$file"
}

append_install_rollback_guard_port() {
	local variable=$1 port=$2 ports

	[[ "$port" =~ ^[0-9]+$ && ${#port} -le 5 ]] || return 1
	(( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
	port=$((10#$port))
	ports="${!variable}"
	case ",$ports," in
		*",$port,"*) return 0 ;;
	esac
	if [[ -n "$ports" ]]; then
		printf -v "$variable" '%s,%s' "$ports" "$port"
	else
		printf -v "$variable" '%s' "$port"
	fi
}

load_install_rollback_guard_ports() {
	local config disable_ipv6=y file port proto source=${1:-captured} unit

	INSTALL_ROLLBACK_GUARD_REQUIRED=n
	INSTALL_ROLLBACK_TCP4_PORTS=
	INSTALL_ROLLBACK_UDP4_PORTS=
	INSTALL_ROLLBACK_TCP6_PORTS=
	INSTALL_ROLLBACK_UDP6_PORTS=
	if [[ -f "$INSTALL_ROLLBACK_SETUP_FILE" ]]; then
		disable_ipv6="$(awk -F= '$1 == "DISABLE_IPV6" && $2 ~ /^[yn]$/ { value = $2 } END { print value }' "$INSTALL_ROLLBACK_SETUP_FILE")"
		[[ "$disable_ipv6" =~ ^[yn]$ ]] || disable_ipv6=y
	fi

	for unit in \
		openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service \
		openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service
	do
		install_rollback_vpn_unit_was_active "$source" "$unit" || continue
		INSTALL_ROLLBACK_GUARD_REQUIRED=y
		case "$unit" in
			openvpn-server@antizapret-udp.service) config=/etc/openvpn/server/antizapret-udp.conf ;;
			openvpn-server@vpn-udp.service) config=/etc/openvpn/server/vpn-udp.conf ;;
			openvpn-server@antizapret-tcp.service) config=/etc/openvpn/server/antizapret-tcp.conf ;;
			openvpn-server@vpn-tcp.service) config=/etc/openvpn/server/vpn-tcp.conf ;;
		esac
		if ! proto="$(read_install_rollback_openvpn_value "$config" proto)" ||
			! port="$(read_install_rollback_openvpn_value "$config" port)"
		then
			echo "Rollback error: Cannot read the active OpenVPN listener from $config"
			return 1
		fi
		case "${proto,,}" in
			tcp4|tcp4-server)
				append_install_rollback_guard_port INSTALL_ROLLBACK_TCP4_PORTS "$port" || return 1
				;;
			tcp6|tcp6-server)
				append_install_rollback_guard_port INSTALL_ROLLBACK_TCP4_PORTS "$port" || return 1
				append_install_rollback_guard_port INSTALL_ROLLBACK_TCP6_PORTS "$port" || return 1
				;;
			tcp|tcp-server)
				append_install_rollback_guard_port INSTALL_ROLLBACK_TCP4_PORTS "$port" || return 1
				if [[ "$disable_ipv6" == 'n' ]]; then
					append_install_rollback_guard_port INSTALL_ROLLBACK_TCP6_PORTS "$port" || return 1
				fi
				;;
			udp4)
				append_install_rollback_guard_port INSTALL_ROLLBACK_UDP4_PORTS "$port" || return 1
				;;
			udp6)
				append_install_rollback_guard_port INSTALL_ROLLBACK_UDP4_PORTS "$port" || return 1
				append_install_rollback_guard_port INSTALL_ROLLBACK_UDP6_PORTS "$port" || return 1
				;;
			udp)
				append_install_rollback_guard_port INSTALL_ROLLBACK_UDP4_PORTS "$port" || return 1
				if [[ "$disable_ipv6" == 'n' ]]; then
					append_install_rollback_guard_port INSTALL_ROLLBACK_UDP6_PORTS "$port" || return 1
				fi
				;;
			*)
				echo "Rollback error: Unsupported proto $proto in $config"
				return 1
				;;
		esac
	done

	for unit in wg-quick@antizapret.service wg-quick@vpn.service; do
		install_rollback_vpn_unit_was_active "$source" "$unit" || continue
		INSTALL_ROLLBACK_GUARD_REQUIRED=y
		case "$unit" in
			wg-quick@antizapret.service) file=/etc/wireguard/antizapret.conf ;;
			wg-quick@vpn.service) file=/etc/wireguard/vpn.conf ;;
		esac
		if ! port="$(read_install_rollback_wireguard_port "$file")"; then
			echo "Rollback error: Cannot read the active WireGuard listener from $file"
			return 1
		fi
		append_install_rollback_guard_port INSTALL_ROLLBACK_UDP4_PORTS "$port" || return 1
		# Kernel WireGuard owns both address families even when the tunnel has no
		# inner IPv6 address yet.
		append_install_rollback_guard_port INSTALL_ROLLBACK_UDP6_PORTS "$port" || return 1
	done
}

add_install_rollback_vpn_guard() {
	local ports protocol source=${1:-captured} tool variable

	if [[ -z "$INSTALL_ROLLBACK_GUARD_COMMENT" ]]; then
		echo 'Rollback error: Installation guard identifier is missing'
		return 1
	fi
	load_install_rollback_guard_ports "$source" || return 1
	for variable in \
		INSTALL_ROLLBACK_TCP4_PORTS INSTALL_ROLLBACK_UDP4_PORTS \
		INSTALL_ROLLBACK_TCP6_PORTS INSTALL_ROLLBACK_UDP6_PORTS
	do
		ports="${!variable}"
		[[ -n "$ports" ]] || continue
		case "$variable" in
			INSTALL_ROLLBACK_TCP4_PORTS) tool=iptables; protocol=tcp ;;
			INSTALL_ROLLBACK_UDP4_PORTS) tool=iptables; protocol=udp ;;
			INSTALL_ROLLBACK_TCP6_PORTS) tool=ip6tables; protocol=tcp ;;
			INSTALL_ROLLBACK_UDP6_PORTS) tool=ip6tables; protocol=udp ;;
		esac
		if ! "$tool" -w -I INPUT 1 -p "$protocol" -m multiport --dports "$ports" \
			-m comment --comment "$INSTALL_ROLLBACK_GUARD_COMMENT" -j DROP
		then
			echo "Rollback error: Cannot protect restored VPN ports with $tool"
			return 1
		fi
	done
}

remove_install_rollback_vpn_guard_from() {
	local exact=${3:-n} listing marker=$2 number tool=$1

	while :; do
		if ! listing="$("$tool" -w -L INPUT --line-numbers -n 2>/dev/null)"; then
			echo "Error: Cannot inspect $tool rollback guard rules"
			return 1
		fi
		number="$(awk -v exact="$exact" -v marker="$marker" '
			BEGIN { target = exact == "y" ? "/* " marker " */" : marker }
			index($0, target) { print $1; exit }
		' <<< "$listing")"
		[[ -n "$number" ]] || return 0
		if [[ ! "$number" =~ ^[0-9]+$ ]] || ! "$tool" -w -D INPUT "$number"; then
			echo "Error: Cannot remove $tool rollback guard rule"
			return 1
		fi
	done
}

remove_install_rollback_vpn_guard() {
	local failed=0

	remove_install_rollback_vpn_guard_from iptables "$INSTALL_ROLLBACK_GUARD_COMMENT_PREFIX" || failed=1
	remove_install_rollback_vpn_guard_from ip6tables "$INSTALL_ROLLBACK_GUARD_COMMENT_PREFIX" || failed=1
	return "$failed"
}

remove_current_install_rollback_vpn_guard() {
	local failed=0

	if [[ -z "$INSTALL_ROLLBACK_GUARD_COMMENT" ]]; then
		echo 'Error: Installation guard identifier is missing'
		return 1
	fi
	remove_install_rollback_vpn_guard_from iptables "$INSTALL_ROLLBACK_GUARD_COMMENT" y || failed=1
	remove_install_rollback_vpn_guard_from ip6tables "$INSTALL_ROLLBACK_GUARD_COMMENT" y || failed=1
	return "$failed"
}

verify_install_transaction_unit_active() {
	local state unit=$1

	state="$(systemctl is-active "$unit" 2>/dev/null || true)"
	if [[ "$state" != 'active' ]]; then
		echo "Rollback error: $unit is not active after restart (state: ${state:-unavailable})"
		return 1
	fi
}

verify_install_unit_stopped() {
	local state unit=$1

	state="$(systemctl is-active "$unit" 2>/dev/null || true)"
	case "$state" in
		inactive|failed|unknown) return 0 ;;
		*)
			echo "Error: Cannot confirm that $unit stopped (state: ${state:-unavailable})"
			return 1
			;;
	esac
}

restore_install_transaction() {
	local failed=0 hook_state= knob path runtime_paths=() saved state unit vpn_unit

	set +e
	if ! capture_install_rollback_current_vpn_units ||
		! add_install_rollback_vpn_guard current
	then
		return 1
	fi
	if ! lock_install_custom_hooks; then
		echo 'Rollback error: Cannot lock custom hook cutover state'
		return 1
	fi
	if [[ -f "$INSTALL_CUSTOM_HOOK_MARKER" ]]; then
		if ! hook_state="$(< "$INSTALL_CUSTOM_HOOK_MARKER")"; then
			echo 'Rollback error: Cannot read custom hook cutover state'
			unlock_install_custom_hooks
			return 1
		fi
		# custom-up уже запускался: штатный stop должен парно
		# вызвать custom-down, пока VPN-интерфейсы ещё живы.
		if [[ "$hook_state" == 'applied' ]] && ! rm -f -- "$INSTALL_CUSTOM_HOOK_MARKER"; then
			echo 'Rollback error: Cannot enable custom-down for the active cutover'
			unlock_install_custom_hooks
			return 1
		fi
	fi
	unlock_install_custom_hooks
	for unit in "${INSTALL_STOP_UNITS[@]}"; do
		systemctl stop "$unit" >/dev/null 2>&1 || true
		systemctl disable "$unit" >/dev/null 2>&1 || true
	done
	for unit in "${INSTALL_STOP_UNITS[@]}"; do
		state="$(systemctl is-active "$unit" 2>/dev/null || true)"
		case "$state" in
			inactive|failed|unknown) ;;
			*)
				echo "Rollback error: Cannot confirm that $unit stopped; live files were not replaced (state: ${state:-unavailable})"
				failed=1
				;;
		esac
		if ! state="$(read_install_unit_enabled_state "$unit")"; then
			state=
		fi
		case "$state" in
			disabled|static|indirect|generated|transient|linked|linked-runtime|alias|masked|masked-runtime|not-found) ;;
			*)
				echo "Rollback error: Cannot confirm that $unit is disabled; live files were not replaced (state: ${state:-unavailable})"
				failed=1
				;;
		esac
	done
	if (( failed != 0 )); then
		return "$failed"
	fi
	if ! rm -f -- "$INSTALL_CUSTOM_HOOK_MARKER" "$INSTALL_CUSTOM_HOOK_ENV"; then
		echo 'Rollback error: Cannot clear custom hook cutover state'
		return 1
	fi

	for path in "${INSTALL_TRANSACTION_PATHS[@]}"; do
		saved="$INSTALL_TRANSACTION_ROOT/files$path"
		if ! rm -rf -- "$path"; then
			echo "Rollback error: Cannot remove replacement path $path"
			failed=1
			continue
		fi
		if [[ -e "$saved" || -L "$saved" ]]; then
			if ! mkdir -p "${path%/*}" || ! cp -a -- "$saved" "$path"; then
				echo "Rollback error: Cannot restore $path"
				failed=1
			fi
		fi
	done
	if [[ "$INSTALL_TRANSACTION_LATE_SNAPSHOT" == 'y' ]]; then
		for path in "${INSTALL_TRANSACTION_LATE_PATHS[@]}"; do
			saved="$INSTALL_TRANSACTION_ROOT/late-files$path"
			if ! rm -rf -- "$path"; then
				echo "Rollback error: Cannot remove replacement path $path"
				failed=1
				continue
			fi
			if [[ -e "$saved" || -L "$saved" ]]; then
				if ! mkdir -p "${path%/*}" || ! cp -a -- "$saved" "$path"; then
					echo "Rollback error: Cannot restore $path"
					failed=1
				fi
			fi
		done
	fi

	mapfile -t runtime_paths < <(printf '%s\n' "${!INSTALL_TRANSACTION_SYSCTL[@]}" | sort)
	for knob in disable_ipv6 forwarding accept_ra ip_forward route_localnet; do
		for path in "${runtime_paths[@]}"; do
			[[ "$path" == */"$knob" ]] || continue
			# Tunnel interfaces disappear while their services are stopped. They
			# inherit the restored default values when recreated.
			[[ -w "$path" ]] || continue
			if ! printf '%s\n' "${INSTALL_TRANSACTION_SYSCTL[$path]}" > "$path"; then
				echo "Rollback error: Cannot restore live sysctl $path"
				failed=1
			fi
		done
	done

	if ! set_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard; then
		echo 'Rollback error: Cannot secure restored VPN private keys'
		failed=1
	fi
	if ! systemctl daemon-reload; then
		echo 'Rollback error: systemd daemon-reload failed'
		failed=1
	fi
	if (( failed != 0 )); then
		return "$failed"
	fi

	for unit in "${INSTALL_TRANSACTION_UNITS[@]}"; do
		state="${INSTALL_TRANSACTION_ENABLED[$unit]}"
		case "$state" in
			enabled)
				systemctl unmask "$unit" >/dev/null 2>&1 || true
				systemctl unmask --runtime "$unit" >/dev/null 2>&1 || true
				systemctl enable "$unit" >/dev/null 2>&1 || true
				;;
			enabled-runtime)
				systemctl unmask "$unit" >/dev/null 2>&1 || true
				systemctl unmask --runtime "$unit" >/dev/null 2>&1 || true
				systemctl enable --runtime "$unit" >/dev/null 2>&1 || true
				;;
			disabled)
				systemctl unmask "$unit" >/dev/null 2>&1 || true
				systemctl unmask --runtime "$unit" >/dev/null 2>&1 || true
				systemctl disable "$unit" >/dev/null 2>&1 || true
				;;
			masked)
				systemctl mask "$unit" >/dev/null 2>&1 || true
				;;
			masked-runtime)
				systemctl mask --runtime "$unit" >/dev/null 2>&1 || true
				;;
		esac
	done
	for unit in "${INSTALL_TRANSACTION_UNITS[@]}"; do
		if ! state="$(read_install_unit_enabled_state "$unit")"; then
			state=
		fi
		if [[ -z "$state" ]] ||
			! install_unit_enabled_state_matches "$state" "${INSTALL_TRANSACTION_ENABLED[$unit]}"
		then
			echo "Rollback error: Cannot restore the enablement state of $unit (expected: ${INSTALL_TRANSACTION_ENABLED[$unit]}, got: ${state:-unavailable})"
			failed=1
		fi
	done
	if (( failed != 0 )); then
		return "$failed"
	fi

	if ! add_install_rollback_vpn_guard; then
		return 1
	fi
	if [[ "$INSTALL_ROLLBACK_GUARD_REQUIRED" == 'y' ]] &&
		! install_transaction_unit_was_active antizapret.service
	then
		echo 'Rollback error: Active VPN listeners cannot be restored without the previous firewall service'
		return 1
	fi

	for unit in "${INSTALL_START_UNITS[@]}"; do
		install_transaction_unit_was_active "$unit" || continue
		if ! systemctl start "$unit"; then
			echo "Rollback error: Cannot restart $unit"
			return 1
		fi
		if [[ "$unit" == 'antizapret.service' ]]; then
			verify_install_transaction_unit_active antizapret.service || return 1
			for vpn_unit in \
				openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service \
				openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service \
				wg-quick@antizapret.service wg-quick@vpn.service
			do
				install_transaction_unit_was_active "$vpn_unit" || continue
				verify_install_transaction_unit_active "$vpn_unit" || return 1
			done
			remove_current_install_rollback_vpn_guard || return 1
		fi
	done
	return 0
}

finish_install_transaction() {
	local original_status=$1 rollback_status=0

	trap - EXIT ERR INT TERM
	if [[ "$INSTALL_TRANSACTION_STARTED" == 'y' && "$INSTALL_TRANSACTION_COMMITTED" != 'y' ]]; then
		echo 'Installation did not complete; restoring the previous VPN and DNS configuration...'
		restore_install_transaction || rollback_status=$?
		if (( rollback_status == 0 )); then
			rm -rf -- "$INSTALL_TRANSACTION_ROOT" || true
			echo 'Managed VPN and DNS configuration restored; package upgrades were not rolled back.'
		else
			echo "Rollback is incomplete. Recovery data was kept in $INSTALL_TRANSACTION_ROOT"
		fi
	elif [[ "$INSTALL_TRANSACTION_STARTED" != 'y' && "$INSTALL_TRANSACTION_MAINTENANCE_STOPPED" == 'y' ]]; then
		# The filesystem snapshot was not completed. No managed files changed,
		# but writers stopped for a consistent copy still have to come back.
		restore_install_maintenance_units_before_snapshot || true
	fi
	[[ -z "${BACKUP_STAGING:-}" ]] || rm -rf -- "$BACKUP_STAGING" || true
	[[ -z "${OPENVPN_CCD_STAGING:-}" ]] || rm -rf -- "$OPENVPN_CCD_STAGING" || true
	rm -rf -- /tmp/antizapret /tmp/dnslib || true
	exit "$original_status"
}

commit_install_transaction() {
	local hook_state=

	if ! lock_install_custom_hooks; then
		echo 'Error: Cannot lock custom hook cutover state before commit'
		return 1
	fi
	if [[ -f "$INSTALL_CUSTOM_HOOK_MARKER" ]]; then
		if ! hook_state="$(< "$INSTALL_CUSTOM_HOOK_MARKER")"; then
			echo 'Error: Cannot read custom hook cutover state before commit'
			unlock_install_custom_hooks
			return 1
		fi
	fi
	if [[ "$hook_state" != 'applied' ]]; then
		echo "Error: Custom hook cutover is not ready for commit: ${hook_state:-missing}"
		unlock_install_custom_hooks
		return 1
	fi
	if ! rm -f -- "$INSTALL_CUSTOM_HOOK_MARKER" "$INSTALL_CUSTOM_HOOK_ENV"; then
		echo 'Error: Cannot clear custom hook cutover state before commit'
		unlock_install_custom_hooks
		return 1
	fi
	unlock_install_custom_hooks
	INSTALL_TRANSACTION_COMMITTED=y
	if ! rm -rf -- "$INSTALL_TRANSACTION_ROOT"; then
		echo "Warning: Cannot remove completed installation rollback data: $INSTALL_TRANSACTION_ROOT"
	fi
}

# Проверка необходимости перезагрузить
if [[ -f /var/run/reboot-required ]] || pidof apt apt-get dpkg unattended-upgrades &>/dev/null; then
	echo 'Error: You need to reboot this server before installation!'
	exit 2
fi

# Проверка прав root
if [[ "$EUID" -ne 0 ]]; then
	echo 'Error: You need to run this as root!'
	exit 3
fi
if ! acquire_install_lock; then
	exit 17
fi

cd /root

# Проверяем загруженный архив до изменения установленной системы. Несколько
# архивов неоднозначны: выбор по порядку glob мог восстановить не тот backup.
BACKUP_ARCHIVES=()
mapfile -d '' -t BACKUP_ARCHIVES < <(find /root -maxdepth 1 -type f -name 'backup*.tar.gz' -print0)
if (( ${#BACKUP_ARCHIVES[@]} > 1 )); then
	echo 'Error: Multiple backup*.tar.gz archives found in /root. Leave exactly one archive and restart installation:'
	printf '  %s\n' "${BACKUP_ARCHIVES[@]}"
	exit 13
fi
BACKUP_ARCHIVE="${BACKUP_ARCHIVES[0]-}"
if [[ -n "$BACKUP_ARCHIVE" ]] && ! tar -tzf "$BACKUP_ARCHIVE" >/dev/null; then
	echo "Error: Invalid or unreadable backup archive: $BACKUP_ARCHIVE"
	exit 13
fi
backup_has_supported_directory() {
	local entry
	while IFS= read -r entry; do
		entry="${entry#./}"
		case "$entry" in
			easyrsa3|easyrsa3/*|openvpn-ccd|openvpn-ccd/*|wireguard|wireguard/*|config|config/*|knot-resolver|knot-resolver/*|custom|custom/*)
				return 0
				;;
		esac
	done < <(tar -tzf "$1")
	return 1
}
if [[ -n "$BACKUP_ARCHIVE" ]] && ! backup_has_supported_directory "$BACKUP_ARCHIVE"; then
	echo "Error: Backup archive contains no supported configuration directories: $BACKUP_ARCHIVE"
	exit 13
fi

# Запоминаем управляемые настройки предыдущей установки. Значения IPv6 из
# окружения сохраняются отдельно: явный override должен иметь высший приоритет.
ENV_VPN_IPV6_PREFIX="${VPN_IPV6_PREFIX-}"
ENV_WIREGUARD_IPV6_PREFIX="${WIREGUARD_IPV6_PREFIX-}"
OLD_BGP_ENABLE=n
OLD_BGP_SERVER_ASN=4200000290
OLD_BGP_CLIENT_ASN=4200000291
OLD_VPN_IPV6_PREFIX=
MANAGED_BGP_PRESENT=n
if [[ -f /root/antizapret/setup ]]; then
	OLD_BGP_ENABLE="$(sed -n 's/^BGP_ENABLE=\([yn]\)$/\1/p' /root/antizapret/setup | tail -n 1)"
	OLD_BGP_SERVER_ASN="$(sed -n 's/^BGP_SERVER_ASN=\([0-9]\+\)$/\1/p' /root/antizapret/setup | tail -n 1)"
	OLD_BGP_CLIENT_ASN="$(sed -n 's/^BGP_CLIENT_ASN=\([0-9]\+\)$/\1/p' /root/antizapret/setup | tail -n 1)"
	OLD_VPN_IPV6_PREFIX="$(sed -n 's/^VPN_IPV6_PREFIX=//p' /root/antizapret/setup | tail -n 1)"
	if [[ -z "$OLD_VPN_IPV6_PREFIX" ]]; then
		OLD_VPN_IPV6_PREFIX="$(sed -n 's/^WIREGUARD_IPV6_PREFIX=//p' /root/antizapret/setup | tail -n 1)"
	fi
fi
OLD_BGP_ENABLE="${OLD_BGP_ENABLE:-n}"
OLD_BGP_SERVER_ASN="${OLD_BGP_SERVER_ASN:-4200000290}"
OLD_BGP_CLIENT_ASN="${OLD_BGP_CLIENT_ASN:-4200000291}"
if [[ "$OLD_BGP_ENABLE" == 'y' || -f /etc/systemd/system/antizapret-bgp.service ]]; then
	MANAGED_BGP_PRESENT=y
fi
dpkg-query -W -f='${Status}' bird2 2>/dev/null | grep -q 'ok installed' && BIRD_WAS_INSTALLED=y || BIRD_WAS_INSTALLED=n
BIRD_WAS_AUTO=n
if [[ "$BIRD_WAS_INSTALLED" == 'y' ]] && apt-mark showauto bird2 2>/dev/null | grep -qx bird2; then
	BIRD_WAS_AUTO=y
fi

# Проверка на OpenVZ и LXC
if [[ "$(systemd-detect-virt)" == 'openvz' || "$(systemd-detect-virt)" == 'lxc' ]]; then
	echo 'Error: OpenVZ and LXC are not supported!'
	exit 4
fi

# Проверка версии системы
OS="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
VERSION="$(lsb_release -rs | cut -d '.' -f1)"
CODENAME="$(lsb_release -cs)"
ARCH="$(dpkg --print-architecture)"

if [[ "$OS" != 'debian' && "$OS" != 'ubuntu' ]]; then
	echo "Error: Your Linux distribution ($OS) is not supported!"
	exit 7
fi

# Проверка свободного места (минимум 2Гб)
if [[ $(df --output=avail / | tail -n 1) -lt $((2 * 1024 * 1024)) ]]; then
	echo 'Error: Low disk space! You need 2GB of free space!'
	exit 8
fi

# Проверка наличия сетевого интерфейса и IPv4-адреса
DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
if [[ -z "$DEFAULT_INTERFACE" ]]; then
	echo 'Default network interface not found!'
	exit 9
fi

DEFAULT_IP="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'src \K\S+')"
if [[ -z "$DEFAULT_IP" ]]; then
	echo 'Default IPv4 address not found!'
	exit 10
fi

echo
echo -e '\e[1;32mInstalling AntiZapret VPN + full VPN...\e[0m'
echo 'OpenVPN + WireGuard + AmneziaWG'
echo 'More details: https://github.com/Nessusd/AntiZapret-VPN-ipv6'
echo

MTU=$(< /sys/class/net/$DEFAULT_INTERFACE/mtu)
if (( MTU < 1500 )); then
	echo "Warning! Low MTU on $DEFAULT_INTERFACE: $MTU"
	echo "Change MTU in OpenVPN and WireGuard configs from 1420 to $((MTU-80)) on this server after installation"
	echo
fi

# Спрашиваем о настройках
until [[ "$OPENVPN_UDP_ENABLE" =~ ^[yn]$ ]]; do
	read -rp 'Enable OpenVPN UDP? [y/n]: ' -e -i y OPENVPN_UDP_ENABLE
done
echo
until [[ "$OPENVPN_TCP_ENABLE" =~ ^[yn]$ ]]; do
	read -rp 'Enable OpenVPN TCP? [y/n]: ' -e -i n OPENVPN_TCP_ENABLE
done
echo
until [[ "$WIREGUARD_ENABLE" =~ ^[yn]$ ]]; do
	read -rp 'Enable WireGuard/AmneziaWG? [y/n]: ' -e -i y WIREGUARD_ENABLE
done
echo
until [[ "$BGP_ENABLE" =~ ^[yn]$ ]]; do
	read -rp 'Enable private BGP route delivery for router clients? [y/n]: ' -e -i "$OLD_BGP_ENABLE" BGP_ENABLE
done
is_private_asn() {
	[[ "$1" =~ ^[0-9]{1,10}$ ]] || return 1
	(( (1 <= 10#$1 && 10#$1 <= 4294967294) && ((10#$1 >= 64512 && 10#$1 <= 65534) || 10#$1 >= 4200000000) ))
}
BGP_SERVER_ASN=
BGP_CLIENT_ASN=
if [[ "$BGP_ENABLE" == 'y' ]]; then
	if [[ "$OPENVPN_UDP_ENABLE" != 'y' && "$OPENVPN_TCP_ENABLE" != 'y' && "$WIREGUARD_ENABLE" != 'y' ]]; then
		echo 'BGP requires at least one enabled VPN protocol!'
		exit 11
	fi
	until is_private_asn "$BGP_SERVER_ASN"; do
		read -rp 'Private ASN for the AntiZapret BGP server: ' -e -i "$OLD_BGP_SERVER_ASN" BGP_SERVER_ASN
	done
	until is_private_asn "$BGP_CLIENT_ASN" && [[ "$BGP_CLIENT_ASN" != "$BGP_SERVER_ASN" ]]; do
		read -rp 'Private ASN used by BGP clients: ' -e -i "$OLD_BGP_CLIENT_ASN" BGP_CLIENT_ASN
	done
else
	BGP_SERVER_ASN="$OLD_BGP_SERVER_ASN"
	BGP_CLIENT_ASN="$OLD_BGP_CLIENT_ASN"
fi
echo
until [[ "$DISABLE_IPV6" =~ ^[yn]$ ]]; do
	read -rp 'Disable IPv6 on this server? [y/n]: ' -e -i n DISABLE_IPV6
done
VPN_IPV6_PREFIX="${ENV_VPN_IPV6_PREFIX:-${ENV_WIREGUARD_IPV6_PREFIX:-${OLD_VPN_IPV6_PREFIX:-fd3a:c9bc:6bcb::/48}}}"
read_ipv6_details() {
	local address=$1 output

	output="$(sipcalc "$address" 2>&1)" || return 1
	[[ "$output" != *'-[ERR :'* ]] || return 1
	IPV6_EXPANDED_ADDRESS="$(awk '/^Expanded Address/ { sub(/^.*-[[:space:]]*/, ""); print; exit }' <<< "$output")"
	IPV6_PREFIX_LENGTH="$(awk '/^Prefix length/ { sub(/^.*-[[:space:]]*/, ""); print; exit }' <<< "$output")"
	[[ "$IPV6_EXPANDED_ADDRESS" =~ ^([0-9a-f]{4}:){7}[0-9a-f]{4}$ ]] || return 1
	[[ "$IPV6_PREFIX_LENGTH" =~ ^[0-9]{1,3}$ ]] || return 1
}

normalize_ipv6_hextet() {
	printf '%x' "$((16#$1))"
}

is_ipv4_address() {
	local address=$1 octet
	local -a octets=()

	[[ "$address" != .* && "$address" != *. && "$address" != *..* ]] || return 1
	IFS=. read -r -a octets <<< "$address"
	(( ${#octets[@]} == 4 )) || return 1
	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
		(( 10#$octet <= 255 )) || return 1
	done
}

is_ipv6_address() {
	read_ipv6_details "$1" && [[ "$IPV6_PREFIX_LENGTH" == '128' ]]
}

validate_vpn_ipv6_prefix() {
	local prefix=$1
	local -a hextets=()

	if ! read_ipv6_details "$prefix"; then
		echo "Error: Invalid VPN IPv6 prefix: $prefix"
		return 1
	fi
	IFS=: read -r -a hextets <<< "$IPV6_EXPANDED_ADDRESS"
	if [[ "$IPV6_PREFIX_LENGTH" != '48' ]] ||
		[[ "${hextets[*]:3}" != '0000 0000 0000 0000 0000' ]]
	then
		echo 'Error: VPN IPv6 prefix must be an IPv6 /48 network'
		return 1
	fi
	if [[ ! "${hextets[0]}" =~ ^f[cd][0-9a-f]{2}$ ]]; then
		echo 'Error: VPN IPv6 prefix must be a private ULA /48 network'
		return 1
	fi
}

derive_vpn_ipv6_layout() {
	local -a hextets=()
	local base

	if ! validate_vpn_ipv6_prefix "$VPN_IPV6_PREFIX"; then
		echo 'Error: Cannot derive VPN IPv6 networks from VPN_IPV6_PREFIX'
		exit 14
	fi
	IFS=: read -r -a hextets <<< "$IPV6_EXPANDED_ADDRESS"
	base="$(normalize_ipv6_hextet "${hextets[0]}"):$(normalize_ipv6_hextet "${hextets[1]}"):$(normalize_ipv6_hextet "${hextets[2]}")"

	ANTIZAPRET_UDP_NETWORK6="$base:2900::/64"
	ANTIZAPRET_UDP_DNS6="$base:2900::1"
	ANTIZAPRET_TCP_NETWORK6="$base:2904::/64"
	ANTIZAPRET_TCP_DNS6="$base:2904::1"
	ANTIZAPRET_WG_NETWORK6="$base:2908::/64"
	ANTIZAPRET_WG_DNS6="$base:2908::1"
	VPN_UDP_NETWORK6="$base:2800::/64"
	VPN_UDP_DNS6="$base:2800::1"
	VPN_TCP_NETWORK6="$base:2804::/64"
	VPN_TCP_DNS6="$base:2804::1"
	VPN_WG_NETWORK6="$base:2808::/64"
	VPN_WG_DNS6="$base:2808::1"
}

default_fake_ipv6_network() {
	local -a hextets=()
	local base

	validate_vpn_ipv6_prefix "$1" >/dev/null || return 1
	IFS=: read -r -a hextets <<< "$IPV6_EXPANDED_ADDRESS"
	base="$(normalize_ipv6_hextet "${hextets[0]}"):$(normalize_ipv6_hextet "${hextets[1]}"):$(normalize_ipv6_hextet "${hextets[2]}")"
	printf '%s:29ff::/96\n' "$base"
}

keep_ipv4_addresses() {
	local address
	FILTERED_DNS_ADDRESSES=()
	for address in "$@"; do
		[[ "$address" == *:* ]] || FILTERED_DNS_ADDRESSES+=("$address")
	done
}

select_dns_addresses() {
	local cloudflare_quad9=(
		1.1.1.1 9.9.9.10
		2606:4700:4700::1111 2620:fe::10
	)

	case "$ANTIZAPRET_DNS" in
		1)
			ANTI_UPSTREAMS=(
				62.76.76.62 195.208.4.1
				2001:6d0:6d0::2001 2a0c:a9c7:8::1
			)
			PROXY_UPSTREAMS=("${cloudflare_quad9[@]}")
			;;
		2|3)
			if [[ "$ANTIZAPRET_DNS" == '2' ]]; then
				echo 'Warning: SkyDNS is no longer available; using Cloudflare+Quad9'
			fi
			ANTI_UPSTREAMS=("${cloudflare_quad9[@]}")
			PROXY_UPSTREAMS=("${cloudflare_quad9[@]}")
			;;
		4)
			ANTI_UPSTREAMS=(83.220.169.155 212.109.195.93)
			PROXY_UPSTREAMS=("${ANTI_UPSTREAMS[@]}")
			;;
		5)
			ANTI_UPSTREAMS=(
				111.88.96.50 111.88.96.51
				2a00:ab00:1233:26::50 2a00:ab00:1233:26::51
			)
			PROXY_UPSTREAMS=("${ANTI_UPSTREAMS[@]}")
			;;
		6)
			ANTI_UPSTREAMS=(
				95.216.204.218 80.253.249.40
				2a01:4f9:c014:6dac::1 2a12:bec4:1460:5b7::2
			)
			PROXY_UPSTREAMS=("${ANTI_UPSTREAMS[@]}")
			;;
		*)
			echo "Error: Unsupported AntiZapret DNS choice: $ANTIZAPRET_DNS"
			exit 16
			;;
	esac

	case "$VPN_DNS" in
		1) VPN_CLIENT_DNS=() ;;
		2) VPN_CLIENT_DNS=(1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001) ;;
		3) VPN_CLIENT_DNS=(9.9.9.10 149.112.112.10 2620:fe::10 2620:fe::fe:10) ;;
		4) VPN_CLIENT_DNS=(8.8.8.8 8.8.4.4 2001:4860:4860::8888 2001:4860:4860::8844) ;;
		5) VPN_CLIENT_DNS=(94.140.14.14 94.140.15.15 2a10:50c0::ad1:ff 2a10:50c0::ad2:ff) ;;
		6) VPN_CLIENT_DNS=(83.220.169.155 212.109.195.93) ;;
		7) VPN_CLIENT_DNS=(111.88.96.50 111.88.96.51 2a00:ab00:1233:26::50 2a00:ab00:1233:26::51) ;;
		8) VPN_CLIENT_DNS=(95.216.204.218 80.253.249.40 2a01:4f9:c014:6dac::1 2a12:bec4:1460:5b7::2) ;;
		*)
			echo "Error: Unsupported full VPN DNS choice: $VPN_DNS"
			exit 16
			;;
	esac

	if [[ "$DISABLE_IPV6" == 'y' ]]; then
		keep_ipv4_addresses "${ANTI_UPSTREAMS[@]}"
		ANTI_UPSTREAMS=("${FILTERED_DNS_ADDRESSES[@]}")
		keep_ipv4_addresses "${PROXY_UPSTREAMS[@]}"
		PROXY_UPSTREAMS=("${FILTERED_DNS_ADDRESSES[@]}")
		keep_ipv4_addresses "${VPN_CLIENT_DNS[@]}"
		VPN_CLIENT_DNS=("${FILTERED_DNS_ADDRESSES[@]}")
	fi
}

write_lua_list() {
	local name=$1 separator= value
	shift
	printf '  %s = {' "$name"
	for value in "$@"; do
		printf "%s'%s'" "$separator" "$value"
		separator=', '
	done
	printf '},\n'
}

write_kresd_generated_config() {
	local destination=${KRESD_GENERATED_CONFIG_PATH:-/etc/knot-resolver/antizapret-generated.conf}
	local temporary ipv6_enabled=false vpn_dns_self_hosted=false
	[[ "$DISABLE_IPV6" != 'y' ]] && ipv6_enabled=true
	[[ "$VPN_DNS" == '1' ]] && vpn_dns_self_hosted=true
	temporary="$(mktemp "${destination%/*}/.antizapret-generated.conf.XXXXXX")"
	{
		echo 'return {'
		printf '  ipv6_enabled = %s,\n' "$ipv6_enabled"
		printf '  vpn_dns_self_hosted = %s,\n' "$vpn_dns_self_hosted"
		write_lua_list anti_upstreams "${ANTI_UPSTREAMS[@]}"
		write_lua_list proxy_upstreams "${PROXY_UPSTREAMS[@]}"
		printf "  anti_ipv6 = {\n"
		printf "    udp = { network = '%s', gateway = '%s' },\n" "$ANTIZAPRET_UDP_NETWORK6" "$ANTIZAPRET_UDP_DNS6"
		printf "    tcp = { network = '%s', gateway = '%s' },\n" "$ANTIZAPRET_TCP_NETWORK6" "$ANTIZAPRET_TCP_DNS6"
		printf "    wireguard = { network = '%s', gateway = '%s' },\n" "$ANTIZAPRET_WG_NETWORK6" "$ANTIZAPRET_WG_DNS6"
		printf "  },\n"
		printf "  vpn_ipv6 = {\n"
		printf "    udp = { network = '%s', gateway = '%s' },\n" "$VPN_UDP_NETWORK6" "$VPN_UDP_DNS6"
		printf "    tcp = { network = '%s', gateway = '%s' },\n" "$VPN_TCP_NETWORK6" "$VPN_TCP_DNS6"
		printf "    wireguard = { network = '%s', gateway = '%s' },\n" "$VPN_WG_NETWORK6" "$VPN_WG_DNS6"
		printf "  },\n"
		echo '}'
	} > "$temporary"
	chmod 644 "$temporary"
	chown root:root "$temporary"
	mv -f "$temporary" "$destination"
}

set_dns_directives() {
	local kind=$1 path=$2
	shift 2
	local address directory joined='' line normalized read_status temporary
	local inserted=n managed=n newline trimmed
	local -a replacement=()

	if (( $# == 0 )); then
		echo "Error: No DNS addresses supplied for $path"
		return 1
	fi
	if [[ ! -f "$path" ]]; then
		echo "Error: DNS configuration does not exist: $path"
		return 1
	fi
	for address in "$@"; do
		if is_ipv4_address "$address"; then
			[[ "$kind" == 'openvpn' ]] && replacement+=("push \"dhcp-option DNS $address\"")
		elif is_ipv6_address "$address"; then
			[[ "$kind" == 'openvpn' ]] && replacement+=("push \"dhcp-option DNS6 $address\"")
		else
			echo "Error: Invalid DNS address: $address"
			return 1
		fi
	done
	case "$kind" in
		openvpn) ;;
		wireguard)
			for address in "$@"; do
				joined+="${joined:+, }$address"
			done
			replacement=("DNS = $joined")
			;;
		*)
			echo "Error: Unsupported DNS directive type: $kind"
			return 1
			;;
	esac

	directory=${path%/*}
	[[ "$directory" != "$path" ]] || directory=.
	temporary="$(mktemp "$directory/.${path##*/}.XXXXXX.tmp")" || return 1
	while true; do
		if IFS= read -r line; then
			read_status=0
		else
			read_status=$?
		fi
		if (( read_status != 0 )) && [[ -z "$line" ]]; then
			break
		fi

		normalized=${line%$'\r'}
		trimmed="${normalized#"${normalized%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		managed=n
		if [[ "$kind" == 'openvpn' && "$trimmed" =~ ^push\ \"dhcp-option\ DNS6?\ .*\"$ ]]; then
			managed=y
		elif [[ "$kind" == 'wireguard' && "$trimmed" =~ ^DNS\ = ]]; then
			managed=y
		fi

		if [[ "$managed" == 'y' ]]; then
			if [[ "$inserted" != 'y' ]]; then
				newline=$'\n'
				[[ "$line" == *$'\r' ]] && newline=$'\r\n'
				printf '%s%s' "${replacement[0]}" "$newline" >> "$temporary" || {
					rm -f -- "$temporary"
					return 1
				}
				for address in "${replacement[@]:1}"; do
					printf '%s%s' "$address" "$newline" >> "$temporary" || {
						rm -f -- "$temporary"
						return 1
					}
				done
				inserted=y
			fi
		else
			printf '%s' "$line" >> "$temporary" || {
				rm -f -- "$temporary"
				return 1
			}
			if (( read_status == 0 )) && ! printf '\n' >> "$temporary"; then
				rm -f -- "$temporary"
				return 1
			fi
		fi
		(( read_status == 0 )) || break
	done < "$path"

	if [[ "$inserted" != 'y' ]]; then
		rm -f -- "$temporary"
		echo "Error: Managed DNS directive not found in $path"
		return 1
	fi
	if cmp -s -- "$temporary" "$path"; then
		rm -f -- "$temporary"
		return 0
	fi
	chmod --reference="$path" "$temporary" || {
		rm -f -- "$temporary"
		return 1
	}
	sync -f "$temporary" || {
		rm -f -- "$temporary"
		return 1
	}
	mv -f -- "$temporary" "$path" || {
		rm -f -- "$temporary"
		return 1
	}
}

configure_installed_dns() {
	local anti_udp=("$IP.29.0.1")
	local anti_tcp=("$IP.29.4.1")
	local anti_wireguard=("$IP.29.8.1")
	local vpn_udp vpn_tcp vpn_wireguard

	if [[ "$DISABLE_IPV6" != 'y' ]]; then
		anti_udp+=("$ANTIZAPRET_UDP_DNS6")
		anti_tcp+=("$ANTIZAPRET_TCP_DNS6")
		anti_wireguard+=("$ANTIZAPRET_WG_DNS6")
	fi

	if [[ "$VPN_DNS" == '1' ]]; then
		vpn_udp=("$IP.28.0.1")
		vpn_tcp=("$IP.28.4.1")
		vpn_wireguard=("$IP.28.8.1")
		if [[ "$DISABLE_IPV6" != 'y' ]]; then
			vpn_udp+=("$VPN_UDP_DNS6")
			vpn_tcp+=("$VPN_TCP_DNS6")
			vpn_wireguard+=("$VPN_WG_DNS6")
		fi
	else
		vpn_udp=("${VPN_CLIENT_DNS[@]}")
		vpn_tcp=("${VPN_CLIENT_DNS[@]}")
		vpn_wireguard=("${VPN_CLIENT_DNS[@]}")
	fi

	set_dns_directives openvpn /etc/openvpn/server/antizapret-udp.conf "${anti_udp[@]}"
	set_dns_directives openvpn /etc/openvpn/server/antizapret-tcp.conf "${anti_tcp[@]}"
	set_dns_directives openvpn /etc/openvpn/server/vpn-udp.conf "${vpn_udp[@]}"
	set_dns_directives openvpn /etc/openvpn/server/vpn-tcp.conf "${vpn_tcp[@]}"
	set_dns_directives wireguard /etc/wireguard/templates/antizapret-client-wg.conf "${anti_wireguard[@]}"
	set_dns_directives wireguard /etc/wireguard/templates/antizapret-client-am.conf "${anti_wireguard[@]}"
	set_dns_directives wireguard /etc/wireguard/templates/vpn-client-wg.conf "${vpn_wireguard[@]}"
	set_dns_directives wireguard /etc/wireguard/templates/vpn-client-am.conf "${vpn_wireguard[@]}"
}

validate_installed_kresd_config() {
	local instance output run_dir status
	for instance in 1 2; do
		run_dir="$(mktemp -d "/tmp/antizapret-kresd-check.${instance}.XXXXXX")"
		chown knot-resolver:knot-resolver "$run_dir"
		# timeout=124 means kresd stayed alive and accepted the configuration.
		# Keep the expected non-zero status inside a conditional so ERR traps in
		# the caller do not turn a successful probe into an installation failure.
		if output="$(SYSTEMD_INSTANCE="$instance" timeout 3 kresd -n -c /etc/knot-resolver/kresd.conf "$run_dir" 2>&1)"; then
			status=0
		else
			status=$?
		fi
		rm -rf -- "$run_dir"
		if (( status != 124 )); then
			echo "Error: Knot Resolver instance $instance rejected its configuration"
			[[ -z "$output" ]] || echo "$output"
			exit 17
		fi
	done
}

mark_dns6_runtime_ready() {
	local state_dir=/root/antizapret/state
	local marker="$state_dir/dns6-ready"
	local temporary

	mkdir -p "$state_dir"
	if [[ "$DISABLE_IPV6" == 'y' ]]; then
		rm -f -- "$marker"
		return
	fi
	temporary="$(mktemp "$state_dir/.dns6-ready.XXXXXX")"
	printf 'version=1\n' > "$temporary"
	chmod 644 "$temporary"
	mv -f -- "$temporary" "$marker"
}

health_error() {
	echo "Error: Runtime health check failed: $*" >&2
	return 26
}

wait_for_interface_address() {
	local family=$1 interface=$2 expected=$3 attempt

	if [[ "$family" != '4' && "$family" != '6' ]]; then
		health_error "unsupported address family IPv$family for $interface"
	fi
	for (( attempt = 1; attempt <= 10; attempt++ )); do
		if ip -o link show dev "$interface" 2>/dev/null |
			grep -Eq '<([^>]*,)?UP(,[^>]*)?>' &&
			ip "-$family" -o address show dev "$interface" 2>/dev/null |
			awk -v expected="$expected" '
				$4 == expected {
					unusable = 0
					for (field = 5; field <= NF; field++) {
						if ($field == "tentative" || $field == "dadfailed") {
							unusable = 1
						}
					}
					if (!unusable) found = 1
				}
				END { exit !found }
			'
		then
			return 0
		fi
		sleep 1
	done
	health_error "$interface is not UP with IPv$family address $expected"
}

single_openvpn_value() {
	local path=$1 directive=$2

	awk -v directive="$directive" '
		{
			line = $0
			sub(/[;#].*$/, "", line)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
			if (line == "") next
			fields = split(line, token, /[[:space:]]+/)
			if (token[1] != directive) next
			matches++
			if (fields != 2) malformed = 1
			value = token[2]
		}
		END {
			if (matches != 1 || malformed) exit 1
			print value
		}
	' "$path"
}

wait_for_openvpn_listener() {
	local transport=$1 family=$2 port=$3 dual_stack=$4
	local attempt socket_output

	for (( attempt = 1; attempt <= 10; attempt++ )); do
		if [[ "$transport" == 'udp' ]]; then
			socket_output="$(ss -H -lnuep "-$family" "sport = :$port" 2>/dev/null || true)"
		else
			socket_output="$(ss -H -lntep "-$family" "sport = :$port" 2>/dev/null || true)"
		fi
		if [[ "$dual_stack" == 'y' ]]; then
			if grep -F '"openvpn"' <<< "$socket_output" | grep -Fq 'v6only:0'; then
				return 0
			fi
		elif grep -Fq '"openvpn"' <<< "$socket_output"; then
			return 0
		fi
		sleep 1
	done
	health_error "OpenVPN has no usable IPv$family $transport listener on port $port"
}

require_openvpn_runtime() {
	local name=$1 transport=$2 ipv4_cidr=$3 ipv6_cidr=$4
	local config="/etc/openvpn/server/$name.conf"
	local expected_proto port proto

	if ! proto="$(single_openvpn_value "$config" proto)"; then
		health_error "$config must contain exactly one valid proto directive"
	fi
	if ! port="$(single_openvpn_value "$config" port)" ||
		[[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 ))
	then
		health_error "$config must contain exactly one valid port directive"
	fi
	if [[ "$DISABLE_IPV6" == 'y' ]]; then
		[[ "$transport" == 'udp' ]] && expected_proto=udp4 || expected_proto=tcp4
		if [[ "${proto,,}" != "$expected_proto" ]]; then
			health_error "$config uses proto $proto instead of $expected_proto"
		fi
		wait_for_interface_address 4 "$name" "$ipv4_cidr"
		wait_for_openvpn_listener "$transport" 4 "$port" n
	else
		[[ "$transport" == 'udp' ]] && expected_proto=udp6 || expected_proto=tcp6-server
		if [[ "${proto,,}" != "$expected_proto" ]]; then
			health_error "$config uses proto $proto instead of $expected_proto"
		fi
		wait_for_interface_address 4 "$name" "$ipv4_cidr"
		wait_for_interface_address 6 "$name" "$ipv6_cidr"
		wait_for_openvpn_listener "$transport" 6 "$port" y
	fi
}

require_wireguard_runtime() {
	local interface=$1 port=$2 ipv4_cidr=$3 ipv6_cidr=$4
	local actual_port ipv4_socket=n ipv6_socket=n

	wait_for_interface_address 4 "$interface" "$ipv4_cidr"
	if ! actual_port="$(wg show "$interface" listen-port 2>/dev/null)" ||
		[[ "$actual_port" != "$port" ]]
	then
		health_error "$interface is not listening on WireGuard port $port"
	fi
	if [[ "$DISABLE_IPV6" == 'y' ]]; then
		return 0
	fi
	wait_for_interface_address 6 "$interface" "$ipv6_cidr"
	if ss -H -lnu -4 "sport = :$port" 2>/dev/null | grep -q .; then
		ipv4_socket=y
	fi
	if ss -H -lnu -6 "sport = :$port" 2>/dev/null | grep -q .; then
		ipv6_socket=y
	fi
	# Kernel WireGuard sockets are not visible in every ss build. If one family
	# is visible, the other one must be visible too.
	if [[ "$ipv4_socket" != "$ipv6_socket" ]]; then
		health_error "$interface WireGuard socket is not dual-stack on port $port"
	fi
}

require_ip6tables_rule() {
	local table=$1 chain=$2
	shift 2
	if ! ip6tables -w -t "$table" -C "$chain" "$@" 2>/dev/null; then
		health_error "missing ip6tables $table/$chain rule: $*"
	fi
}

require_dns6_dnat() {
	local interface=$1 destination=$2 protocol
	for protocol in udp tcp; do
		require_ip6tables_rule nat ANTIZAPRET6-PREROUTING \
			-i "$interface" -p "$protocol" --dport 53 \
			-j DNAT --to-destination "$destination"
	done
}

require_firewall6_runtime() {
	local set_name

	[[ -f /root/antizapret/state/dns6-ready ]] ||
		health_error 'IPv6 DNS runtime marker is missing'
	require_ip6tables_rule filter INPUT -j ANTIZAPRET6-INPUT
	require_ip6tables_rule filter FORWARD -j ANTIZAPRET6-FORWARD
	require_ip6tables_rule filter OUTPUT -j ANTIZAPRET6-OUTPUT
	require_ip6tables_rule mangle PREROUTING -j ANTIZAPRET6-MARK
	require_ip6tables_rule nat PREROUTING -j ANTIZAPRET6-PREROUTING
	require_ip6tables_rule nat POSTROUTING -j ANTIZAPRET6-POSTROUTING
	if ! ip6tables -w -t nat -S ANTIZAPRET6-MAPPING &>/dev/null; then
		health_error 'missing ip6tables nat/ANTIZAPRET6-MAPPING chain'
	fi
	for set_name in antizapret-allow6 antizapret-deny6 antizapret-drop6 antizapret-forward6; do
		if ! ipset list "$set_name" 2>/dev/null |
			grep -Eq '^Header:.*family inet6([[:space:]]|$)'
		then
			health_error "missing inet6 ipset $set_name"
		fi
	done
}

require_firewall6_disabled() {
	local jump table chain target
	local jumps=(
		'filter INPUT ANTIZAPRET6-INPUT'
		'filter FORWARD ANTIZAPRET6-FORWARD'
		'filter OUTPUT ANTIZAPRET6-OUTPUT'
		'mangle PREROUTING ANTIZAPRET6-MARK'
		'nat PREROUTING ANTIZAPRET6-PREROUTING'
		'nat POSTROUTING ANTIZAPRET6-POSTROUTING'
	)

	[[ ! -e /root/antizapret/state/dns6-ready ]] ||
		health_error 'IPv6 DNS runtime marker exists while IPv6 is disabled'
	for jump in "${jumps[@]}"; do
		read -r table chain target <<< "$jump"
		if ip6tables -w -t "$table" -C "$chain" -j "$target" 2>/dev/null; then
			health_error "ip6tables jump to $target remains while IPv6 is disabled"
		fi
	done
}

dns_append_byte() {
	local value=$1 escaped

	printf -v escaped '\\%03o' "$value"
	printf '%b' "$escaped"
}

dns_append_u16() {
	dns_append_byte "$(( ($1 >> 8) & 255 ))"
	dns_append_byte "$(( $1 & 255 ))"
}

dns_build_query() {
	local destination=$1 identifier=$2 name=${3%.} query_type_name=$4
	local label query_type
	local -a labels=()

	case "$query_type_name" in
		A) query_type=1 ;;
		AAAA) query_type=28 ;;
		*) return 1 ;;
	esac
	[[ -n "$name" && ${#name} -le 253 ]] || return 1
	IFS=. read -r -a labels <<< "$name"
	(( ${#labels[@]} > 0 )) || return 1
	for label in "${labels[@]}"; do
		[[ -n "$label" && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
	done

	: > "$destination" || return 1
	{
		dns_append_u16 "$identifier" || return 1
		dns_append_u16 256 || return 1
		dns_append_u16 1 || return 1
		dns_append_u16 0 || return 1
		dns_append_u16 0 || return 1
		dns_append_u16 0 || return 1
		for label in "${labels[@]}"; do
			dns_append_byte "${#label}" || return 1
			printf '%s' "$label" || return 1
		done
		dns_append_byte 0 || return 1
		dns_append_u16 "$query_type" || return 1
		dns_append_u16 1 || return 1
	} >> "$destination"
}

dns_load_file_bytes() {
	local target_name=$1 path=$2
	local -n target=$target_name

	read -r -a target <<< "$(od -An -v -tu1 -- "$path" | tr '\n' ' ')"
	(( ${#target[@]} > 0 ))
}

dns_skip_name() {
	local packet_name=$1 offset=$2 limit=$3 length
	local -n packet=$packet_name

	while (( offset < limit )); do
		length=${packet[offset]}
		if (( (length & 192) == 192 )); then
			(( offset + 2 <= limit )) || return 1
			DNS_OFFSET=$((offset + 2))
			return 0
		fi
		(( (length & 192) == 0 )) || return 1
		offset=$((offset + 1))
		if (( length == 0 )); then
			DNS_OFFSET=$offset
			return 0
		fi
		(( length <= 63 && offset + length <= limit )) || return 1
		offset=$((offset + length))
	done
	return 1
}

dns_address_hex() {
	local query_type_name=$1 address=$2 hextet octet
	local -a values=()

	DNS_ADDRESS_HEX=
	case "$query_type_name" in
		A)
			is_ipv4_address "$address" || return 1
			IFS=. read -r -a values <<< "$address"
			for octet in "${values[@]}"; do
				printf -v DNS_ADDRESS_HEX '%s%02x' "$DNS_ADDRESS_HEX" "$((10#$octet))"
			done
			;;
		AAAA)
			is_ipv6_address "$address" || return 1
			IFS=: read -r -a values <<< "$IPV6_EXPANDED_ADDRESS"
			for hextet in "${values[@]}"; do
				printf -v DNS_ADDRESS_HEX '%s%04x' "$DNS_ADDRESS_HEX" "$((16#$hextet))"
			done
			;;
		*) return 1 ;;
	esac
}

dns_validate_response() {
	local response_path=$1 query_path=$2 identifier=$3 query_type_name=$4 expected=$5 transport=$6
	local answers base=0 data_hex='' data_length flags i limit matched=n offset
	local query_type questions record_class record_type response_identifier tcp_length
	local -a query_bytes=() response_bytes=()

	dns_load_file_bytes response_bytes "$response_path" || return 1
	dns_load_file_bytes query_bytes "$query_path" || return 1
	if [[ "$transport" == 'tcp' ]]; then
		(( ${#response_bytes[@]} >= 2 )) || return 1
		tcp_length=$((response_bytes[0] * 256 + response_bytes[1]))
		(( ${#response_bytes[@]} >= tcp_length + 2 )) || return 1
		base=2
		limit=$((tcp_length + 2))
	else
		limit=${#response_bytes[@]}
	fi
	(( limit >= base + 12 )) || return 1

	response_identifier=$((response_bytes[base] * 256 + response_bytes[base + 1]))
	flags=$((response_bytes[base + 2] * 256 + response_bytes[base + 3]))
	questions=$((response_bytes[base + 4] * 256 + response_bytes[base + 5]))
	answers=$((response_bytes[base + 6] * 256 + response_bytes[base + 7]))
	(( response_identifier == identifier )) || return 1
	(( (flags & 32768) != 0 && (flags & 15) == 0 )) || return 1
	(( questions == 1 && answers > 0 )) || return 1

	(( limit >= base + ${#query_bytes[@]} )) || return 1
	for ((i = 12; i < ${#query_bytes[@]}; i++)); do
		(( response_bytes[base + i] == query_bytes[i] )) || return 1
	done
	offset=$((base + ${#query_bytes[@]}))
	[[ "$query_type_name" == 'AAAA' ]] && query_type=28 || query_type=1
	if [[ -n "$expected" ]]; then
		dns_address_hex "$query_type_name" "$expected" || return 1
	fi

	for ((i = 0; i < answers; i++)); do
		dns_skip_name response_bytes "$offset" "$limit" || return 1
		offset=$DNS_OFFSET
		(( offset + 10 <= limit )) || return 1
		record_type=$((response_bytes[offset] * 256 + response_bytes[offset + 1]))
		record_class=$((response_bytes[offset + 2] * 256 + response_bytes[offset + 3]))
		data_length=$((response_bytes[offset + 8] * 256 + response_bytes[offset + 9]))
		offset=$((offset + 10))
		(( offset + data_length <= limit )) || return 1
		if [[ -n "$expected" ]] && (( record_class == 1 && record_type == query_type )); then
			data_hex=
			for ((tcp_length = 0; tcp_length < data_length; tcp_length++)); do
				printf -v data_hex '%s%02x' "$data_hex" "${response_bytes[offset + tcp_length]}"
			done
			[[ "$data_hex" != "$DNS_ADDRESS_HEX" ]] || matched=y
		fi
		offset=$((offset + data_length))
	done
	[[ -z "$expected" || "$matched" == 'y' ]]
}

dns_query_once() {
	local address=$1 name=$2 query_type_name=$3 expected=$4 transport=$5 identifier=$6 directory=$7
	local endpoint packet="$directory/query-$identifier" request="$directory/request-$identifier"
	local response="$directory/response-$identifier" port=${DNS_PROBE_PORT:-53}

	dns_build_query "$packet" "$identifier" "$name" "$query_type_name" || return 1
	if is_ipv6_address "$address"; then
		endpoint="${transport^^}6:[$address]:$port,bind=[$address]"
	elif is_ipv4_address "$address"; then
		endpoint="${transport^^}4:$address:$port,bind=$address"
	else
		return 1
	fi
	if [[ "$transport" == 'tcp' ]]; then
		: > "$request" || return 1
		dns_append_u16 "$(stat -c %s "$packet")" >> "$request" || return 1
		cat "$packet" >> "$request" || return 1
	else
		request=$packet
	fi
	timeout 3 socat -T2 - "$endpoint" < "$request" > "$response" 2>/dev/null || return 1
	dns_validate_response "$response" "$packet" "$identifier" "$query_type_name" "$expected" "$transport"
}

probe_dns_records() {
	local address attempt directory expected identifier name query_index=0 query_type_name success transport

	if (( $# == 0 || $# % 4 != 0 )); then
		echo 'DNS probe requires ADDRESS NAME TYPE EXPECTED groups' >&2
		return 2
	fi
	directory="$(mktemp -d /tmp/antizapret-dns-probe.XXXXXX)" || return 1
	while (( $# > 0 )); do
		address=$1
		name=$2
		query_type_name=$3
		expected=$4
		shift 4
		if [[ "$query_type_name" != 'A' && "$query_type_name" != 'AAAA' ]]; then
			echo "Unsupported DNS query type: $query_type_name" >&2
			rm -rf -- "$directory"
			return 2
		fi
		for transport in udp tcp; do
			success=n
			for attempt in 0 1 2; do
				identifier=$(( ($$ + query_index * 17 + attempt) & 65535 ))
				if dns_query_once "$address" "$name" "$query_type_name" "$expected" "$transport" "$identifier" "$directory"; then
					success=y
					break
				fi
				sleep 0.5
			done
			if [[ "$success" != 'y' ]]; then
				echo "DNS ${transport^^} $name $query_type_name probe failed via $address" >&2
				rm -rf -- "$directory"
				return 1
			fi
			query_index=$((query_index + 1))
		done
	done
	rm -rf -- "$directory"
}

require_dns_runtime() {
	local family

	for family in 4 6; do
		if ss -H -lnut "-$family" 'sport = :53' 2>/dev/null |
			awk '$5 == "*:53" || $5 == "0.0.0.0:53" || $5 == "[::]:53" || $5 == ":::53" { found = 1 } END { exit !found }'
		then
			health_error "wildcard IPv$family DNS listener is active"
		fi
	done
	if ! probe_dns_records "$@"; then
		health_error 'Knot Resolver DNS probe failed'
	fi
}

validate_cutover_runtime() {
	local server_name
	local dns_queries=(
		127.1.1.1 localhost. A ''
		127.2.2.2 localhost. A ''
	)

	server_name="$(hostname)"
	[[ -n "$server_name" ]] || health_error 'system hostname is empty'

	if [[ "$OPENVPN_UDP_ENABLE" == 'y' ]]; then
		require_openvpn_runtime antizapret-udp udp "$IP.29.0.1/22" "$ANTIZAPRET_UDP_DNS6/64"
		require_openvpn_runtime vpn-udp udp "$IP.28.0.1/22" "$VPN_UDP_DNS6/64"
		if [[ "$DISABLE_IPV6" != 'y' ]]; then
			dns_queries+=(
				"$ANTIZAPRET_UDP_DNS6" "$server_name" A "$IP.29.0.1"
				"$ANTIZAPRET_UDP_DNS6" "$server_name" AAAA "$ANTIZAPRET_UDP_DNS6"
			)
			if [[ "$VPN_DNS" == '1' ]]; then
				dns_queries+=(
					"$VPN_UDP_DNS6" "$server_name" A "$IP.28.0.1"
					"$VPN_UDP_DNS6" "$server_name" AAAA "$VPN_UDP_DNS6"
				)
			fi
		fi
	fi
	if [[ "$OPENVPN_TCP_ENABLE" == 'y' ]]; then
		require_openvpn_runtime antizapret-tcp tcp "$IP.29.4.1/22" "$ANTIZAPRET_TCP_DNS6/64"
		require_openvpn_runtime vpn-tcp tcp "$IP.28.4.1/22" "$VPN_TCP_DNS6/64"
		if [[ "$DISABLE_IPV6" != 'y' ]]; then
			dns_queries+=(
				"$ANTIZAPRET_TCP_DNS6" "$server_name" A "$IP.29.4.1"
				"$ANTIZAPRET_TCP_DNS6" "$server_name" AAAA "$ANTIZAPRET_TCP_DNS6"
			)
			if [[ "$VPN_DNS" == '1' ]]; then
				dns_queries+=(
					"$VPN_TCP_DNS6" "$server_name" A "$IP.28.4.1"
					"$VPN_TCP_DNS6" "$server_name" AAAA "$VPN_TCP_DNS6"
				)
			fi
		fi
	fi
	if [[ "$WIREGUARD_ENABLE" == 'y' ]]; then
		require_wireguard_runtime antizapret 51443 "$IP.29.8.1/24" "$ANTIZAPRET_WG_DNS6/64"
		require_wireguard_runtime vpn 51080 "$IP.28.8.1/24" "$VPN_WG_DNS6/64"
		if [[ "$DISABLE_IPV6" != 'y' ]]; then
			dns_queries+=(
				"$ANTIZAPRET_WG_DNS6" "$server_name" A "$IP.29.8.1"
				"$ANTIZAPRET_WG_DNS6" "$server_name" AAAA "$ANTIZAPRET_WG_DNS6"
			)
			if [[ "$VPN_DNS" == '1' ]]; then
				dns_queries+=(
					"$VPN_WG_DNS6" "$server_name" A "$IP.28.8.1"
					"$VPN_WG_DNS6" "$server_name" AAAA "$VPN_WG_DNS6"
				)
			fi
		fi
	fi

	if [[ "$DISABLE_IPV6" == 'y' ]]; then
		require_firewall6_disabled
	else
		require_firewall6_runtime
		if [[ "$OPENVPN_UDP_ENABLE" == 'y' ]]; then
			require_dns6_dnat antizapret-udp "$ANTIZAPRET_UDP_DNS6"
			[[ "$VPN_DNS" != '1' ]] || require_dns6_dnat vpn-udp "$VPN_UDP_DNS6"
		fi
		if [[ "$OPENVPN_TCP_ENABLE" == 'y' ]]; then
			require_dns6_dnat antizapret-tcp "$ANTIZAPRET_TCP_DNS6"
			[[ "$VPN_DNS" != '1' ]] || require_dns6_dnat vpn-tcp "$VPN_TCP_DNS6"
		fi
		if [[ "$WIREGUARD_ENABLE" == 'y' ]]; then
			require_dns6_dnat antizapret "$ANTIZAPRET_WG_DNS6"
			[[ "$VPN_DNS" != '1' ]] || require_dns6_dnat vpn "$VPN_WG_DNS6"
		fi
	fi
	require_dns_runtime "${dns_queries[@]}"
}
# sipcalc is installed on supported systems. On a minimal image perform an
# early structural ULA /48 check, then repeat the authoritative validation
# immediately after the package dependencies are installed.
if command -v sipcalc >/dev/null; then
	if ! validate_vpn_ipv6_prefix "$VPN_IPV6_PREFIX"; then
		exit 14
	fi
elif ! [[ "$VPN_IPV6_PREFIX" =~ ^[Ff][CcDd][0-9A-Fa-f]{2}:[0-9A-Fa-f:]+\/48$ ]]; then
	echo 'Error: VPN IPv6 prefix must be a private ULA /48 network'
	exit 14
fi
echo
echo 'Choose anti-censorship patch for OpenVPN (UDP only):'
echo '    0) None        - Do not install anti-censorship patch, or remove if already installed'
echo '    1) Strong      - Recommended by default'
echo '    2) Error-free  - Use if Strong patch causes connection error, recommended for Mikrotik routers'
until [[ "$OPENVPN_PATCH" =~ ^[0-2]$ ]]; do
	read -rp 'Version choice [0-2]: ' -e -i 1 OPENVPN_PATCH
done
echo
echo 'OpenVPN DCO lowers CPU load, boosts data speeds, and only supports AES-128-GCM, AES-256-GCM and CHACHA20-POLY1305 encryption'
until [[ "$OPENVPN_DCO" =~ ^[yn]$ ]]; do
	read -rp 'Turn on OpenVPN DCO? [y/n]: ' -e -i y OPENVPN_DCO
done
echo
until [[ "$ANTIZAPRET_WARP" =~ ^[yn]$ ]]; do
	read -rp $'Use Cloudflare WARP for \001\e[1;32m\002AntiZapret VPN\e[0m\002 (antizapret-*) outbound traffic? [y/n]: ' -e -i n ANTIZAPRET_WARP
done
echo
until [[ "$VPN_WARP" =~ ^[yn]$ ]]; do
	read -rp $'Use Cloudflare WARP for \001\e[1;32m\002full VPN\e[0m\002 (vpn-*) outbound traffic? [y/n]: ' -e -i n VPN_WARP
done
echo
echo -e 'Choose DNS resolvers for \e[1;32mAntiZapret VPN\e[0m (antizapret-*):'
echo '    1) MSK-IX+NSDI       - Recommended for users located in Russia'
echo '    3) Cloudflare+Quad9  - Public fallback'
echo '    4) Comss **          - More details: https://comss.ru/disqus/page.php?id=7315'
echo '    5) XBox **           - More details: https://xbox-dns.ru'
echo '    6) Malw **           - More details: https://info.dns.malw.link'
echo
echo ' ** - Enable additional proxying and hide this server IP on some internet resources'
echo '      Use only if this server is geolocated in Russia or problems accessing some internet resources'
until [[ "$ANTIZAPRET_DNS" =~ ^[1-6]$ ]]; do
	read -rp 'DNS choice [1,3-6]: ' -e -i 1 ANTIZAPRET_DNS
done
echo
echo -e 'Choose DNS resolvers for \e[1;32mfull VPN\e[0m (vpn-*):'
echo '    1) Self-hosted  - Use previous choice for AntiZapret VPN, recommended by default'
echo '    2) Cloudflare   - Use if default choice fails to resolve domains'
echo '    3) Quad9        - Use if previous choice fails to resolve domains'
echo '    4) Google *     - Use if previous choice fails to resolve domains'
echo '    5) AdGuard *    - Use for blocking ads, trackers, malware and phishing websites'
echo '    6) Comss **     - More details: https://comss.ru/disqus/page.php?id=7315'
echo '    7) XBox **      - More details: https://xbox-dns.ru'
echo '    8) Malw **      - More details: https://info.dns.malw.link'
echo
echo '  * - DNS resolvers support EDNS Client Subnet'
echo ' ** - Enable additional proxying and hide this server IP on some internet resources'
echo '      Use only if this server is geolocated in Russia or problems accessing some internet resources'
until [[ "$VPN_DNS" =~ ^[1-8]$ ]]; do
	read -rp 'DNS choice [1-8]: ' -e -i 1 VPN_DNS
done
echo
until [[ "$BLOCK_ADS" =~ ^[yn]$ ]]; do
	read -rp $'Enable blocking ads, trackers, malware and phishing websites in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002 (antizapret-*) based on AdGuard and OISD rules? [y/n]: ' -e -i y BLOCK_ADS
done
echo
echo 'Default CLIENT IP address range:     10.28.0.0/15'
echo 'Alternative CLIENT IP address range: 172.28.0.0/15'
until [[ "$ALTERNATIVE_CLIENT_IP" =~ ^[yn]$ ]]; do
	read -rp 'Use alternative CLIENT IP address range? [y/n]: ' -e -i n ALTERNATIVE_CLIENT_IP
done
echo
[[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]] && IP=172 || IP=10
echo "Default FAKE IP address range:     $IP.30.0.0/15"
echo 'Alternative FAKE IP address range: 198.18.0.0/15'
until [[ "$ALTERNATIVE_FAKE_IP" =~ ^[yn]$ ]]; do
	read -rp 'Use alternative range of FAKE IP addresses? [y/n]: ' -e -i y ALTERNATIVE_FAKE_IP
done
echo
if command -v sipcalc >/dev/null; then
	DEFAULT_FAKE_IPV6_NETWORK="$(default_fake_ipv6_network "$VPN_IPV6_PREFIX")"
else
	DEFAULT_FAKE_IPV6_NETWORK="ULA /96 derived from $VPN_IPV6_PREFIX"
fi
echo "Default FAKE IPv6 address range:     $DEFAULT_FAKE_IPV6_NETWORK"
echo 'Alternative FAKE IPv6 address range: 2001:2::/48 (benchmarking)'
until [[ "$ALTERNATIVE_FAKE_IPV6" =~ ^[yn]$ ]]; do
	read -rp 'Use alternative range of FAKE IPv6 addresses? [y/n]: ' -e -i y ALTERNATIVE_FAKE_IPV6
done
echo
until [[ "$OPENVPN_BACKUP_TCP" =~ ^[yn]$ ]]; do
	read -rp 'Use TCP ports 80, 443, 504, 508 as backup for OpenVPN connections? [y/n]: ' -e -i n OPENVPN_BACKUP_TCP
done
echo
until [[ "$OPENVPN_BACKUP_UDP" =~ ^[yn]$ ]]; do
	read -rp 'Use UDP ports 80, 443, 504, 508 as backup for OpenVPN connections? [y/n]: ' -e -i y OPENVPN_BACKUP_UDP
done
echo
until [[ "$WIREGUARD_BACKUP" =~ ^[yn]$ ]]; do
	read -rp 'Use UDP ports 540, 580 as backup for WireGuard/AmneziaWG connections? [y/n]: ' -e -i y WIREGUARD_BACKUP
done
echo
until [[ "$OPENVPN_DUPLICATE" =~ ^[yn]$ ]]; do
	read -rp 'Allow multiple clients connecting to OpenVPN using same profile file (*.ovpn)? [y/n]: ' -e -i y OPENVPN_DUPLICATE
done
echo
until [[ "$OPENVPN_LOG" =~ ^[yn]$ ]]; do
	read -rp 'Enable detailed logs in OpenVPN? [y/n]: ' -e -i n OPENVPN_LOG
done
echo
echo 'Warning! SSH protection may block your IP after 5 logins/minute!'
until [[ "$SSH_PROTECTION" =~ ^[yn]$ ]]; do
	read -rp 'Enable SSH brute-force protection? [y/n]: ' -e -i y SSH_PROTECTION
done
echo
echo 'Warning! Attack protection may block VPN or third-party applications!'
until [[ "$ATTACK_PROTECTION" =~ ^[yn]$ ]]; do
	read -rp 'Enable network attack protection? [y/n]: ' -e -i y ATTACK_PROTECTION
done
echo
echo 'Warning! Scan protection blocks ping and closed-port replies!'
until [[ "$SCAN_PROTECTION" =~ ^[yn]$ ]]; do
	read -rp 'Enable network scan protection? [y/n]: ' -e -i y SCAN_PROTECTION
done
echo
echo 'Warning! Torrent guard blocks VPN traffic for 1 minute on torrent detection!'
until [[ "$TORRENT_GUARD" =~ ^[yn]$ ]]; do
	read -rp $'Enable torrent guard for \001\e[1;32m\002full VPN\001\e[0m\002? [y/n]: ' -e -i y TORRENT_GUARD
done
echo
until [[ "$RESTRICT_FORWARD" =~ ^[yn]$ ]]; do
	read -rp $'Restrict forwarding in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002 to IPs from config/forward-ips.txt and result/route-ips.txt? [y/n]: ' -e -i y RESTRICT_FORWARD
done
echo
until [[ "$CLIENT_ISOLATION" =~ ^[yn]$ ]]; do
	read -rp $'Enable \001\e[1;32m\002all VPN\001\e[0m\002 client and server isolation? [y/n]: ' -e -i y CLIENT_ISOLATION
done
echo

normalize_endpoint_host() {
	local host=$1

	if [[ "$host" == \[*\] ]]; then
		host="${host#[}"
		host="${host%]}"
	fi
	printf '%s\n' "$host"
}

endpoint_has_ipv4() {
	getent ahostsv4 "$1" 2>/dev/null | awk 'NF && $1 !~ /:/ { found=1 } END { exit !found }'
}

endpoint_has_native_ipv6() {
	getent ahostsv6 "$1" 2>/dev/null | awk '
		NF && $1 ~ /:/ && tolower($1) !~ /^::ffff:/ { found=1 }
		END { exit !found }
	'
}

endpoint_is_usable() {
	if [[ "$DISABLE_IPV6" == 'y' ]]; then
		endpoint_has_ipv4 "$1"
	else
		endpoint_has_ipv4 "$1" || endpoint_has_native_ipv6 "$1"
	fi
}

warn_endpoint_families() {
	local host=$1 service=$2
	[[ -n "$host" && "$DISABLE_IPV6" != 'y' ]] || return 0
	endpoint_has_ipv4 "$host" || echo "Warning: $service endpoint $host has no IPv4 address"
	endpoint_has_native_ipv6 "$host" || echo "Warning: $service endpoint $host has no native IPv6 address"
}

while read -rp 'Enter a resolvable domain name or IP address for this OpenVPN server, or press Enter to use server IPv4: ' -e OPENVPN_HOST
do
	[[ -z "$OPENVPN_HOST" ]] && break
	OPENVPN_HOST="$(normalize_endpoint_host "$OPENVPN_HOST")"
	endpoint_is_usable "$OPENVPN_HOST" && break
done
warn_endpoint_families "$OPENVPN_HOST" OpenVPN
echo
while read -rp 'Enter a resolvable domain name or IP address for this WireGuard/AmneziaWG server, or press Enter to use server IPv4: ' -e WIREGUARD_HOST
do
	[[ -z "$WIREGUARD_HOST" ]] && break
	WIREGUARD_HOST="$(normalize_endpoint_host "$WIREGUARD_HOST")"
	endpoint_is_usable "$WIREGUARD_HOST" && break
done
warn_endpoint_families "$WIREGUARD_HOST" WireGuard/AmneziaWG
echo
until [[ "$ROUTE_ALL" =~ ^[yn]$ ]]; do
	read -rp $'Route all traffic for domains via \001\e[1;32m\002AntiZapret VPN\001\e[0m\002, excluding Russian domains and domains from config/exclude-hosts.txt? [y/n]: ' -e -i n ROUTE_ALL
done
echo
until [[ "$DISCORD_INCLUDE" =~ ^[yn]$ ]]; do
	read -rp $'Obsolete! Include Discord voice IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n DISCORD_INCLUDE
done
echo
until [[ "$CLOUDFLARE_INCLUDE" =~ ^[yn]$ ]]; do
	read -rp $'Include Cloudflare IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i y CLOUDFLARE_INCLUDE
done
echo
until [[ "$TELEGRAM_INCLUDE" =~ ^[yn]$ ]]; do
	read -rp $'Include Telegram IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i y TELEGRAM_INCLUDE
done
echo
until [[ "$WHATSAPP_INCLUDE" =~ ^[yn]$ ]]; do
	read -rp $'Include WhatsApp IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i y WHATSAPP_INCLUDE
done
echo
until [[ "$ROBLOX_INCLUDE" =~ ^[yn]$ ]]; do
	read -rp $'Include Roblox IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n ROBLOX_INCLUDE
done
echo
#until [[ "$AMAZON_INCLUDE" =~ ^[yn]$ ]]; do
#	read -rp $'Include Amazon IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n AMAZON_INCLUDE
#done
#echo
#until [[ "$HETZNER_INCLUDE" =~ ^[yn]$ ]]; do
#	read -rp $'Include Hetzner IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n HETZNER_INCLUDE
#done
#echo
#until [[ "$DIGITALOCEAN_INCLUDE" =~ ^[yn]$ ]]; do
#	read -rp $'Include DigitalOcean IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n DIGITALOCEAN_INCLUDE
#done
#echo
#until [[ "$OVH_INCLUDE" =~ ^[yn]$ ]]; do
#	read -rp $'Include OVH IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n OVH_INCLUDE
#done
#echo
#until [[ "$GOOGLE_INCLUDE" =~ ^[yn]$ ]]; do
#	read -rp $'Include Google IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n GOOGLE_INCLUDE
#done
#echo
#until [[ "$AKAMAI_INCLUDE" =~ ^[yn]$ ]]; do
#	read -rp $'Include Akamai IPs in \001\e[1;32m\002AntiZapret VPN\001\e[0m\002? [y/n]: ' -e -i n AKAMAI_INCLUDE
#done
#echo
echo 'Installation, please wait...'

handle_error() {
	local status=$1 line=$2 command=$3
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $line: $command\e[0m"
	exit "$status"
}

trap 'finish_install_transaction $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'handle_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
set -Ee

# Старые установки могли оставить ключи с широкими правами. Зажимаем их до
# snapshot, чтобы rollback тоже не сохранил небезопасные режимы.
require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard

if ! begin_install_transaction; then
	exit 18
fi

# Writers were stopped and checked before the filesystem snapshot. Keep them
# stopped until the new runtime has passed the cutover checks.

# Repair/cleanup package operations are inside the rollback window: package
# postinst scripts cannot restart a half-replaced VPN/DNS configuration.
dpkg --configure -a >/dev/null
apt-get install -f -y >/dev/null
apt-get clean >/dev/null
if [[ "$BIRD_WAS_AUTO" == 'y' ]]; then
	apt-mark manual bird2 >/dev/null
fi
apt-get autoremove --purge -y >/dev/null
if [[ "$BIRD_WAS_AUTO" == 'y' ]]; then
	apt-mark auto bird2 >/dev/null
fi

# Удалим ненужные службы
apt-get purge -y ufw
apt-get purge -y firewalld
apt-get purge -y apparmor
apt-get purge -y apport
apt-get purge -y modemmanager
apt-get purge -y snapd
apt-get purge -y upower
apt-get purge -y multipath-tools
apt-get purge -y rsyslog
apt-get purge -y udisks2
apt-get purge -y qemu-guest-agent
apt-get purge -y tuned
apt-get purge -y sysstat
apt-get purge -y acpid
apt-get purge -y fwupd
apt-get purge -y watchdog
apt-get purge -y pcscd
apt-get purge -y packagekit

# SSH protection включён
if [[ "$SSH_PROTECTION" == 'y' ]]; then
	apt-get purge -y fail2ban || true
	apt-get purge -y sshguard || true
fi

# Сохраняем персональные OpenVPN CCD-файлы с маршрутизируемыми IPv6-префиксами.
OPENVPN_CCD_STAGING=/tmp/antizapret-openvpn-ccd
rm -rf "$OPENVPN_CCD_STAGING"
mkdir -p "$OPENVPN_CCD_STAGING/ccd" "$OPENVPN_CCD_STAGING/ccd2"
if [[ -d /etc/openvpn/server/ccd ]]; then
	find /etc/openvpn/server/ccd -maxdepth 1 -type f ! -name DEFAULT -exec cp -a -t "$OPENVPN_CCD_STAGING/ccd" -- {} +
fi
if [[ -d /etc/openvpn/server/ccd2 ]]; then
	find /etc/openvpn/server/ccd2 -maxdepth 1 -type f ! -name DEFAULT -exec cp -a -t "$OPENVPN_CCD_STAGING/ccd2" -- {} +
fi

# Обновляем систему
rm -rf /etc/apt/sources.list.d/cznic-labs-knot-resolver.list
rm -rf /etc/apt/sources.list.d/openvpn-aptrepo.list
rm -rf /etc/apt/sources.list.d/backports.list
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y
apt-get install -y curl gpg

# Папка для ключей
mkdir -p /etc/apt/keyrings

# Добавим репозиторий Knot Resolver
curl -fL --connect-timeout 30 https://pkg.labs.nic.cz/gpg -o /etc/apt/keyrings/cznic-labs-pkg.gpg
echo "deb [signed-by=/etc/apt/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/knot-resolver $CODENAME main" > /etc/apt/sources.list.d/cznic-labs-knot-resolver.list

# Добавим репозиторий OpenVPN
curl -fL --connect-timeout 30 https://swupdate.openvpn.net/repos/repo-public.gpg | gpg --yes --dearmor -o /etc/apt/keyrings/openvpn-repo-public.gpg
echo "deb [signed-by=/etc/apt/keyrings/openvpn-repo-public.gpg] https://build.openvpn.net/debian/openvpn/release/2.7 $CODENAME main" > /etc/apt/sources.list.d/openvpn-aptrepo.list

# Добавим репозиторий Debian Backports
if [[ "$OS" == 'debian' ]]; then
	echo "deb http://deb.debian.org/debian $CODENAME-backports main" > /etc/apt/sources.list.d/backports.list
fi

# Ставим необходимое ядро и пакеты
apt-get update
INSTALL=
# Обновляем ядро только на Ubuntu ниже 26 и Debian ниже 14
if [[ "$OS" == 'ubuntu' ]] && (( VERSION < 26 )); then
	INSTALL="linux-generic-hwe-${VERSION}.04"
elif [[ "$OS" == 'debian' ]] && (( VERSION < 14 )); then
	INSTALL="-t $CODENAME-backports linux-image-$ARCH linux-headers-$ARCH"
fi
BGP_PACKAGE=
[[ "$BGP_ENABLE" == 'y' ]] && BGP_PACKAGE=bird2
OPENVPN_DCO_PACKAGES=()
if [[ "$OPENVPN_DCO" == 'y' ]]; then
	OPENVPN_DCO_PACKAGES=(ovpn-dkms "linux-headers-$(uname -r)")
fi
OPENVPN_PATCH_PACKAGES=()
if [[ "$OPENVPN_PATCH" != '0' ]]; then
	OPENVPN_PATCH_PACKAGES=(tar build-essential pkg-config libssl-dev libsystemd-dev libnl-genl-3-dev libcap-ng-dev)
fi
apt-get install -y $INSTALL $BGP_PACKAGE git openvpn iptables easy-rsa gawk knot-resolver idn sipcalc python3 wireguard diffutils socat lua-cqueues ipset irqbalance unattended-upgrades jq ethtool iproute2 logrotate "${OPENVPN_DCO_PACKAGES[@]}" "${OPENVPN_PATCH_PACKAGES[@]}"
if [[ "$OPENVPN_DCO" == 'y' ]]; then
	depmod -a
	if ! modprobe ovpn; then
		echo 'Error: OpenVPN DCO was requested, but the ovpn kernel module is unavailable'
		exit 20
	fi
fi
if ! validate_vpn_ipv6_prefix "$VPN_IPV6_PREFIX"; then
	exit 14
fi
derive_vpn_ipv6_layout
select_dns_addresses
if [[ "$BGP_ENABLE" == 'y' && "$BIRD_WAS_INSTALLED" == 'n' ]]; then
	# The distribution unit is not used; AntiZapret has an isolated instance.
	systemctl disable --now bird.service || true
fi
if [[ "$BGP_ENABLE" == 'y' ]] && ss -H -ltn 'sport = :179' | grep -q .; then
	echo 'Error: TCP port 179 is already used by another BGP service!'
	exit 12
fi
if [[ "$BGP_ENABLE" != 'y' && "$BIRD_WAS_AUTO" == 'y' ]]; then
	apt-mark manual bird2 >/dev/null
fi
apt-get autoremove --purge -y
if [[ "$BGP_ENABLE" != 'y' && "$BIRD_WAS_AUTO" == 'y' ]]; then
	apt-mark auto bird2 >/dev/null
fi
apt-get clean
dpkg-reconfigure -f noninteractive unattended-upgrades

# Package postinst may re-arm timers stopped before the snapshot.
if ! stop_and_verify_install_maintenance_units; then
	echo 'Error: Package installation left maintenance writers active'
	exit 19
fi

if ! snapshot_install_transaction_late_paths; then
	echo 'Error: Cannot preserve the installed Knot Resolver modules'
	exit 24
fi

# Клонируем dnslib. Пакет положим в runtime-дерево, не в root site-packages.
rm -rf /tmp/dnslib
git clone https://github.com/paulc/dnslib.git /tmp/dnslib

# Клонируем репозиторий antizapret
rm -rf /tmp/antizapret
git clone https://github.com/Nessusd/AntiZapret-VPN-ipv6.git /tmp/antizapret
if [[ ! -d /tmp/dnslib/dnslib ]]; then
	echo 'Error: dnslib package directory is missing'
	exit 20
fi
rm -rf /tmp/antizapret/setup/root/antizapret/dnslib
cp -a /tmp/dnslib/dnslib /tmp/antizapret/setup/root/antizapret/dnslib

# A disabled BGP option must not install any BGP runtime files.
if [[ "$BGP_ENABLE" != 'y' ]]; then
	rm -f /tmp/antizapret/setup/root/antizapret/bgp-update.py
	rm -f /tmp/antizapret/setup/root/antizapret/bgp-firewall.sh
	rm -f /tmp/antizapret/setup/etc/systemd/system/antizapret-bgp.service
fi

# Сохраняем пользовательские настройки и обработчики custom*.sh
cp /root/antizapret/config/*.txt /tmp/antizapret/setup/root/antizapret/config/ || true
cp /root/antizapret/custom*.sh /tmp/antizapret/setup/root/antizapret/ || true
cp /etc/knot-resolver/*.lua /tmp/antizapret/setup/etc/knot-resolver/ || true

# Восстанавливаем из единственного проверенного архива в отдельный staging.
# Без архива сохраняется совместимость с заранее распакованными каталогами в /root.
BACKUP_STAGING=
RESTORE_ROOT=/root
if [[ -n "$BACKUP_ARCHIVE" ]]; then
	BACKUP_STAGING="$(mktemp -d /tmp/antizapret-backup.XXXXXX)"
	if ! tar -xzf "$BACKUP_ARCHIVE" -C "$BACKUP_STAGING" --no-same-owner --no-same-permissions; then
		rm -rf -- "$BACKUP_STAGING"
		BACKUP_STAGING=
		echo "Error: Cannot extract backup archive: $BACKUP_ARCHIVE"
		exit 13
	fi
	RESTORE_ROOT="$BACKUP_STAGING"
	if [[ ! -d "$RESTORE_ROOT/easyrsa3" && ! -d "$RESTORE_ROOT/openvpn-ccd" && ! -d "$RESTORE_ROOT/wireguard" && ! -d "$RESTORE_ROOT/config" && ! -d "$RESTORE_ROOT/knot-resolver" && ! -d "$RESTORE_ROOT/custom" ]]; then
		rm -rf -- "$BACKUP_STAGING"
		BACKUP_STAGING=
		echo "Error: Backup archive contains no supported configuration directories: $BACKUP_ARCHIVE"
		exit 13
	fi
fi

mkdir -p /tmp/antizapret/setup/etc/openvpn/server/ccd /tmp/antizapret/setup/etc/openvpn/server/ccd2
require_vpn_key_permissions "$RESTORE_ROOT/easyrsa3" "$RESTORE_ROOT/wireguard"
if [[ -d "$RESTORE_ROOT/easyrsa3" ]]; then
	cp -a "$RESTORE_ROOT/easyrsa3/." /tmp/antizapret/setup/etc/openvpn/easyrsa3/
fi
if [[ -d "$OPENVPN_CCD_STAGING/ccd" ]]; then
	cp -a "$OPENVPN_CCD_STAGING/ccd/." /tmp/antizapret/setup/etc/openvpn/server/ccd/
fi
if [[ -d "$OPENVPN_CCD_STAGING/ccd2" ]]; then
	cp -a "$OPENVPN_CCD_STAGING/ccd2/." /tmp/antizapret/setup/etc/openvpn/server/ccd2/
fi
if [[ -d "$RESTORE_ROOT/openvpn-ccd/ccd" ]]; then
	cp -a "$RESTORE_ROOT/openvpn-ccd/ccd/." /tmp/antizapret/setup/etc/openvpn/server/ccd/
fi
if [[ -d "$RESTORE_ROOT/openvpn-ccd/ccd2" ]]; then
	cp -a "$RESTORE_ROOT/openvpn-ccd/ccd2/." /tmp/antizapret/setup/etc/openvpn/server/ccd2/
fi
if [[ -d "$RESTORE_ROOT/wireguard" ]]; then
	cp -a "$RESTORE_ROOT/wireguard/." /tmp/antizapret/setup/etc/wireguard/
fi
if [[ -d "$RESTORE_ROOT/config" ]]; then
	cp -a "$RESTORE_ROOT/config/." /tmp/antizapret/setup/root/antizapret/config/
fi
if [[ -d "$RESTORE_ROOT/knot-resolver" ]]; then
	cp -a "$RESTORE_ROOT/knot-resolver/." /tmp/antizapret/setup/etc/knot-resolver/
fi
if [[ -d "$RESTORE_ROOT/custom" ]]; then
	cp -a "$RESTORE_ROOT/custom/." /tmp/antizapret/setup/root/antizapret/
fi
require_vpn_key_permissions \
	/tmp/antizapret/setup/etc/openvpn/easyrsa3 \
	/tmp/antizapret/setup/etc/wireguard

# Сохраняем настройки
echo "SETUP_DATE=$(date --iso-8601=seconds)
OPENVPN_UDP_ENABLE=$OPENVPN_UDP_ENABLE
OPENVPN_TCP_ENABLE=$OPENVPN_TCP_ENABLE
WIREGUARD_ENABLE=$WIREGUARD_ENABLE
BGP_ENABLE=$BGP_ENABLE
BGP_SERVER_ASN=$BGP_SERVER_ASN
BGP_CLIENT_ASN=$BGP_CLIENT_ASN
DISABLE_IPV6=$DISABLE_IPV6
VPN_IPV6_PREFIX=$VPN_IPV6_PREFIX
ANTIZAPRET_UDP_NETWORK6=$ANTIZAPRET_UDP_NETWORK6
ANTIZAPRET_UDP_DNS6=$ANTIZAPRET_UDP_DNS6
ANTIZAPRET_TCP_NETWORK6=$ANTIZAPRET_TCP_NETWORK6
ANTIZAPRET_TCP_DNS6=$ANTIZAPRET_TCP_DNS6
ANTIZAPRET_WG_NETWORK6=$ANTIZAPRET_WG_NETWORK6
ANTIZAPRET_WG_DNS6=$ANTIZAPRET_WG_DNS6
VPN_UDP_NETWORK6=$VPN_UDP_NETWORK6
VPN_UDP_DNS6=$VPN_UDP_DNS6
VPN_TCP_NETWORK6=$VPN_TCP_NETWORK6
VPN_TCP_DNS6=$VPN_TCP_DNS6
VPN_WG_NETWORK6=$VPN_WG_NETWORK6
VPN_WG_DNS6=$VPN_WG_DNS6
OPENVPN_PATCH=$OPENVPN_PATCH
OPENVPN_DCO=$OPENVPN_DCO
ANTIZAPRET_WARP=$ANTIZAPRET_WARP
VPN_WARP=$VPN_WARP
ANTIZAPRET_DNS=$ANTIZAPRET_DNS
VPN_DNS=$VPN_DNS
BLOCK_ADS=$BLOCK_ADS
ALTERNATIVE_CLIENT_IP=$ALTERNATIVE_CLIENT_IP
ALTERNATIVE_FAKE_IP=$ALTERNATIVE_FAKE_IP
ALTERNATIVE_FAKE_IPV6=$ALTERNATIVE_FAKE_IPV6
OPENVPN_BACKUP_TCP=$OPENVPN_BACKUP_TCP
OPENVPN_BACKUP_UDP=$OPENVPN_BACKUP_UDP
WIREGUARD_BACKUP=$WIREGUARD_BACKUP
OPENVPN_DUPLICATE=$OPENVPN_DUPLICATE
OPENVPN_LOG=$OPENVPN_LOG
SSH_PROTECTION=$SSH_PROTECTION
ATTACK_PROTECTION=$ATTACK_PROTECTION
SCAN_PROTECTION=$SCAN_PROTECTION
TORRENT_GUARD=$TORRENT_GUARD
RESTRICT_FORWARD=$RESTRICT_FORWARD
CLIENT_ISOLATION=$CLIENT_ISOLATION
OPENVPN_HOST=$OPENVPN_HOST
WIREGUARD_HOST=$WIREGUARD_HOST
ROUTE_ALL=$ROUTE_ALL
DISCORD_INCLUDE=$DISCORD_INCLUDE
CLOUDFLARE_INCLUDE=$CLOUDFLARE_INCLUDE
TELEGRAM_INCLUDE=$TELEGRAM_INCLUDE
WHATSAPP_INCLUDE=$WHATSAPP_INCLUDE
ROBLOX_INCLUDE=$ROBLOX_INCLUDE
AMAZON_INCLUDE=$AMAZON_INCLUDE
HETZNER_INCLUDE=$HETZNER_INCLUDE
DIGITALOCEAN_INCLUDE=$DIGITALOCEAN_INCLUDE
OVH_INCLUDE=$OVH_INCLUDE
GOOGLE_INCLUDE=$GOOGLE_INCLUDE
AKAMAI_INCLUDE=$AKAMAI_INCLUDE
CLEAR_HOSTS=y
TXQUEUELEN=1000
MTU=1420
SEGMENTATION_OFFLOAD=off
DEFAULT_INTERFACE=
DEFAULT_IP=
ANTIZAPRET_OUT_INTERFACE=
ANTIZAPRET_OUT_IP=
VPN_OUT_INTERFACE=
VPN_OUT_IP=
CLIENT_IP=
FAKE_IP=" > /tmp/antizapret/setup/root/antizapret/setup

# Создаем папки для кэша Knot Resolver
mkdir -p /var/cache/knot-resolver
mkdir -p /var/cache/knot-resolver2

# Выставляем разрешения
find /tmp/antizapret \
	\( -path '/tmp/antizapret/setup/etc/openvpn/easyrsa3/*.creds' -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/inline -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/renewed/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/renewed/private_by_serial -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/revoked/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/revoked/private_by_serial -o \
	   -path '/tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/*.creds' -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/inline -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/renewed/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/renewed/private_by_serial -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/revoked/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/revoked/private_by_serial -o \
	   -path /tmp/antizapret/setup/etc/wireguard \) -prune -o \
	-type f -exec chmod 644 {} +
find /tmp/antizapret \
	\( -path '/tmp/antizapret/setup/etc/openvpn/easyrsa3/*.creds' -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/inline -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/renewed/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/renewed/private_by_serial -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/revoked/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/revoked/private_by_serial -o \
	   -path '/tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/*.creds' -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/inline -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/renewed/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/renewed/private_by_serial -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/revoked/private -o \
	   -path /tmp/antizapret/setup/etc/openvpn/easyrsa3/pki/revoked/private_by_serial -o \
	   -path /tmp/antizapret/setup/etc/wireguard \) -prune -o \
	-type d -exec chmod 755 {} +
find /tmp/antizapret/setup/root/antizapret -type f -exec chmod +x {} +
find /tmp/antizapret/setup/etc/openvpn/server/scripts -type f -exec chmod +x {} +
chown -R knot-resolver:knot-resolver /var/cache/knot-resolver
chown -R knot-resolver:knot-resolver /var/cache/knot-resolver2

# Штатный stop вызовет старый custom-down, пока VPN-интерфейсы ещё живы.
# Сразу после этого гасим сами туннели и начинаем замену live-дерева.
if ! capture_install_rollback_current_vpn_units ||
	! add_install_rollback_vpn_guard current
then
	echo 'Error: Cannot protect active VPN listeners before installation cutover'
	exit 23
fi
systemctl stop antizapret.service >/dev/null 2>&1 || true
if ! verify_install_unit_stopped antizapret.service; then
	echo 'Error: Cannot stop antizapret.service before publishing the new installation'
	exit 23
fi
for unit in \
	openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service \
	openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service \
	wg-quick@antizapret.service wg-quick@vpn.service
do
	systemctl disable --now "$unit" >/dev/null 2>&1 || true
done
for unit in \
	openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service \
	openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service \
	wg-quick@antizapret.service wg-quick@vpn.service
do
	if ! verify_install_unit_stopped "$unit"; then
		echo "Error: Cannot stop $unit before publishing the new installation"
		exit 23
	fi
done

for unit in kresd.target kres-cache-gc.service kresd@1.service kresd@2.service; do
	systemctl stop "$unit" >/dev/null 2>&1 || true
done
for unit in kresd.target kres-cache-gc.service kresd@1.service kresd@2.service; do
	if ! verify_install_unit_stopped "$unit"; then
		echo "Error: Cannot stop $unit before publishing the new installation"
		exit 23
	fi
done
rm -rf /var/cache/knot-resolver/*
rm -rf /var/cache/knot-resolver2/*

# Ранний старт нового firewall не должен дёргать custom hooks
# до возврата VPN-интерфейсов.
rm -f -- "$INSTALL_CUSTOM_HOOK_ENV"
write_install_custom_hook_state deferred

# Удаляем старые файлы OpenVPN и WireGuard.
rm -rf /etc/openvpn/server/*
rm -rf /etc/openvpn/client/*
rm -rf /etc/wireguard/templates/*

# Удаляем скомпилированный патченный OpenVPN.
make -C /usr/local/src/openvpn uninstall || true
rm -f /usr/local/lib/tmpfiles.d/openvpn.conf /usr/local/lib/tmpfiles.d/tmpfiles-openvpn.conf
rm -rf /usr/local/src/openvpn

# Настраиваем IPv6.
IPV6_SYSCTL=/etc/sysctl.d/99-antizapret-ipv6.conf
rm -f /etc/sysctl.d/99-disable-ipv6.conf /etc/sysctl.d/99-proxy-ipv6.conf "$IPV6_SYSCTL"
if [[ "$DISABLE_IPV6" == 'y' ]]; then
	cat > "$IPV6_SYSCTL" <<'EOF'
# IPv6 disabled by AntiZapret installer
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
else
	cat > "$IPV6_SYSCTL" <<EOF
# IPv6 enabled by AntiZapret installer
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net/ipv6/conf/${DEFAULT_INTERFACE}/accept_ra=2
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
fi
if [[ "$DISABLE_IPV6" != 'y' ]]; then
	# disable_ipv6=1 removes live addresses and routes. Apply it only on the
	# final reboot; enabling IPv6 here remains reversible.
	sysctl -p "$IPV6_SYSCTL"
	IPV6_ROUTE_CHECK="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)"
	if ! grep -Eq '(^|[[:space:]])src[[:space:]]+[23][0-9A-Fa-f]*:' <<< "$IPV6_ROUTE_CHECK"; then
		echo 'Warning: No usable public IPv6 route found; IPv6 VPN endpoints and IPv6 DNS upstreams will be unavailable until the server network is configured'
	fi
fi

# Forwarding and the existing IPv4 DNS DNAT must work before the final reboot.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sysctl -w net.ipv4.conf.default.route_localnet=1 >/dev/null

# Удаляем переопределённые параметры ядра.
sed -i '/^$/!{/^#/!d}' /etc/sysctl.conf

# Принудительная загрузка модуля nf_conntrack.
echo 'nf_conntrack' > /etc/modules-load.d/nf_conntrack.conf

# Копируем нужное, удаляем не нужное
rm -rf /root/antizapret
cp -r /tmp/antizapret/setup/* /
require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard
rm -rf /tmp/dnslib
rm -rf /tmp/antizapret

# Одноразовые источники уже опубликованы. Они входят в snapshot и вернутся
# только при rollback; после успешного cutover устаревший backup не останется.
rm -rf /root/easyrsa3
rm -rf /root/wireguard
rm -rf /root/config
rm -rf /root/knot-resolver
rm -rf /root/custom
rm -rf /root/openvpn-ccd
if [[ -n "${BACKUP_STAGING:-}" ]]; then
	rm -rf -- "$BACKUP_STAGING"
	BACKUP_STAGING=
fi
rm -rf -- "$OPENVPN_CCD_STAGING"
OPENVPN_CCD_STAGING=

if [[ "$BGP_ENABLE" == 'y' ]]; then
	mkdir -p /etc/antizapret-bgp /var/lib/antizapret-bgp
	chmod 755 /etc/antizapret-bgp /var/lib/antizapret-bgp
elif [[ "$MANAGED_BGP_PRESENT" == 'y' ]]; then
	# Remove only files and state owned by the AntiZapret BGP instance.
	rm -f /etc/systemd/system/antizapret-bgp.service
	rm -rf /etc/antizapret-bgp /var/lib/antizapret-bgp /run/antizapret-bgp
fi
systemctl daemon-reload

# Upstreams and ULA listeners are generated from the selected settings.  The
# file has no .lua suffix so it is not mistaken for user DNS configuration in
# backups; setup.sh recreates it on every installation.
write_kresd_generated_config

# Не используем альтернативный диапазон подменных IPv4-адресов
# 198.18.0.0/15 => 10.30.0.0/15 или 172.30.0.0/15
if [[ "$ALTERNATIVE_FAKE_IP" == 'n' ]]; then
	sed -i "s/198\.18\./${IP}\.30\./g" /root/antizapret/proxy.py
fi

# Используем альтернативный диапазон клиентских IPv4-адресов
# 10.28.0.0/15 => 172.28.0.0/15
if [[ "$ALTERNATIVE_CLIENT_IP" == 'y' ]]; then
	sed -i 's/10\./172\./g' /etc/knot-resolver/kresd.conf
	sed -i 's/10\./172\./g' /etc/openvpn/server/*.conf
	sed -i 's/10\./172\./g' /etc/wireguard/templates/*.conf
	find /etc/wireguard -name '*.conf' -exec sed -i 's/s = 10\./s = 172\./g' {} +
else
	find /etc/wireguard -name '*.conf' -exec sed -i 's/s = 172\./s = 10\./g' {} +
fi

configure_installed_dns
validate_installed_kresd_config

# Добавляем или удаляем управляемую IPv6-конфигурацию OpenVPN.
[[ "$DISABLE_IPV6" == 'y' ]] && OPENVPN_IPV6_ACTION=strip || OPENVPN_IPV6_ACTION=migrate
for OPENVPN_MODE in antizapret-udp antizapret-tcp vpn-udp vpn-tcp; do
	python3 /root/antizapret/openvpn-ipv6.py --prefix "${VPN_IPV6_PREFIX:-fd3a:c9bc:6bcb::/48}" \
		"$OPENVPN_IPV6_ACTION" "$OPENVPN_MODE" "/etc/openvpn/server/$OPENVPN_MODE.conf" --check >/dev/null
done
for OPENVPN_MODE in antizapret-udp antizapret-tcp vpn-udp vpn-tcp; do
	python3 /root/antizapret/openvpn-ipv6.py --prefix "${VPN_IPV6_PREFIX:-fd3a:c9bc:6bcb::/48}" \
		"$OPENVPN_IPV6_ACTION" "$OPENVPN_MODE" "/etc/openvpn/server/$OPENVPN_MODE.conf" >/dev/null
done

# Запрещаем несколько одновременных подключений к OpenVPN для одного клиента
if [[ "$OPENVPN_DUPLICATE" == 'n' ]]; then
	sed -i '/duplicate-cn/s/^/#/' /etc/openvpn/server/*.conf
fi

# Включим подробные логи в OpenVPN
if [[ "$OPENVPN_LOG" == 'y' ]]; then
	sed -i '/^#\(verb\|log\)/s/^#//' /etc/openvpn/server/*.conf
fi

# Изменяем поведение policy.PASS в Knot Resolver. Незнакомую верстку не патчим.
POLICY_PASS_FILE=/usr/lib/knot-resolver/kres_modules/policy.lua
POLICY_PASS_FUNCTIONS="$(grep -Ec '^[[:space:]]*function policy\.PASS\(state, _\)[[:space:]]*$' "$POLICY_PASS_FILE" || true)"
POLICY_PASS_BLOCK="$(sed -n '/^[[:space:]]*function policy\.PASS(state, _)[[:space:]]*$/,/^[[:space:]]*end[[:space:]]*$/p' "$POLICY_PASS_FILE")"
POLICY_PASS_STATE="$(grep -Ec '^[[:space:]]*return state[[:space:]]*$' <<< "$POLICY_PASS_BLOCK" || true)"
POLICY_PASS_NIL="$(grep -Ec '^[[:space:]]*return nil[[:space:]]*$' <<< "$POLICY_PASS_BLOCK" || true)"
if [[ "$POLICY_PASS_FUNCTIONS" != 1 ]] || (( POLICY_PASS_STATE + POLICY_PASS_NIL != 1 )); then
	echo 'Error: Unsupported Knot Resolver policy.PASS implementation'
	exit 25
fi
sed -i '/^[[:space:]]*function policy\.PASS(state, _)[[:space:]]*$/,/^[[:space:]]*end[[:space:]]*$/s/^[[:space:]]*return state[[:space:]]*$/\treturn nil/' "$POLICY_PASS_FILE"
POLICY_PASS_BLOCK="$(sed -n '/^[[:space:]]*function policy\.PASS(state, _)[[:space:]]*$/,/^[[:space:]]*end[[:space:]]*$/p' "$POLICY_PASS_FILE")"
if [[ "$(grep -Ec '^[[:space:]]*return nil[[:space:]]*$' <<< "$POLICY_PASS_BLOCK" || true)" != 1 ]] ||
	grep -Eq '^[[:space:]]*return state[[:space:]]*$' <<< "$POLICY_PASS_BLOCK"
then
	echo 'Error: Knot Resolver policy.PASS patch verification failed'
	exit 25
fi

mark_dns6_runtime_ready

# Включим обновляемые службы
systemctl enable kresd@1
systemctl enable kresd@2
systemctl enable antizapret
systemctl enable antizapret-update.timer
systemctl enable antizapret-update
systemctl enable logrotate.timer
if [[ "$OPENVPN_UDP_ENABLE" == 'y' ]]; then
	systemctl enable openvpn-server@antizapret-udp
	systemctl enable openvpn-server@vpn-udp
fi
if [[ "$OPENVPN_TCP_ENABLE" == 'y' ]]; then
	systemctl enable openvpn-server@antizapret-tcp
	systemctl enable openvpn-server@vpn-tcp
fi
if [[ "$WIREGUARD_ENABLE" == 'y' ]]; then
	systemctl enable wg-quick@antizapret
	systemctl enable wg-quick@vpn
fi
if [[ "$BGP_ENABLE" == 'y' ]]; then
	systemctl enable antizapret-bgp
fi

# Firewall first. Public VPN listeners are started only after antizapret is up.
systemctl start kresd@1.service kresd@2.service
systemctl start antizapret.service
CORE_CUTOVER_UNITS=(kresd@1.service kresd@2.service antizapret.service)
for unit in kresd.target kres-cache-gc.service; do
	case "${INSTALL_TRANSACTION_ACTIVE[$unit]}" in
		active|activating|reloading)
			systemctl start "$unit"
			CORE_CUTOVER_UNITS+=("$unit")
			;;
	esac
done
for unit in "${CORE_CUTOVER_UNITS[@]}"; do
	wait_install_unit_active "$unit" || exit 23
done

# Файрвол уже в строю; теперь сетевое обновление списков не оставляет хост голым.
/root/antizapret/doall.sh noclear

# Готовим серверные конфиги и пересоздаём клиентские профили.
/root/antizapret/client.sh 7
require_vpn_key_permissions /etc/openvpn/easyrsa3 /etc/wireguard

if [[ "$OPENVPN_PATCH" != '0' ]]; then
	ANTIZAPRET_SETUP_RUN=y /root/antizapret/patch-openvpn.sh "$OPENVPN_PATCH"
fi

if [[ "$OPENVPN_DCO" == 'y' ]]; then
	/root/antizapret/openvpn-dco.sh y
fi

# Новый runtime должен подняться до commit. Если любой unit падает, EXIT trap
# вернёт прежнюю конфигурацию и состояние служб.
CUTOVER_UNITS=("${CORE_CUTOVER_UNITS[@]}")
CUTOVER_VPN_UNITS=()
if [[ "$OPENVPN_UDP_ENABLE" == 'y' ]]; then
	CUTOVER_VPN_UNITS+=(openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service)
fi
if [[ "$OPENVPN_TCP_ENABLE" == 'y' ]]; then
	CUTOVER_VPN_UNITS+=(openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service)
fi
if [[ "$WIREGUARD_ENABLE" == 'y' ]]; then
	CUTOVER_VPN_UNITS+=(wg-quick@antizapret.service wg-quick@vpn.service)
fi
if (( ${#CUTOVER_VPN_UNITS[@]} > 0 )); then
	systemctl start "${CUTOVER_VPN_UNITS[@]}"
	for unit in "${CUTOVER_VPN_UNITS[@]}"; do
		wait_install_unit_active "$unit" || exit 23
	done
	CUTOVER_UNITS+=("${CUTOVER_VPN_UNITS[@]}")
fi

# custom-up штатно видит уже поднятые VPN-интерфейсы. State и lock
# не дают потерять парный custom-down при падении основного unit.
(
	# Пользовательский hook может оставить фоновый процесс. Он не должен
	# унаследовать setup lock и заблокировать следующую установку.
	exec {INSTALL_LOCK_FD}>&-
	/root/antizapret/up.sh --complete-cutover
)

if [[ "$BGP_ENABLE" == 'y' ]]; then
	systemctl start antizapret-bgp.service
	CUTOVER_UNITS+=(antizapret-bgp.service)
fi
systemctl start antizapret-update.timer logrotate.timer
CUTOVER_UNITS+=(antizapret-update.timer logrotate.timer)
for unit in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
	case "${INSTALL_TRANSACTION_ACTIVE[$unit]}" in
		active|activating|reloading)
			systemctl start "$unit"
			CUTOVER_UNITS+=("$unit")
			;;
	esac
done

for unit in "${CUTOVER_UNITS[@]}"; do
	wait_install_unit_active "$unit" || exit 23
done

for unit in \
	openvpn-server@antizapret-udp.service openvpn-server@vpn-udp.service \
	openvpn-server@antizapret-tcp.service openvpn-server@vpn-tcp.service \
	wg-quick@antizapret.service wg-quick@vpn.service
do
	case " ${CUTOVER_UNITS[*]} " in
		*" $unit "*) ;;
		*)
			if ! verify_install_unit_stopped "$unit"; then
				echo "Error: Disabled VPN unit $unit is unexpectedly active"
				exit 23
			fi
			;;
	esac
done

# Units are active; now verify addresses, listeners, firewall and local DNS.
# This is the last fatal gate before the transaction is committed.
validate_cutover_runtime

# A guard left by a failed rollback is cleared only after the replacement
# firewall and every requested tunnel passed the regular cutover checks.
if ! remove_install_rollback_vpn_guard; then
	echo 'Error: Cannot clear the installation rollback VPN guard'
	exit 26
fi

# Перезагружаем
echo
commit_install_transaction

# Необязательная уборка и swap не должны откатывать уже проверенный VPN.
if ! {
	journalctl --vacuum-size=1B -q
	find /var/log -name '*.gz' -delete
	find /var/log -name '*.1' -delete
	find /var/log -type f -exec truncate -s 0 {} +
	[[ ! -d /etc/openvpn/server/logs ]] || find /etc/openvpn/server/logs -type f -exec truncate -s 0 {} +
}; then
	echo 'Warning: Cannot finish optional log cleanup'
fi

# Создадим swap только если его нет. Чужой /swapfile не трогаем.
if [[ -z "$(swapon --show --noheadings)" ]]; then
	if [[ -e /swapfile || -L /swapfile ]] || grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
		echo 'Warning: inactive /swapfile configuration already exists; leaving it unchanged'
	else
		SWAP_TEMP=
		FSTAB_TEMP=
		if SWAP_TEMP="$(mktemp /swapfile.antizapret.XXXXXX)" &&
			FSTAB_TEMP="$(mktemp /etc/.fstab.antizapret.XXXXXX)" &&
			dd if=/dev/zero of="$SWAP_TEMP" bs=1M count=1024 status=none &&
			chmod 600 "$SWAP_TEMP" &&
			mkswap "$SWAP_TEMP" >/dev/null &&
			cp -a /etc/fstab "$FSTAB_TEMP" &&
			printf '/swapfile none swap sw 0 0\n' >> "$FSTAB_TEMP" &&
			mv -f -- "$SWAP_TEMP" /swapfile &&
			swapon /swapfile &&
			mv -f -- "$FSTAB_TEMP" /etc/fstab
		then
			:
		else
			swapoff /swapfile >/dev/null 2>&1 || true
			rm -f -- /swapfile ${SWAP_TEMP:+"$SWAP_TEMP"} ${FSTAB_TEMP:+"$FSTAB_TEMP"}
			echo 'Warning: Cannot create the optional swap file'
		fi
	fi
fi

if [[ -n "$BACKUP_ARCHIVE" ]] && ! rm -f -- "$BACKUP_ARCHIVE"; then
	echo "Warning: Installation succeeded, but backup archive was not removed: $BACKUP_ARCHIVE"
fi
echo -e '\e[1;32mAntiZapret VPN + full VPN installed successfully!\e[0m'
echo 'Rebooting...'

if ! reboot -f; then
	echo 'Warning: Automatic reboot failed; the verified VPN services remain active'
fi
