#!/bin/bash

# Полный менеджер AdminAntizapret
export LC_ALL="C.UTF-8"
export LANG="C.UTF-8"
export DEBIAN_FRONTEND=noninteractive

# ─── Цвета ────────────────────────────────────────
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

# ─── Основные параметры ───────────────────────────
export INSTALL_DIR="/opt/AdminAntizapret"
export VENV_PATH="$INSTALL_DIR/venv"
export SERVICE_NAME="admin-antizapret"
export DEFAULT_PORT="5050"
export APP_PORT="$DEFAULT_PORT"
export DB_FILE="$INSTALL_DIR/instance/users.db"
export ANTIZAPRET_INSTALL_DIR="/root/antizapret"
export LOG_FILE="/var/log/adminpanel.log"
export MAX_MAIN_LOG_SIZE_MB=20
export MAX_MAIN_LOG_BACKUPS=5
export INCLUDE_DIR="$INSTALL_DIR/script_sh"
export ADMIN_PANEL_DIR="/root/AdminPanel"

# utils — первым, чтобы UI-функции были доступны всем модулям
modules=(
    "utils"
    "ssl_setup"
    "backup_functions"
    "monitoring"
    "service_functions"
    "uninstall"
    "user_management"
    "site_diagnostics"
    "panel_menus"
    "ip_whitelist"
)

for module in "${modules[@]}"; do
    if [ -f "$INCLUDE_DIR/${module}.sh" ]; then
        # shellcheck disable=SC1090
        . "$INCLUDE_DIR/${module}.sh"
    else
        printf "  ${RED}✗${NC}  Не найден модуль: ${module}.sh\n" >&2
        exit 1
    fi
done

# Значения по умолчанию для .env (общий модуль с единым setup.sh)
if [ -f "$INCLUDE_DIR/env_defaults.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$INCLUDE_DIR/env_defaults.sh"
else
    printf "  ${RED}✗${NC}  Не найден модуль: env_defaults.sh\n" >&2
    exit 1
fi

# ─── Генерация секретного ключа ───────────────────
generate_secret_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
        return $?
    fi
    if [ -r /dev/urandom ]; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
        return $?
    fi
    return 1
}

# SECRET_KEY задаётся в .env только при первой настройке (ssl_setup.sh)
# shellcheck disable=SC2034
SECRET_KEY=""

# ─── Проверка занятости порта ─────────────────────
check_port() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -q ":$port " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -q ":$port " && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null && return 0
    elif grep -q ":$port " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
        return 0
    else
        ui_warn "Не удалось проверить порт (нужен ss, netstat или lsof)"
        return 1
    fi
    return 1
}

# Debian ≥13: пакет dnsutils заменён на bind9-dnsutils (dig/host/nslookup)
_is_dnsutils_pkg_installed() {
    dpkg -s dnsutils >/dev/null 2>&1 || dpkg -s bind9-dnsutils >/dev/null 2>&1
}

_dnsutils_apt_pkg_name() {
    if apt-cache show dnsutils >/dev/null 2>&1; then
        printf '%s\n' dnsutils
    else
        printf '%s\n' bind9-dnsutils
    fi
}

# ─── Проверка окружения ───────────────────────────
verify_project_environment() {
    local failed=0 warned=0 passed=0
    local req_file="$INSTALL_DIR/requirements.txt"
    local missing_system_packages=()
    local required_system_packages=(python3 python3-pip python3-venv python3-dev git wget openssl cron vnstat dnsutils libjpeg-dev zlib1g-dev iptables ipset)

    _vpe_ok()   { ui_ok "$1";   passed=$((passed + 1)); }
    _vpe_warn() { ui_warn "$1"; warned=$((warned + 1)); }
    _vpe_fail() { ui_fail "$1"; failed=$((failed + 1)); }

    normalize_pkg_name() {
        printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
    }

    ui_section "1) Системные команды"
    local required_commands=(python3 pip3 git wget openssl systemctl awk sed grep ss dig iptables ipset)
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            _vpe_ok "$cmd"
        else
            _vpe_fail "$cmd — не найден"
        fi
    done

    ui_section "2) Системные пакеты"
    for pkg in "${required_system_packages[@]}"; do
        if [ "$pkg" = "dnsutils" ]; then
            if _is_dnsutils_pkg_installed; then
                if dpkg -s dnsutils >/dev/null 2>&1; then
                    _vpe_ok "dnsutils"
                else
                    _vpe_ok "dnsutils (bind9-dnsutils)"
                fi
            else
                _vpe_fail "dnsutils — не установлен"
                missing_system_packages+=("dnsutils")
            fi
        elif dpkg -s "$pkg" >/dev/null 2>&1; then
            _vpe_ok "$pkg"
        else
            _vpe_fail "$pkg — не установлен"
            missing_system_packages+=("$pkg")
        fi
    done

    if [ "${#missing_system_packages[@]}" -gt 0 ]; then
        ui_warn "Отсутствуют пакеты: ${missing_system_packages[*]}"
        if ui_confirm "Установить недостающие пакеты?"; then
            ui_info "Устанавливаем недостающие пакеты..."
            local apt_install_packages=()
            local mpkg resolved_dns
            for mpkg in "${missing_system_packages[@]}"; do
                if [ "$mpkg" = "dnsutils" ]; then
                    resolved_dns=$(_dnsutils_apt_pkg_name)
                    apt_install_packages+=("$resolved_dns")
                else
                    apt_install_packages+=("$mpkg")
                fi
            done
            if apt-get update --quiet --quiet >/dev/null && \
               apt-get install -y --quiet --quiet "${apt_install_packages[@]}" >/dev/null; then
                _vpe_ok "Пакеты установлены"
            else
                _vpe_fail "Не удалось установить часть пакетов"
            fi
        else
            _vpe_warn "Установка пакетов пропущена"
        fi
    fi

    ui_section "3) Виртуальное окружение"
    if [ -x "$VENV_PATH/bin/python3" ] && [ -x "$VENV_PATH/bin/pip" ]; then
        _vpe_ok "Окружение: $VENV_PATH"
    else
        _vpe_fail "Не найдено или повреждено: $VENV_PATH"
    fi

    ui_section "4) Python-зависимости"
    if [ ! -f "$req_file" ]; then
        _vpe_fail "requirements.txt не найден"
    else
        _vpe_ok "requirements.txt найден"

        if [ -x "$VENV_PATH/bin/pip" ]; then
            local installed_pkgs
            installed_pkgs=$(
                "$VENV_PATH/bin/pip" list --format=freeze 2>/dev/null |
                    cut -d'=' -f1 | sed '/^$/d' |
                    while IFS= read -r p; do normalize_pkg_name "$p"; done
            )
            local missing_python_packages=()
            while IFS= read -r line; do
                line=$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//' | tr -d '[:space:]')
                [ -z "$line" ] && continue
                local req_name
                req_name=$(printf '%s' "$line" | sed -E 's/[<>=!~].*$//; s/\[.*\]$//')
                req_name=$(normalize_pkg_name "$req_name")
                printf '%s\n' "$installed_pkgs" | grep -qx "$req_name" || missing_python_packages+=("$line")
            done < "$req_file"

            if [ "${#missing_python_packages[@]}" -eq 0 ]; then
                _vpe_ok "Все зависимости из requirements.txt установлены"
            else
                _vpe_fail "Не установлены (${#missing_python_packages[@]} шт.):"
                printf '%s\n' "${missing_python_packages[@]}" | sed 's/^/      - /'
                if ui_confirm "Установить Python-зависимости?"; then
                    ui_info "Устанавливаем..."
                    if "$VENV_PATH/bin/pip" install -q -r "$req_file"; then
                        _vpe_ok "Python-зависимости установлены"
                    else
                        _vpe_fail "Не удалось установить Python-зависимости"
                    fi
                else
                    _vpe_warn "Установка Python-зависимостей пропущена"
                fi
            fi

            if "$VENV_PATH/bin/pip" check >/dev/null 2>&1; then
                _vpe_ok "Зависимости согласованы (pip check)"
            else
                _vpe_warn "Конфликты зависимостей (pip check). Проверьте вручную."
            fi
        else
            _vpe_fail "pip в venv не найден"
        fi
    fi

    ui_section "5) Файлы и сервисы"
    if [ -f "$INSTALL_DIR/.env" ]; then
        _vpe_ok ".env присутствует"
    else
        _vpe_fail ".env отсутствует"
    fi
    if [ -f "$DB_FILE" ]; then
        _vpe_ok "База данных: $DB_FILE"
    else
        _vpe_fail "База данных не найдена: $DB_FILE"
    fi
    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        _vpe_ok "Systemd unit: $SERVICE_NAME.service"
    else
        _vpe_fail "Systemd unit не найден"
    fi
    if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        _vpe_ok "Сервис включён в автозапуск"
    else
        _vpe_warn "Сервис не включён в автозапуск"
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        _vpe_ok "Сервис запущен"
    else
        _vpe_warn "Сервис не запущен"
    fi

    ui_section "6) AntiZapret-VPN"
    if [ -d "$ANTIZAPRET_INSTALL_DIR" ]; then
        _vpe_ok "Каталог $ANTIZAPRET_INSTALL_DIR"
    else
        _vpe_fail "Каталог $ANTIZAPRET_INSTALL_DIR не найден"
    fi
    if [ -x "$ANTIZAPRET_INSTALL_DIR/doall.sh" ]; then
        _vpe_ok "doall.sh доступен"
    else
        _vpe_fail "doall.sh не найден или не исполняемый"
    fi
    if systemctl is-active --quiet antizapret.service 2>/dev/null; then
        _vpe_ok "antizapret.service активен"
    else
        _vpe_warn "antizapret.service не активен (панель частично ограничена)"
    fi

    printf "\n"
    _m_top
    _m_item "$(printf "${GREEN}Успешно:${NC}       %d" "$passed")"
    _m_item "$(printf "${RED}Ошибок:${NC}        %d" "$failed")"
    _m_item "$(printf "${YELLOW}Предупреждений:${NC} %d" "$warned")"
    _m_bot
    printf "\n"

    if [ "$failed" -eq 0 ]; then
        ui_ok "Окружение готово."
    else
        ui_fail "Обнаружены ошибки. Устраните их перед работой."
    fi
}

# ─── Проверка root ────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "Попытка запуска без прав root"
        ui_fail "Запустите скрипт с правами root." >&2
        exit 1
    fi
}

# ─── Главное меню ─────────────────────────────────
main_menu() {
    while true; do
        clear
        _m_top
        _m_title "AdminAntizapret — Управление"
        _m_sep
        _m_item "1. Сервис панели"
        _m_item "2. Администраторы"
        _m_item "3. Сеть и HTTPS"
        _m_item "4. Резервные копии"
        _m_item "5. Диагностика"
        _m_item "6. Удалить AdminAntizapret"
        _m_sep
        _m_item "7. Диагностика запуска сайта"
        _m_item "8. Проверка окружения"
        _m_item "9. Белый список IP"
        _m_sep
        _m_item "0. Выход"
        _m_bot
        printf "\n"

        read -r -p "  Выберите действие [0-9]: " choice
        case $choice in
        1) menu_service_panel ;;
        2) menu_administrators ;;
        3) menu_network_https ;;
        4) menu_backups ;;
        5) menu_diagnostics ;;
        6) uninstall ;;
        7)
            diagnose_site_startup
            press_any_key
            ;;
        8)
            verify_project_environment
            press_any_key
            ;;
        9) menu_ip_whitelist ;;
        0) exit 0 ;;
        *)
            ui_warn "Неверный выбор"
            sleep 1
            ;;
        esac
    done
}

# ─── Точка входа ──────────────────────────────────
main() {
    check_root
    init_logging

    case "${1:-}" in
    "--install")
        ui_fail "Отдельная установка панели отключена. Используйте setup.sh AntiZapret-VPN-ipv6."
        exit 2
        ;;
    "--restart")
        restart_service
        ;;
    "--backup")
        create_backup
        ;;
    "--restore")
        if [ -z "${2:-}" ]; then
            ui_fail "Укажите файл для восстановления"
            exit 1
        fi
        restore_backup "$2"
        ;;
    "--diagnose")
        run_site_diagnostics_cli
        exit $?
        ;;
    "--ip-add")
        if [ -z "${2:-}" ]; then
            ui_fail "Укажите IP: adminpanel.sh --ip-add <IP>"
            exit 1
        fi
        ip_whitelist_apply add "$2"
        exit $?
        ;;
    "--ip-remove")
        if [ -z "${2:-}" ]; then
            ui_fail "Укажите IP: adminpanel.sh --ip-remove <IP>"
            exit 1
        fi
        ip_whitelist_apply remove "$2"
        exit $?
        ;;
    "--ip-add-temp")
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            ui_fail "Использование: adminpanel.sh --ip-add-temp <IP> <1h|12h|24h>"
            exit 1
        fi
        ip_whitelist_apply add-temp "$2" --duration "$3"
        exit $?
        ;;
    "--ip-list")
        ip_whitelist_run_cli list
        exit $?
        ;;
    *)
        if [ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
            ui_warn "AdminAntizapret не установлен."
            ui_info "Запустите setup.sh AntiZapret-VPN-ipv6 и выберите INSTALL_PANEL=y."
            exit 2
        else
            main_menu
        fi
        ;;
    esac
}

main "$@"
