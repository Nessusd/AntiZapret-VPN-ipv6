#!/bin/bash

# Удаление начинается с резервной копии и трогает только ресурсы, которыми
# владеет панель или которые однозначно распознаны по управляемым маркерам.
uninstall() {
    printf "\n"
    _m_top
    _m_title "Удаление AdminAntizapret"
    _m_sep
    _m_item "Это действие необратимо!"
    _m_bot
    printf "\n"

    ui_confirm "Вы уверены, что хотите удалить AdminAntizapret?" || {
        ui_ok "Удаление отменено"
        press_any_key
        return
    }

    local use_selfsigned=false use_letsencrypt=false use_nginx=false restore_unit
    local -a restore_units=()

    mapfile -t restore_units < <(
        systemctl list-units --all --plain --no-legend 'admin-antizapret-restore@*.service' 2>/dev/null |
            awk '{print $1}'
    )
    if [ "${#restore_units[@]}" -gt 0 ]; then
        # Активное восстановление может менять БД и файлы; его необходимо
        # остановить до создания последнего согласованного бэкапа.
        ui_info "Остановка активного восстановления перед резервным копированием..."
        if ! systemctl stop "${restore_units[@]}"; then
            ui_fail "Не удалось безопасно остановить восстановление панели"
            press_any_key
            return 1
        fi
        for restore_unit in "${restore_units[@]}"; do
            if systemctl is-active --quiet "$restore_unit"; then
                ui_fail "Задача восстановления всё ещё активна: $restore_unit"
                press_any_key
                return 1
            fi
        done
    fi

    create_backup

    if [ -f "$INSTALL_DIR/.env" ]; then
        if grep -q "USE_HTTPS=true" "$INSTALL_DIR/.env" 2>/dev/null; then
            if [ -f "/etc/ssl/certs/admin-antizapret.crt" ] && \
               [ -f "/etc/ssl/private/admin-antizapret.key" ]; then
                use_selfsigned=true
            elif grep -q "DOMAIN=" "$INSTALL_DIR/.env" 2>/dev/null; then
                use_letsencrypt=true
            fi
        elif grep -q "USE_HTTPS=false" "$INSTALL_DIR/.env" && \
             grep -q "DOMAIN=" "$INSTALL_DIR/.env" 2>/dev/null; then
            use_nginx=true
            use_letsencrypt=true
        fi
    fi

    ui_info "Остановка сервисов..."
    crontab -l 2>/dev/null | grep -v 'adminantizapret-nightly-idle-restart' | crontab - 2>/dev/null || true
    systemctl stop  "admin-antizapret-traffic-sync.timer"   2>/dev/null || true
    systemctl disable "admin-antizapret-traffic-sync.timer" 2>/dev/null || true
    systemctl stop  "admin-antizapret-traffic-sync.service" 2>/dev/null || true
    systemctl disable "admin-antizapret-traffic-sync.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/admin-antizapret-traffic-sync.timer"
    rm -f "/etc/systemd/system/admin-antizapret-traffic-sync.service"
    rm -f "/etc/systemd/system/admin-antizapret-restore@.service"
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    rm -rf "/var/lib/admin-antizapret"
    rm -f /run/admin-antizapret-restore.lock
    rm -f "/etc/letsencrypt/renewal-hooks/deploy/admin-antizapret-nginx"
    rm -f /run/admin-antizapret-certbot-redirect.state \
        /run/admin-antizapret-certbot-redirect.lock
    systemctl daemon-reload
    ui_ok "Сервисы остановлены"

    if [ "$use_selfsigned" = true ]; then
        ui_info "Удаление самоподписанного сертификата..."
        rm -f /etc/ssl/certs/admin-antizapret.crt
        rm -f /etc/ssl/private/admin-antizapret.key
        ui_ok "Сертификат удалён"
    fi

    if [ "$use_letsencrypt" = true ]; then
        local DOMAIN
        DOMAIN=$(grep "^DOMAIN=" "$INSTALL_DIR/.env" 2>/dev/null | cut -d'=' -f2 | tr -d '" ' || printf '')
		if [ -n "$DOMAIN" ] && ! [[ "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
			ui_warn "Некорректный домен в .env; сертификат и Nginx-конфигурация оставлены без изменений"
			DOMAIN=
		fi

        ui_warn "Обнаружены сертификаты Let's Encrypt для домена: $DOMAIN"
        if ui_confirm "Удалить сертификат и конфиг Nginx (если есть)?"; then
            if [ "$use_nginx" = true ] && [ -n "$DOMAIN" ]; then
                local conf="${DOMAIN//./_}"
                local nginx_config="/etc/nginx/sites-available/$conf"
                local nginx_enabled="/etc/nginx/sites-enabled/$conf"
                local nginx_owned=false
                # Пользовательский virtual host удалять нельзя. Старые установки
                # распознаются по полному набору ожидаемых директив.
                if grep -Fxq '# Managed by AntiZapret integrated installer' "$nginx_config" 2>/dev/null; then
                    nginx_owned=true
                elif [ -f "$nginx_config" ] && [ ! -L "$nginx_config" ] && \
                     [ -L "$nginx_enabled" ] && \
                     [ "$(readlink -f "$nginx_enabled")" = "$(readlink -f "$nginx_config")" ] && \
                     grep -Fq "server_name $DOMAIN;" "$nginx_config" && \
                     grep -Fq "ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;" "$nginx_config" && \
					 grep -Fq "ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;" "$nginx_config" && \
                     grep -Eq '^[[:space:]]*proxy_pass http://127\.0\.0\.1:[0-9]+;[[:space:]]*$' "$nginx_config"
                then
                    nginx_owned=true
                fi
                ui_info "Удаление конфигурации Nginx..."
                if [ "$nginx_owned" = true ]; then
                    rm -f "$nginx_config" "$nginx_enabled"
                    nginx -t && systemctl reload nginx 2>/dev/null || ui_warn "Nginx не перезагружен"
                else
                    ui_warn "Конфигурация Nginx не принадлежит AdminAntizapret и оставлена без изменений"
                fi
            fi
            if [ -n "$DOMAIN" ] && command -v certbot >/dev/null 2>&1; then
                ui_info "Удаление сертификата Let's Encrypt..."
                certbot delete --non-interactive --cert-name "$DOMAIN" >/dev/null 2>&1 || \
                    ui_warn "Сертификат $DOMAIN не найден или уже удалён"
            fi
            crontab -l 2>/dev/null | grep -v 'renew_cert.sh' | crontab - 2>/dev/null || true
            ui_ok "Сертификат и связанные файлы удалены"
        else
            ui_ok "Удаление сертификата отменено"
        fi

        local renewal_config="/etc/letsencrypt/renewal/${DOMAIN}.conf"
		if [ -n "$DOMAIN" ] && [ -f "$renewal_config" ] && [ ! -L "$renewal_config" ]; then
            sed -i "\\|$INSTALL_DIR/script_sh/certbot_standalone_|d" "$renewal_config"
        fi
    fi

    ui_info "Удаление файлов приложения..."
    rm -rf "$INSTALL_DIR"
    rm -f "$LOG_FILE"
    ui_ok "Файлы удалены"

    printf "\n"
    ui_ok "Удаление завершено"
    ui_info "Резервная копия сохранена в /var/backups/antizapret"
    press_any_key
    exit 0
}
