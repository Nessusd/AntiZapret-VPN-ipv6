#!/bin/bash
set -e

SECONDS=0
ROOT_DIR="${ANTIZAPRET_ROOT:-/root/antizapret}"
SYSTEMD_DIR="${ANTIZAPRET_SYSTEMD_DIR:-/etc/systemd/system}"
cd "$ROOT_DIR"
source setup
export DISABLE_IPV6 VPN_IPV6_PREFIX BGP_ENABLE

FIREWALL6_CHANGED=n
FIREWALL6_REPOSITORY=${FIREWALL6_REPOSITORY:-https://github.com/Nessusd/AntiZapret-VPN-ipv6.git}
FIREWALL6_RAW_BASE=${FIREWALL6_RAW_BASE:-https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6}
FIREWALL6_REVISION_API=${FIREWALL6_REVISION_API:-https://api.github.com/repos/Nessusd/AntiZapret-VPN-ipv6/commits/main}
FIREWALL6_PROXY='https://api.codetabs.com/v1/proxy?quest='
FIREWALL6_STAGING=
FIREWALL6_TEMPORARIES=()

cleanup_firewall6_staging() {
	local temporary failed=n
	for temporary in "${FIREWALL6_TEMPORARIES[@]}"; do
		if [[ -n "$temporary" ]] && ! rm -f -- "$temporary"; then
			failed=y
		fi
	done
	if [[ -n "$FIREWALL6_STAGING" && -d "$FIREWALL6_STAGING" ]]; then
		rm -rf -- "$FIREWALL6_STAGING" || failed=y
	fi
	[[ "$failed" == 'n' ]]
}
trap 'cleanup_firewall6_staging || true' EXIT

resolve_firewall6_revision() {
	local reference revision_file
	if [[ -n "${FIREWALL6_REVISION:-}" ]]; then
		[[ "$FIREWALL6_REVISION" =~ ^[0-9a-fA-F]{40}$ ]]
		return
	fi
	if reference="$(timeout 30 git ls-remote "$FIREWALL6_REPOSITORY" refs/heads/main)"; then
		FIREWALL6_REVISION="${reference%%[[:space:]]*}"
		if [[ "$FIREWALL6_REVISION" =~ ^[0-9a-fA-F]{40}$ ]]; then
			return 0
		fi
	fi

	if ! revision_file="$(mktemp /tmp/antizapret-firewall6-revision.XXXXXX)"; then
		return 1
	fi
	FIREWALL6_TEMPORARIES+=("$revision_file")
	if ! curl -fL --connect-timeout 30 "$FIREWALL6_REVISION_API" -o "$revision_file" &&
		! curl -fL --connect-timeout 30 "$FIREWALL6_PROXY$FIREWALL6_REVISION_API" -o "$revision_file"; then
		return 1
	fi
	if ! FIREWALL6_REVISION="$(python3 - "$revision_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        value = json.load(source).get("sha", "")
except (OSError, AttributeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, str):
    raise SystemExit(1)
print(value)
PY
)"; then
		return 1
	fi
	[[ "$FIREWALL6_REVISION" =~ ^[0-9a-fA-F]{40}$ ]]
}

download_firewall6_file() {
	local relative=$1 destination=$2
	local link="$FIREWALL6_RAW_BASE/$FIREWALL6_REVISION/$relative"
	if curl -fL --connect-timeout 30 "$link" -o "$destination"; then
		return 0
	fi
	if curl -fL --connect-timeout 30 "$FIREWALL6_PROXY$link" -o "$destination"; then
		return 0
	fi
	rm -f "$destination"
	return 1
}

validate_firewall6_file() {
	local relative=$1 staged=$2
	[[ -s "$staged" ]] || return 1
	case "$relative" in
		*.sh) bash -n "$staged" ;;
		*.py) python3 -m py_compile "$staged" ;;
		*/antizapret.service.d/ipv6-firewall.conf)
			grep -Fxq '[Service]' "$staged" &&
			grep -Eq '^ExecStartPre=.*/firewall6\.sh up$' "$staged" &&
			grep -Eq '^ExecStopPost=.*/firewall6\.sh down$' "$staged"
			;;
		*/antizapret-bgp.service)
			grep -Fxq '[Unit]' "$staged" &&
			grep -Fxq '[Service]' "$staged" &&
			grep -Eq '^ExecStartPre=.*bgp-update\.py --prepare-only$' "$staged" &&
			grep -Eq '^ExecStartPre=.*bgp-firewall\.sh up$' "$staged" &&
			grep -Eq '^ExecStart=' "$staged" &&
			grep -Eq '^ExecStopPost=.*bgp-firewall\.sh down$' "$staged"
			;;
		*) return 0 ;;
	esac
}

keep_installed_firewall6_snapshot() {
	local message=$1 index
	for index in "${!destinations[@]}"; do
		if [[ ! -f "${destinations[$index]}" ]]; then
			echo "Error: the IPv6/BGP snapshot is incomplete: ${destinations[$index]} is missing" >&2
			return 1
		fi
		if ! chmod "${modes[$index]}" "${destinations[$index]}"; then
			return 1
		fi
	done
	echo "$message"
	if ! cleanup_firewall6_staging; then
		return 1
	fi
	FIREWALL6_STAGING=
	FIREWALL6_TEMPORARIES=()
	return 0
}

rollback_firewall6_publication() {
	local position index destination restore failed=n
	for ((position=${#published[@]} - 1; position >= 0; position--)); do
		index=${published[$position]}
		destination=${destinations[$index]}
		if [[ "${old_exists[$index]}" == 'y' ]]; then
			restore="${destination}.rollback.$$"
			FIREWALL6_TEMPORARIES+=("$restore")
			if ! cp -a -- "$FIREWALL6_STAGING/backup-$index" "$restore" || ! mv -f -- "$restore" "$destination"; then
				echo "Error: failed to restore $destination" >&2
				failed=y
			fi
		else
			if ! rm -f -- "$destination"; then
				echo "Error: failed to remove newly published $destination" >&2
				failed=y
			fi
		fi
	done
	[[ "$failed" == 'n' ]]
}

sync_firewall6_locked() {
	local index staged destination temporary current_mode
	local -a relatives=(
		setup/root/antizapret/firewall6.sh
		setup/root/antizapret/firewall6-protection.sh
		setup/root/antizapret/firewall6-apply.sh
		setup/root/antizapret/firewall6-lists.py
		setup/etc/systemd/system/antizapret.service.d/ipv6-firewall.conf
	)
	local -a destinations=(
		firewall6.sh
		firewall6-protection.sh
		firewall6-apply.sh
		firewall6-lists.py
		"$SYSTEMD_DIR/antizapret.service.d/ipv6-firewall.conf"
	)
	local -a modes=(755 755 755 755 644)
	local -a changed=()
	local -a old_exists=()
	local -a published=()
	if [[ "${BGP_ENABLE:-n}" == 'y' ]]; then
		relatives+=(
			setup/root/antizapret/bgp-update.py
			setup/root/antizapret/bgp-firewall.sh
			setup/etc/systemd/system/antizapret-bgp.service
		)
		destinations+=(
			bgp-update.py
			bgp-firewall.sh
			"$SYSTEMD_DIR/antizapret-bgp.service"
		)
		modes+=(755 755 644)
	fi

	if ! resolve_firewall6_revision; then
		keep_installed_firewall6_snapshot \
			'Warning: failed to resolve the update revision; keeping the installed IPv6/BGP snapshot'
		return
	fi

	if ! FIREWALL6_STAGING="$(mktemp -d /tmp/antizapret-firewall6.XXXXXX)"; then
		return 1
	fi
	for index in "${!relatives[@]}"; do
		staged="$FIREWALL6_STAGING/$index"
		if ! download_firewall6_file "${relatives[$index]}" "$staged"; then
			keep_installed_firewall6_snapshot \
				'Warning: failed to download the complete IPv6/BGP snapshot; keeping the installed version'
			return
		fi
		if ! validate_firewall6_file "${relatives[$index]}" "$staged"; then
			keep_installed_firewall6_snapshot \
				'Warning: the downloaded IPv6/BGP snapshot failed validation; keeping the installed version'
			return
		fi
	done

	# Подготавливаем файлы в каталогах назначения. Сетевые запросы к этому
	# моменту уже завершены, поэтому их сбой не может смешать две версии.
	for index in "${!destinations[@]}"; do
		destination="${destinations[$index]}"
		temporary="${destination}.sync.$$"
		FIREWALL6_TEMPORARIES+=("$temporary")
		if ! mkdir -p "$(dirname "$destination")" || \
			! install -m "${modes[$index]}" "$FIREWALL6_STAGING/$index" "$temporary"; then
			echo "Error: failed to prepare $destination" >&2
			return 1
		fi
	done

	for index in "${!destinations[@]}"; do
		destination="${destinations[$index]}"
		temporary="${destination}.sync.$$"
		current_mode=
		if [[ -f "$destination" ]]; then
			current_mode="$(stat -c '%a' "$destination")" || return 1
		fi
		if [[ -f "$destination" ]] && cmp -s "$temporary" "$destination" && \
			[[ "$current_mode" == "${modes[$index]}" ]]; then
			rm -f "$temporary"
		else
			changed+=("$index")
		fi
	done

	# Резервные копии создаются до первой замены, чтобы любую ошибку публикации
	# можно было откатить к полностью установленному предыдущему набору.
	for index in "${changed[@]}"; do
		destination="${destinations[$index]}"
		if [[ -e "$destination" || -L "$destination" ]]; then
			if ! cp -a -- "$destination" "$FIREWALL6_STAGING/backup-$index"; then
				echo "Error: failed to back up $destination" >&2
				return 1
			fi
			old_exists[$index]=y
		else
			old_exists[$index]=n
		fi
	done

	for index in "${changed[@]}"; do
		destination="${destinations[$index]}"
		temporary="${destination}.sync.$$"
		if ! mv -f -- "$temporary" "$destination"; then
			echo "Error: failed to publish $destination; restoring the previous snapshot" >&2
			rollback_firewall6_publication || true
			return 1
		fi
		published+=("$index")
	done

	if (( ${#changed[@]} > 0 )); then
		if ! systemctl daemon-reload; then
			echo 'Error: systemd rejected the new IPv6/BGP snapshot; restoring the previous snapshot' >&2
			rollback_firewall6_publication || true
			systemctl daemon-reload || true
			return 1
		fi
		FIREWALL6_CHANGED=y
	fi

	if ! cleanup_firewall6_staging; then
		return 1
	fi
	FIREWALL6_STAGING=
	FIREWALL6_TEMPORARIES=()
	return 0
}

sync_firewall6() {
	local status=0
	if ! mkdir -p "$ROOT_DIR/state" || \
		! exec {FIREWALL6_LOCK_FD}> "$ROOT_DIR/state/firewall6-sync.lock"; then
		return 1
	fi
	if ! flock -x "$FIREWALL6_LOCK_FD"; then
		exec {FIREWALL6_LOCK_FD}>&-
		return 1
	fi
	sync_firewall6_locked || status=$?
	flock -u "$FIREWALL6_LOCK_FD" || status=1
	exec {FIREWALL6_LOCK_FD}>&-
	return "$status"
}

[[ -d /etc/openvpn/server/logs ]] && find /etc/openvpn/server/logs -type f -size +100M -exec truncate -s 0 {} +
SUM1="$(sha256sum update.sh)"
DOALL_SUM1="$(sha256sum doall.sh)"
cat update.sh | bash -s "$1"
SUM2="$(sha256sum update.sh)"
if [[ "$SUM1" != "$SUM2" ]]; then
	echo 'Restarting update.sh'
	cat update.sh | bash -s "$1"
fi
DOALL_SUM2="$(sha256sum doall.sh)"
if [[ "$DOALL_SUM1" != "$DOALL_SUM2" ]]; then
	if [[ "${ANTIZAPRET_DOALL_REEXECUTED:-n}" == 'y' ]]; then
		echo 'Error: doall.sh changed again after it was restarted' >&2
		exit 1
	fi
	echo 'Restarting doall.sh'
	export ANTIZAPRET_DOALL_REEXECUTED=y
	exec ./doall.sh "$1"
fi

# Синхронизация выполняется после самообновления и возможного re-exec, чтобы
# набором файлов управляла уже загруженная версия doall.sh.
sync_firewall6

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
