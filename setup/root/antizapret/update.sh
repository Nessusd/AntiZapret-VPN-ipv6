#!/bin/bash
set -e
export LC_ALL=C

# Обработка ошибок
handle_error() {
	echo "$(lsb_release -ds) $(uname -r) $(date --iso-8601=seconds)"
	echo -e "\e[1;31mError at line $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

if [[ -n "$1" && "$1" != 'ip' && "$1" != 'ips' && "$1" != 'host' && "$1" != 'hosts' && "$1" != 'noclear' && "$1" != 'noclean' ]]; then
	echo "Ignored invalid parameter: $1"
	set --
fi

echo 'Update AntiZapret VPN files:'

ROOT_DIR="${ANTIZAPRET_ROOT:-/root/antizapret}"
cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/state"
UPDATE_LOCK_PATH="$ROOT_DIR/state/update.lock"
if [[ ! "${ANTIZAPRET_UPDATE_LOCK_FD:-}" =~ ^[0-9]+$ ]] || \
	[[ ! "$UPDATE_LOCK_PATH" -ef "/proc/$$/fd/${ANTIZAPRET_UPDATE_LOCK_FD:-}" ]] || \
	! flock -n "$ANTIZAPRET_UPDATE_LOCK_FD"; then
	exec {ANTIZAPRET_UPDATE_LOCK_FD}> "$UPDATE_LOCK_PATH"
	flock -x "$ANTIZAPRET_UPDATE_LOCK_FD"
fi
export ANTIZAPRET_UPDATE_LOCK_FD
source setup

# Старый набор источников остаётся доступным до успешного завершения загрузок.
DOWNLOAD_STAGING="$(mktemp -d "$ROOT_DIR/state/download-update.XXXXXX")"
DOWNLOAD_BACKUP=
cleanup_download_staging() {
	[[ -z "$DOWNLOAD_STAGING" ]] || rm -rf -- "$DOWNLOAD_STAGING"
	if [[ -n "$DOWNLOAD_BACKUP" && ! -e "$DOWNLOAD_BACKUP/download" ]]; then
		rmdir -- "$DOWNLOAD_BACKUP" || true
	fi
}
trap cleanup_download_staging EXIT

UPDATE_LINK=https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup/root/antizapret/update.sh
UPDATE_PATH=update.sh

PARSE_LINK=https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup/root/antizapret/parse.sh
PARSE_PATH=parse.sh

DOALL_LINK=https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup/root/antizapret/doall.sh
DOALL_PATH=doall.sh

DOMAIN_LINK=https://raw.githubusercontent.com/bol-van/rulist/refs/heads/main/reestr_hostname.txt
DOMAIN_PATH=download/bol-van-domain.txt

DOMAIN2_LINK=https://antifilter.download/list/domains.lst
DOMAIN2_PATH=download/antifilter-download-domain.txt

RPZ_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/deny-rpz.txt
RPZ_PATH=download/rpz.txt

RPZ2_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/deny2-rpz.txt
RPZ2_PATH=download/rpz2.txt

INCLUDE_HOSTS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/include-hosts.txt
INCLUDE_HOSTS_PATH=download/include-hosts.txt

EXCLUDE_HOSTS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/exclude-ru-hosts.txt
EXCLUDE_HOSTS_PATH=download/exclude-hosts.txt

REMOVE_HOSTS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/remove-hosts.txt.gz
REMOVE_HOSTS_PATH=download/remove-hosts.txt.gz

INCLUDE_ADBLOCK_HOSTS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/include-adblock-hosts.txt
INCLUDE_ADBLOCK_HOSTS_PATH=download/include-adblock-hosts.txt

EXCLUDE_ADBLOCK_HOSTS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/exclude-adblock-hosts.txt
EXCLUDE_ADBLOCK_HOSTS_PATH=download/exclude-adblock-hosts.txt

ADGUARD_LINK=https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
ADGUARD_PATH=download/adguard.txt

OISD_LINK=https://raw.githubusercontent.com/sjhgvr/oisd/refs/heads/main/domainswild2_small.txt
OISD_PATH=download/oisd-include-adblock-hosts.txt

CLOUDFLARE_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/cloudflare-ips.txt
CLOUDFLARE_IPS_PATH=download/cloudflare-ips.txt

AMAZON_JSON_LINK=https://ip-ranges.amazonaws.com/ip-ranges.json
AMAZON_JSON_PATH=download/amazon-ip-ranges.json
AMAZON_SCRIPT_LINK=https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup/root/antizapret/amazon-ips.py

HETZNER_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/hetzner-ips.txt
HETZNER_IPS_PATH=download/hetzner-ips.txt

DIGITALOCEAN_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/digitalocean-ips.txt
DIGITALOCEAN_IPS_PATH=download/digitalocean-ips.txt

OVH_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/ovh-ips.txt
OVH_IPS_PATH=download/ovh-ips.txt

TELEGRAM_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/telegram-ips.txt
TELEGRAM_IPS_PATH=download/telegram-ips.txt

GOOGLE_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/google-ips.txt
GOOGLE_IPS_PATH=download/google-ips.txt

AKAMAI_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/akamai-ips.txt
AKAMAI_IPS_PATH=download/akamai-ips.txt

WHATSAPP_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/whatsapp-ips.txt
WHATSAPP_IPS_PATH=download/whatsapp-ips.txt

ROBLOX_IPS_LINK=https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup/root/antizapret/download/roblox-ips.txt
ROBLOX_IPS_PATH=download/roblox-ips.txt

IPV6_LISTS_LINK=https://raw.githubusercontent.com/Nessusd/AntiZapret-VPN-ipv6/main/setup/root/antizapret/download

PROXY=https://api.codetabs.com/v1/proxy?quest=

# Загрузка всегда идёт во временный файл. Основной путь заменяется только после
# успешного ответа и, когда доступно, проверки Content-Length.
function download {
	local path="${1}"
	local link="$2"
	local tmp_path header_path decoded_path='' local_size remote_size
	echo "$path"
	if [[ "$path" == download/* && -n "${DOWNLOAD_STAGING:-}" ]]; then
		path="$DOWNLOAD_STAGING/${path#download/}"
	fi
	tmp_path="$(mktemp "${path}.download.XXXXXX")" || return 1
	header_path="$(mktemp "${path}.headers.XXXXXX")" || {
		rm -f -- "$tmp_path"
		return 1
	}
	if ! curl -fL --connect-timeout 30 --max-time "${ANTIZAPRET_DOWNLOAD_TIMEOUT:-300}" \
		-D "$header_path" "$link" -o "$tmp_path"; then
		echo 'Trying connect via proxy...'
		if ! curl -fL --connect-timeout 30 --max-time "${ANTIZAPRET_DOWNLOAD_TIMEOUT:-300}" \
			-D "$header_path" "$PROXY$link" -o "$tmp_path"; then
			rm -f -- "$tmp_path" "$header_path"
			return 2
		fi
	fi
	local_size="$(stat -c '%s' "$tmp_path")" || {
		rm -f -- "$tmp_path" "$header_path"
		return 3
	}
	# Заголовки принадлежат тому же GET; каждый redirect начинает новый ответ.
	remote_size="$(awk '
		/^HTTP\// { size = "" }
		tolower($0) ~ /^content-length:/ {
			size = $0
			sub(/^[^:]*:[[:space:]]*/, "", size)
			gsub(/[[:space:]]/, "", size)
		}
		END { if (size ~ /^[0-9]+$/) print size }
	' "$header_path")"
	if [[ -n "$remote_size" && "$local_size" != "$remote_size" ]]; then
		echo "Failed to download $path! Size on server is different" >&2
		rm -f -- "$tmp_path" "$header_path"
		return 4
	fi
	if [[ "$path" == *.gz ]]; then
		decoded_path="$(mktemp "${path%.gz}.decoded.XXXXXX")" || {
			rm -f -- "$tmp_path" "$header_path"
			return 1
		}
		if ! gzip -dc -- "$tmp_path" > "$decoded_path"; then
			rm -f -- "$tmp_path" "$header_path" "$decoded_path"
			return 5
		fi
		if ! chmod 644 "$decoded_path" || ! mv -f -- "$decoded_path" "${path%.gz}"; then
			rm -f -- "$tmp_path" "$header_path" "$decoded_path"
			return 1
		fi
	else
		if [[ "$path" == *.sh ]] && ! bash -n "$tmp_path"; then
			rm -f -- "$tmp_path" "$header_path"
			return 6
		fi
		if [[ "$path" == *.sh ]]; then
			chmod 755 "$tmp_path" || {
				rm -f -- "$tmp_path" "$header_path"
				return 1
			}
		else
			chmod 644 "$tmp_path" || {
				rm -f -- "$tmp_path" "$header_path"
				return 1
			}
		fi
		if ! mv -f -- "$tmp_path" "$path"; then
			rm -f -- "$tmp_path" "$header_path"
			return 1
		fi
	fi
	rm -f -- "$tmp_path" "$header_path"
}

function download_ipv6_list {
	[[ "${DISABLE_IPV6:-n}" == 'y' ]] && return 0
	local name="$1"
	download "download/${name}-ips6.txt" "$IPV6_LISTS_LINK/${name}-ips6.txt"
}

if [[ "${ANTIZAPRET_SKIP_SCRIPT_UPDATE:-n}" != 'y' ]]; then
	download $UPDATE_PATH $UPDATE_LINK
	download $PARSE_PATH $PARSE_LINK
	download $DOALL_PATH $DOALL_LINK
else
	# Локальная публикация может ещё отсутствовать в main. Данные обновляются
	# штатно, а установленный проверенный код не заменяется старой версией.
	for script in "$UPDATE_PATH" "$PARSE_PATH" "$DOALL_PATH"; do
		if [[ ! -s "$script" ]] || ! bash -n "$script"; then
			echo "Pinned update requires a valid local script: $script" >&2
			exit 1
		fi
		chmod 755 "$script"
	done
fi

# Доменные источники обновляются отдельно от IP-источников, чтобы параметры
# ip/host могли сократить работу ручного или автоматического запуска.
if [[ -z "$1" || "$1" == 'host' || "$1" == 'hosts' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	download $DOMAIN_PATH $DOMAIN_LINK
	( download $DOMAIN2_PATH $DOMAIN2_LINK ) || true
	download $RPZ_PATH $RPZ_LINK
	download $RPZ2_PATH $RPZ2_LINK
	download $INCLUDE_HOSTS_PATH $INCLUDE_HOSTS_LINK
	download $REMOVE_HOSTS_PATH $REMOVE_HOSTS_LINK

	if [[ "$ROUTE_ALL" == 'y' ]]; then
		download $EXCLUDE_HOSTS_PATH $EXCLUDE_HOSTS_LINK
	else
		printf '# НЕ РЕДАКТИРУЙТЕ ЭТОТ ФАЙЛ!' > "$DOWNLOAD_STAGING/${EXCLUDE_HOSTS_PATH#download/}"
	fi

	if [[ "$BLOCK_ADS" == 'y' ]]; then
		download $INCLUDE_ADBLOCK_HOSTS_PATH $INCLUDE_ADBLOCK_HOSTS_LINK
		download $EXCLUDE_ADBLOCK_HOSTS_PATH $EXCLUDE_ADBLOCK_HOSTS_LINK
		download $ADGUARD_PATH $ADGUARD_LINK
		download $OISD_PATH $OISD_LINK
	else
		: > "$DOWNLOAD_STAGING/${INCLUDE_ADBLOCK_HOSTS_PATH#download/}"
		: > "$DOWNLOAD_STAGING/${EXCLUDE_ADBLOCK_HOSTS_PATH#download/}"
		: > "$DOWNLOAD_STAGING/${ADGUARD_PATH#download/}"
		: > "$DOWNLOAD_STAGING/${OISD_PATH#download/}"
	fi
fi

# Дополнительные сети скачиваются только для включённых провайдеров; IPv6-файл
# запрашивается вместе с соответствующим IPv4-источником.
if [[ -z "$1" || "$1" == 'ip' || "$1" == 'ips' || "$1" == 'noclear' || "$1" == 'noclean' ]]; then
	if [[ "$CLOUDFLARE_INCLUDE" == 'y' ]]; then
		download $CLOUDFLARE_IPS_PATH $CLOUDFLARE_IPS_LINK
		download_ipv6_list cloudflare
	fi

	if [[ "$AMAZON_INCLUDE" == 'y' ]]; then
		# Оба стека собираются из одной публикации AWS, а не из старого IPv4-снимка.
		if [[ "${ANTIZAPRET_SKIP_SCRIPT_UPDATE:-n}" != 'y' ]]; then
			download amazon-ips.py "$AMAZON_SCRIPT_LINK"
		elif [[ ! -s amazon-ips.py ]]; then
			echo 'Pinned update requires the local amazon-ips.py generator' >&2
			exit 1
		fi
		download "$AMAZON_JSON_PATH" "$AMAZON_JSON_LINK"
		amazon_args=()
		[[ "${DISABLE_IPV6:-n}" == 'y' ]] && amazon_args+=(--disable-ipv6)
		python3 amazon-ips.py "$DOWNLOAD_STAGING/${AMAZON_JSON_PATH#download/}" "$DOWNLOAD_STAGING" "${amazon_args[@]}"
	fi

	if [[ "$HETZNER_INCLUDE" == 'y' ]]; then
		download $HETZNER_IPS_PATH $HETZNER_IPS_LINK
		download_ipv6_list hetzner
	fi

	if [[ "$DIGITALOCEAN_INCLUDE" == 'y' ]]; then
		download $DIGITALOCEAN_IPS_PATH $DIGITALOCEAN_IPS_LINK
		download_ipv6_list digitalocean
	fi

	if [[ "$OVH_INCLUDE" == 'y' ]]; then
		download $OVH_IPS_PATH $OVH_IPS_LINK
		download_ipv6_list ovh
	fi

	if [[ "$TELEGRAM_INCLUDE" == 'y' ]]; then
		download $TELEGRAM_IPS_PATH $TELEGRAM_IPS_LINK
		download_ipv6_list telegram
	fi

	if [[ "$GOOGLE_INCLUDE" == 'y' ]]; then
		download $GOOGLE_IPS_PATH $GOOGLE_IPS_LINK
		download_ipv6_list google
	fi

	if [[ "$AKAMAI_INCLUDE" == 'y' ]]; then
		download $AKAMAI_IPS_PATH $AKAMAI_IPS_LINK
		download_ipv6_list akamai
	fi

	if [[ "$WHATSAPP_INCLUDE" == 'y' ]]; then
		download $WHATSAPP_IPS_PATH $WHATSAPP_IPS_LINK
		download_ipv6_list whatsapp
	fi

	if [[ "$ROBLOX_INCLUDE" == 'y' ]]; then
		download $ROBLOX_IPS_PATH $ROBLOX_IPS_LINK
		download_ipv6_list roblox
	fi
fi

# Публикуем только полный набор. Ошибка rename возвращает прежний каталог.
DOWNLOAD_BACKUP="$(mktemp -d "$ROOT_DIR/state/download-previous.XXXXXX")"
if [[ -e download || -L download ]]; then
	mv -- download "$DOWNLOAD_BACKUP/download"
fi
if ! mv -- "$DOWNLOAD_STAGING" download; then
	if [[ -e "$DOWNLOAD_BACKUP/download" || -L "$DOWNLOAD_BACKUP/download" ]]; then
		if ! mv -- "$DOWNLOAD_BACKUP/download" download; then
			echo "Failed to restore download sources; recovery copy: $DOWNLOAD_BACKUP/download" >&2
		fi
	fi
	exit 1
fi
DOWNLOAD_STAGING=
rm -rf -- "$DOWNLOAD_BACKUP"
DOWNLOAD_BACKUP=

# Локальный hook выполняется последним и может дополнить уже загруженный набор.
./custom-update.sh "$1" || true

exit 0
