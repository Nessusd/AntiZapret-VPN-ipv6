from __future__ import annotations

import re
from typing import Any


def parse_action_details_kv(raw_details: str | None) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in str(raw_details or "").split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        key = key.strip()
        if not key:
            continue
        result[key] = value.strip()
    return result


def _parse_arrow_change(details: str | None) -> tuple[str, str] | None:
    text = str(details or "").strip()
    if "→" not in text:
        return None
    old_value, new_value = text.split("→", 1)
    return old_value.strip(), new_value.strip()


def _humanize_cron(cron_expr: str) -> str:
    parts = str(cron_expr or "").strip().split()
    if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
        minute, hour = int(parts[0]), int(parts[1])
        return f"ежедневно в {hour:02d}:{minute:02d}"
    return str(cron_expr or "").strip()


def _format_nightly_update_details(details: str | None) -> str:
    raw = str(details or "").strip()
    if not raw:
        return "Ночной рестарт: настройки изменены"

    enabled_match = re.search(r"enabled=(\S+)", raw)
    cron_match = re.search(r"cron=(.+?)\s+ttl=", raw)
    ttl_match = re.search(r"ttl=(\d+)", raw)
    touch_match = re.search(r"touch=(\d+)", raw)

    enabled_raw = (enabled_match.group(1) if enabled_match else "").lower()
    if enabled_raw in {"вкл", "1", "true", "yes"}:
        enabled_text = "включён"
    elif enabled_raw in {"выкл", "0", "false", "no"}:
        enabled_text = "выключен"
    else:
        enabled_text = "изменён"

    parts = [f"Ночной рестарт {enabled_text}"]
    if cron_match:
        parts.append(f"по расписанию {_humanize_cron(cron_match.group(1))}")
    if ttl_match:
        parts.append(f"TTL сессии {ttl_match.group(1)} с")
    if touch_match:
        parts.append(f"интервал активности {touch_match.group(1)} с")
    return ", ".join(parts)


_BACKUP_COMPONENT_LABELS_RU = {
    "db": "базы SQLite",
    "env": "файл .env",
    "data": "файлы data/",
}

_ROLE_LABELS_RU = {
    "admin": "администратор",
    "viewer": "наблюдатель",
}


def _format_backup_interval_ru(interval_token: str) -> str:
    raw = str(interval_token or "").strip().lower()
    if raw in {"1", "1d"}:
        return "каждый день"
    if raw.endswith("d") and raw[:-1].isdigit():
        days = int(raw[:-1])
        if days == 7:
            return "каждые 7 дней"
        if days == 30:
            return "каждые 30 дней"
        return f"каждые {days} дн."
    return raw or "—"


def _format_backup_components_ru(components_csv: str) -> str:
    parts = []
    for item in str(components_csv or "").split(","):
        key = item.strip().lower()
        if not key:
            continue
        parts.append(_BACKUP_COMPONENT_LABELS_RU.get(key, key))
    return ", ".join(parts) if parts else "—"


def _format_backup_settings_details_ru(details: str | None) -> str:
    raw = str(details or "").strip()
    if not raw:
        return "Настройки авто-бэкапа изменены"

    enabled_match = re.search(r"enabled=(\S+)", raw)
    interval_match = re.search(r"interval=(\S+)", raw)
    time_match = re.search(r"time=(\S+)", raw)
    components_match = re.search(r"components=([^\s]+)", raw)

    enabled_raw = (enabled_match.group(1) if enabled_match else "").lower()
    if enabled_raw in {"вкл", "1", "true", "yes"}:
        enabled_text = "включён"
    elif enabled_raw in {"выкл", "0", "false", "no"}:
        enabled_text = "выключен"
    else:
        enabled_text = "изменён"

    interval_text = _format_backup_interval_ru(interval_match.group(1) if interval_match else "")
    time_text = time_match.group(1) if time_match else "—"
    components_text = _format_backup_components_ru(
        components_match.group(1) if components_match else ""
    )

    return (
        f"Авто-бэкап {enabled_text}, интервал {interval_text}, время {time_text}, "
        f"состав: {components_text}"
    )


def _detail_int(detail_map: dict[str, str], key: str) -> int:
    try:
        return int(str(detail_map.get(key) or "0").strip())
    except ValueError:
        return 0


def _format_games_sync_line(event_key: str, details: str | None) -> str | None:
    detail_map = parse_action_details_kv(details)
    key = str(event_key or "").strip()

    if key == "settings_cidr_games_routes_sync":
        include_games = _detail_int(detail_map, "include_games")
        include_cidrs = _detail_int(detail_map, "include_cidrs")
        include_domains = _detail_int(detail_map, "include_domains")
        exclude_games = _detail_int(detail_map, "exclude_games")
        exclude_cidrs = _detail_int(detail_map, "exclude_cidrs")
        exclude_domains = _detail_int(detail_map, "exclude_domains")
        include_overlap = _detail_int(detail_map, "include_overlap")
        exclude_overlap = _detail_int(detail_map, "exclude_overlap")
        if include_games == 0 and exclude_games == 0 and include_cidrs == 0 and exclude_cidrs == 0:
            return "Игровые маршруты очищены"
        parts = []
        if include_games > 0 or include_cidrs > 0:
            chunk = f"VPN: {include_games} игр, {include_cidrs} CIDR"
            if include_domains > 0:
                chunk += f", {include_domains} доменов"
            if include_overlap > 0:
                chunk += f", пересечений {include_overlap}"
            parts.append(chunk)
        if exclude_games > 0 or exclude_cidrs > 0:
            chunk = f"DIRECT: {exclude_games} игр, {exclude_cidrs} CIDR"
            if exclude_domains > 0:
                chunk += f", {exclude_domains} доменов"
            if exclude_overlap > 0:
                chunk += f", пересечений {exclude_overlap}"
            parts.append(chunk)
        return " · ".join(parts) if parts else "Игровые маршруты обновлены"

    scope = "exclude" if key == "settings_cidr_games_exclude_sync" else "include"
    scope_label = "DIRECT" if scope == "exclude" else "VPN"
    games = _detail_int(detail_map, "selected_games")
    domains = _detail_int(detail_map, "domains")
    cidrs = _detail_int(detail_map, "cidrs")
    overlap = _detail_int(detail_map, "overlap")
    if games == 0 and cidrs == 0 and domains == 0:
        return f"{scope_label}: фильтры очищены"
    parts = [f"{scope_label}: {games} игр", f"{cidrs} CIDR"]
    if domains > 0:
        parts.append(f"{domains} доменов")
    if overlap > 0:
        parts.append(f"пересечений {overlap}")
    return ", ".join(parts)


def _humanize_raw_details(details: str | None) -> str | None:
    """Переводит технические причины и параметры записей журнала."""
    text = str(details or "").strip()
    if not text:
        return None
    if "→" in text:
        return text

    lowered = text.lower()
    replacements = {
        "invalid_credentials": "неверный логин или пароль",
        "manual_create": "ручное создание",
        "manual_unblock": "ручная разблокировка",
        "temp_block": "временная блокировка",
        "permanent_block": "постоянная блокировка",
        "unblock": "разблокировка",
        "success": "успешно",
        "failed": "ошибка",
        "warning": "предупреждение",
        "web_login": "вход через веб",
    }
    for src, dst in replacements.items():
        if lowered == src:
            return dst

    if "=" in text and re.search(r"\b(enabled|interval|components|cron|ttl|touch)=\S+", text):
        if "components=" in text and "interval=" in text:
            return _format_backup_settings_details_ru(text)
        if "cron=" in text or "enabled=" in text:
            return _format_nightly_update_details(text)

    return None


def _translate_auth_failure_detail(raw: str) -> str:
    """Translate raw English auth failure detail strings to Russian."""
    v = raw.strip().lower()
    if not raw.strip():
        return "Причина не указана"
    if "invalid_credentials" in v:
        return "Неверный логин или пароль"
    if "invalid_hash" in v or "hash" in v:
        return "Недействительная подпись запроса"
    if "expired" in v:
        return "Срок действия авторизации истёк"
    return raw


def resolve_user_action_source(event_type: str | None, details: str | None) -> tuple[str, str]:
    event_key = str(event_type or "").strip().lower()
    detail_map = parse_action_details_kv(details)
    via = str(detail_map.get("via") or "").strip().lower()
    source = str(detail_map.get("source") or "").strip().lower()
    channel = str(detail_map.get("channel") or "").strip().lower()

    if source in {"web_settings", "web", "panel"}:
        return "web", "🖥 Панель"

    if channel in {"qr_one_time", "qr", "one_time"}:
        return "qr", "🔗 QR"

    if channel in {"public", "public_download"}:
        return "public", "🌍 Публичное скачивание"

    if channel in {"api", "rest", "webapi"}:
        return "api", "🔌 API"

    if channel in {"web", "panel", "ui"}:
        return "web", "🖥 Панель"

    return "web", "🖥 Панель"


def user_action_event_label(event_type: str | None) -> str:
    mapping = {
        "config_create": "Создание конфига",
        "config_delete": "Удаление конфига",
        "config_recreate": "Пересоздание конфига",
        "config_action": "Действие с конфигом",
        "config_download": "Скачивание конфига",
        "openvpn_client_block_toggle": "Изменение статуса OpenVPN-клиента",
        "settings_port_update": "Изменение порта панели",
        "settings_qr_ttl_update": "Изменение TTL одноразовой ссылки",
        "settings_qr_max_downloads_update": "Изменение лимита скачиваний QR-ссылки",
        "settings_qr_pin_clear": "Очистка PIN одноразовой ссылки",
        "settings_qr_pin_update": "Изменение PIN одноразовой ссылки",
        "settings_public_download_toggle": "Переключение публичного скачивания",
        "settings_nightly_update": "Изменение настроек ночного рестарта",
        "settings_user_create": "Создание пользователя",
        "settings_user_delete": "Удаление пользователя",
        "settings_user_role_update": "Изменение роли пользователя",
        "settings_user_password_update": "Смена пароля пользователя",
        "settings_ip_add": "Добавление IP-ограничения",
        "settings_ip_add_temp": "Временный доступ по IP",
        "settings_ip_remove_temp": "Удаление временного IP",
        "settings_ip_scanner_block": "Защита от сканеров (IP)",
        "settings_ip_scanner_bans_clear": "Сброс банов сканеров",
        "settings_ip_scanner_unban": "Разблокировка IP сканера",
        "settings_ip_remove": "Удаление IP-ограничения",
        "settings_ip_clear": "Сброс IP-ограничений",
        "settings_ip_bulk_enable": "Массовое включение IP-ограничений",
        "settings_ip_add_from_file": "Добавление IP из файла",
        "settings_ip_file_toggle": "Изменение статуса IP-файла",
        "settings_restart_service": "Запуск перезапуска службы",
        "settings_run_doall": "Применение изменений (doall)",
        "settings_viewer_access_grant": "Выдача доступа viewer",
        "settings_viewer_access_revoke": "Отзыв доступа viewer",
        "settings_antizapret_update": "Изменение настроек Antizapret",
        # Auth
        "login_failed": "Неудачная попытка входа",
        # Antizapret / обновления
        "settings_antifilter_refresh": "Обновление списков Antizapret",
        # CIDR
        "settings_cidr_update_queued": "Обновление CIDR-файлов",
        "settings_cidr_rollback_queued": "Откат CIDR-файлов",
        "settings_cidr_db_refresh_queued": "Обновление базы CIDR",
        "settings_cidr_db_clear": "Очистка базы CIDR",
        "settings_cidr_generate_from_db": "Генерация CIDR из базы",
        "settings_cidr_games_sync": "Синхронизация игровых хостов",
        "settings_cidr_games_exclude_sync": "Синхронизация игровых хостов (DIRECT)",
        "settings_cidr_games_routes_sync": "Синхронизация игровых маршрутов",
        "settings_cidr_total_limit_update": "Изменение лимита CIDR",
        "settings_cidr_preset_create": "Создание пресета CIDR",
        "settings_cidr_preset_update": "Изменение пресета CIDR",
        "settings_cidr_preset_delete": "Удаление пресета CIDR",
        "settings_cidr_preset_reset": "Сброс пресета CIDR до базового",
        # IP
        "settings_ip_files_sync": "Синхронизация IP-файлов",
        "settings_backup_update": "Изменение настроек бэкапов",
        "settings_backup_create": "Создание бэкапа",
        "settings_backup_restore": "Восстановление из бэкапа",
        "settings_backup_delete": "Удаление бэкапа",
        "settings_monitor_update": "Изменение мониторинга ресурсов",
        "settings_feature_toggles_update": "Изменение модулей и фоновых задач",
    }
    event_key = str(event_type or "").strip()


    if event_key in mapping:
        return mapping[event_key]
    fallback = event_key.replace("_", " ").strip()
    return fallback.capitalize() if fallback else "Событие"


def user_action_event_display(
    event_type: str | None,
    target_name: str | None,
    target_type: str | None,
    details: str | None,
) -> str:
    event_key = str(event_type or "").strip()
    target_value = str(target_name or "").strip()
    target_kind = str(target_type or "").strip()
    details_value = str(details or "").strip()
    detail_map = parse_action_details_kv(details_value)

    label = user_action_event_label(event_key)

    # ── QR settings ─────────────────────────────────────────────────────
    if event_key == "settings_qr_max_downloads_update":
        arrow = _parse_arrow_change(details_value)
        if arrow:
            return f"Лимит скачиваний QR: с {arrow[0]} до {arrow[1]}"
        value = detail_map.get("value")
        return f"Лимит скачиваний QR-ссылки изменён до {value}" if value else label

    if event_key == "settings_qr_ttl_update":
        arrow = _parse_arrow_change(details_value)
        if arrow:
            old_val, new_val = arrow
            new_clean = new_val.rstrip("с").strip()
            old_clean = old_val.rstrip("с").strip()
            return f"TTL QR-ссылки: с {old_clean} до {new_clean} с"
        value = detail_map.get("value")
        return f"TTL одноразовой ссылки изменён до {value} сек." if value else label

    if event_key == "settings_qr_pin_update":
        length = detail_map.get("length")
        if length:
            return f"PIN QR-ссылки обновлён (длина {length} цифр)"
        return "PIN одноразовой ссылки обновлён"

    if event_key == "settings_qr_pin_clear":
        return "PIN одноразовой ссылки сброшен"

    # ── Порт ────────────────────────────────────────────────────────────
    if event_key == "settings_port_update":
        arrow = _parse_arrow_change(details_value)
        if arrow:
            return f"Порт панели изменён: с {arrow[0]} на {arrow[1]}"
        value = detail_map.get("value")
        return f"Порт панели изменён на {value}" if value else label

    # ── Публичное скачивание ────────────────────────────────────────────
    if event_key == "settings_public_download_toggle":
        enabled = detail_map.get("enabled")
        if enabled == "1":
            return "Публичное скачивание конфигов: включено"
        if enabled == "0":
            return "Публичное скачивание конфигов: выключено"
        return label

    # ── Конфиги ─────────────────────────────────────────────────────────
    if event_key == "config_download" and target_value:
        return f"Скачивание конфига: {target_value}"


    if event_key in {"config_create", "config_delete", "config_recreate", "config_action"} and target_value:
        return f"{label}: {target_value}"


    # ── OpenVPN-клиент ──────────────────────────────────────────────────
    if event_key == "openvpn_client_block_toggle":
        blocked_state = str(detail_map.get("blocked") or "").strip()
        client = target_value or "—"
        if blocked_state == "1":
            return f"Клиент {client}: доступ заблокирован"
        if blocked_state == "0":
            return f"Клиент {client}: доступ разблокирован"
        return f"{label}: {client}" if target_value else label

    # ── Применение изменений ────────────────────────────────────────────
    if event_key == "settings_run_doall":
        task_id = str(detail_map.get("task_id") or "").strip()
        return f"Применение изменений: задача {task_id}" if task_id else "Применение изменений (doall)"

    if event_key == "settings_restart_service":
        svc = target_value or "служба"
        return f"Запуск перезапуска: {svc}"

    # ── Пользователи ────────────────────────────────────────────────────
    if event_key in {
        "settings_user_create", "settings_user_delete",
        "settings_user_role_update", "settings_user_password_update",
    } and target_value:
        return f"{label}: {target_value}"

    # ── IP-ограничения ──────────────────────────────────────────────────
    if event_key == "settings_ip_clear":
        return "Все IP-ограничения сброшены"

    if event_key == "settings_ip_bulk_enable":
        return "IP-ограничения: массовое включение"

    if event_key == "settings_ip_add_from_file":
        return f"IP-адреса добавлены из файла: {target_value}" if target_value else label

    if event_key == "settings_ip_files_sync":
        synced = detail_map.get("synced", "")
        updated = detail_map.get("updated", "")
        parts = []
        if synced:
            parts.append(f"синхронизировано: {synced}")
        if updated:
            parts.append(f"обновлено: {updated}")
        suffix = "; ".join(parts)
        return f"Синхронизация IP-файлов — {suffix}" if suffix else "Синхронизация IP-файлов выполнена"

    if target_value and target_kind in {"ip_restriction", "ip_file"}:
        return f"{label}: {target_value}"

    # ── Ночной рестарт ──────────────────────────────────────────────────
    if event_key == "settings_nightly_update":
        if "cron=" in details_value or "enabled=" in details_value:
            return _format_nightly_update_details(details_value)
        enabled = detail_map.get("enabled")
        if enabled == "1":
            return "Ночной рестарт: включён"
        if enabled == "0":
            return "Ночной рестарт: выключен"
        return label

    # ── Viewer-доступ ───────────────────────────────────────────────────
    if event_key in {"settings_viewer_access_grant", "settings_viewer_access_revoke"} and target_value:
        return f"{label}: {target_value}"

    # ── CIDR ────────────────────────────────────────────────────────────
    if event_key == "settings_cidr_total_limit_update":
        value = detail_map.get("value")
        return f"Лимит CIDR изменён: {value} маршрутов" if value else label

    if event_key == "settings_cidr_games_sync":
        formatted = _format_games_sync_line(event_key, details)
        if formatted:
            return formatted
        games = detail_map.get("selected_games", "")
        domains = detail_map.get("domains", "")
        cidrs = detail_map.get("cidrs", "")
        parts = []
        if _detail_int(detail_map, "selected_games") > 0:
            parts.append(f"игр: {_detail_int(detail_map, 'selected_games')}")
        if _detail_int(detail_map, "domains") > 0:
            parts.append(f"доменов: {_detail_int(detail_map, 'domains')}")
        if _detail_int(detail_map, "cidrs") > 0:
            parts.append(f"CIDR: {_detail_int(detail_map, 'cidrs')}")
        suffix = ", ".join(parts)
        return f"Синхронизация игровых хостов — {suffix}" if suffix else "Синхронизация игровых хостов — фильтры очищены"

    if event_key in {"settings_cidr_games_exclude_sync", "settings_cidr_games_routes_sync"}:
        formatted = _format_games_sync_line(event_key, details)
        if formatted:
            return formatted

    if event_key in {
        "settings_cidr_preset_create", "settings_cidr_preset_update",
        "settings_cidr_preset_delete", "settings_cidr_preset_reset",
    } and target_value:
        return f"{label}: {target_value}"

    if event_key in {
        "settings_cidr_update_queued", "settings_cidr_rollback_queued",
        "settings_cidr_db_refresh_queued", "settings_cidr_db_clear",
        "settings_cidr_generate_from_db",
    }:
        scope = target_value if target_value and target_value != "all" else "все файлы"
        return f"{label} ({scope})"

    # ── Antizapret ──────────────────────────────────────────────────────
    if event_key == "settings_antifilter_refresh":
        return "Обновление списков Antizapret: запущена загрузка"

    if event_key == "settings_antizapret_update":
        return label

    # ── Вход ────────────────────────────────────────────────────────────
    if event_key == "login_failed":
        return f"Неудачная попытка входа: пользователь «{target_value}»" if target_value else label

    return label


def _humanize_boolean_flag(raw: str | None) -> str:
    value = str(raw or "").strip().lower()
    if value in {"1", "true", "yes", "вкл"}:
        return "включено"
    if value in {"0", "false", "no", "выкл"}:
        return "выключено"
    return value or "—"


def _humanize_source_flag(raw: str | None) -> str:
    value = str(raw or "").strip().lower()
    if value in {"web", "panel", "web_settings"}:
        return "веб-панель"
    return value or "панель"


def _humanize_user_action_details(event_key: str, details_value: str) -> str:
    if not details_value:
        return "-"

    if "→" in details_value and event_key not in {
        "settings_nightly_update",
        "settings_backup_update",
    }:
        old_value, new_value = _parse_arrow_change(details_value) or ("—", "—")
        return f"Изменено: с {old_value} на {new_value}"

    if event_key == "login_failed":
        translated = _translate_auth_failure_detail(details_value)
        return translated if translated != details_value else "Ошибка входа"

    if event_key == "settings_user_password_update":
        return "Пароль успешно изменён"


    if event_key in {"settings_viewer_access_grant", "settings_viewer_access_revoke"}:
        detail_map = parse_action_details_kv(details_value)
        count = detail_map.get("configs")
        group = detail_map.get("group")
        action_text = "Выдан доступ" if event_key.endswith("grant") else "Доступ отозван"
        if count and group:
            return f"{action_text}: {count} конфиг(ов), группа {group}"
        return action_text

    if event_key == "settings_ip_file_toggle" and "|" in details_value:
        parts = [part.strip() for part in details_value.split("|")]
        if len(parts) >= 3:
            state_text = "включён" if parts[0] == "вкл" else "выключен"
            return f"Файл «{parts[1]}» {state_text}, затронуто {parts[2]}"

    detail_map = parse_action_details_kv(details_value)
    if detail_map:
        if event_key == "settings_port_update":
            port = detail_map.get("value", "—")
            restart = _humanize_boolean_flag(detail_map.get("restart"))
            source = _humanize_source_flag(detail_map.get("via"))
            return f"Новый порт: {port}; перезапуск: {restart}; источник: {source}"

        if event_key == "settings_ip_add_temp":
            duration = detail_map.get("duration", "—")
            return f"Временный доступ выдан на {duration}"

        if event_key == "settings_ip_bulk_enable":
            entries = detail_map.get("entries", "0")
            return f"Включено IP-ограничений: {entries}"

        if event_key == "settings_ip_files_sync":
            synced = detail_map.get("synced", "0")
            updated = detail_map.get("updated", "0")
            missing = detail_map.get("missing")
            base = f"Синхронизировано файлов: {synced}; обновлено: {updated}"
            if missing:
                return f"{base}; отсутствуют источники: {missing.replace(',', ', ')}"
            return base

        if event_key == "settings_ip_scanner_block":
            return (
                f"Защита: {_humanize_boolean_flag(detail_map.get('enabled'))}; "
                f"порог попыток: {detail_map.get('max', '—')}; "
                f"окно: {detail_map.get('window', '—')} сек.; "
                f"бан: {detail_map.get('ban', '—')} сек.; "
                f"бан на странице блокировки: {_humanize_boolean_flag(detail_map.get('dwell'))}; "
                f"iptables whitelist: {_humanize_boolean_flag(detail_map.get('whitelist_fw'))}"
            )


        if event_key == "settings_user_create":
            role = detail_map.get("роль", detail_map.get("role", "admin"))
            role_h = _ROLE_LABELS_RU.get(str(role).lower(), role)
            return f"Роль: {role_h}"

    humanized = _humanize_raw_details(details_value)
    if humanized:
        return humanized

    return details_value


def user_action_details_label(event_type: str | None, details: str | None) -> str:
    event_key = str(event_type or "").strip()
    details_value = str(details or "").strip()
    if not details_value:
        return "-"


    if event_key == "settings_nightly_update" and (
        "cron=" in details_value or "enabled=" in details_value
    ):
        return _format_nightly_update_details(details_value)

    return _humanize_user_action_details(event_key, details_value)


_STATUS_DISPLAY_MAP = {
    "success": "Успешно",
    "ok": "Успешно",
    "info": "Инфо",
    "warning": "Предупреждение",
    "warn": "Предупреждение",
    "error": "Ошибка",
    "failed": "Ошибка",
    "fail": "Ошибка",
}


def _normalize_result_status(raw_status: str | None, *, is_security_alert: bool) -> tuple[str, str]:
    normalized = str(raw_status or "").strip().lower()
    if not normalized:
        normalized = "success"
    if is_security_alert and normalized not in {"error", "failed", "fail"}:
        normalized = "warning"
    return normalized, _STATUS_DISPLAY_MAP.get(normalized, normalized.capitalize())


def _csv_safe_value(raw_value: str | None) -> str:
    # Keep CSV rows single-line and predictable.
    return str(raw_value or "").replace("\r", " ").replace("\n", " ").strip()


def build_user_action_audit_view(rows: list[Any] | None) -> list[dict[str, Any]]:
    view_rows: list[dict[str, Any]] = []
    for row in rows or []:
        event_type = str(getattr(row, "event_type", "") or "").strip()
        target_type = str(getattr(row, "target_type", "") or "").strip()
        target_name = str(getattr(row, "target_name", "") or "").strip()
        target_display = target_name or "-"
        if target_type:
            target_display = f"{target_display} ({target_type})" if target_name else target_type

        source_kind, source_label = resolve_user_action_source(event_type, getattr(row, "details", None))

        _SECURITY_ALERT_EVENTS = {
            "login_failed",
        }
        is_security_alert = event_type in _SECURITY_ALERT_EVENTS
        status, status_display = _normalize_result_status(
            getattr(row, "status", None),
            is_security_alert=is_security_alert,
        )
        actor_display = str(getattr(row, "actor_username", "") or "").strip() or "system/anonymous"
        details_display = user_action_details_label(event_type, getattr(row, "details", None))
        if is_security_alert or status in {"error", "failed", "fail"}:
            severity = "high"
        elif status in {"warning", "warn"}:
            severity = "medium"
        else:
            severity = "low"

        created_at = row.created_at
        event_display = user_action_event_display(
            event_type,
            target_name,
            target_type,
            getattr(row, "details", None),
        )
        csv_action = _csv_safe_value(event_display)
        csv_details = _csv_safe_value(details_display if details_display != "-" else "")
        csv_ip = _csv_safe_value(getattr(row, "remote_addr", None) or "")
        csv_user = _csv_safe_value(actor_display)
        csv_result = _csv_safe_value(status_display)

        view_rows.append(
            {
                "created_at": created_at,
                "created_at_iso": created_at.isoformat(),
                "created_at_ts": int(created_at.timestamp()),
                "actor_username": row.actor_username,
                "actor_display": actor_display,
                "event_type": event_type,
                "event_label": user_action_event_label(event_type),
                "event_display": event_display,
                "target_display": target_display,
                "status": status,
                "status_display": status_display,
                "details": str(getattr(row, "details", "") or "").strip() or "-",
                "details_display": details_display,
                "remote_addr": getattr(row, "remote_addr", None),
                "source_kind": source_kind,
                "source_label": source_label,
                "is_security_alert": is_security_alert,
                "severity": severity,
                "search_blob": " ".join(
                    [
                        actor_display.lower(),
                        event_display.lower(),
                        str(details_display or "").lower(),
                        str(getattr(row, "remote_addr", "") or "").lower(),
                        str(status_display).lower(),
                        str(source_label).lower(),
                    ]
                ).strip(),
                "csv_row": {
                    "timestamp": created_at.strftime("%Y-%m-%d %H:%M:%S"),
                    "username": csv_user,
                    "action": csv_action,
                    "ip": csv_ip or "—",
                    "result": csv_result,
                    "details": csv_details or "—",
                },
            }
        )
    return view_rows


# ── Session grouping ───────────────────────────────────────────────────────


def _make_session(rows: list[dict[str, Any]], index: int) -> dict[str, Any]:
    alert_count = sum(1 for r in rows if r.get("is_security_alert"))
    ips: list[str] = list(dict.fromkeys(r["remote_addr"] for r in rows if r.get("remote_addr")))
    if len(ips) == 1:
        ip_display = ips[0]
    elif len(ips) > 1:
        ip_display = "разные IP"
    else:
        ip_display = "—"
    return {
        "session_id": str(index),
        "actor_username": rows[0]["actor_username"] or "system/anonymous",
        "session_end": rows[0]["created_at"],     # newest (rows are DESC)
        "session_start": rows[-1]["created_at"],  # oldest
        "session_date": rows[0]["created_at"].date().isoformat(),  # UTC date for day grouping
        "ip_display": ip_display,
        "row_count": len(rows),
        "alert_count": alert_count,
        "has_alerts": alert_count > 0,
        "rows": rows,
    }


def _make_day_group(date_key: str, sessions: list[dict[str, Any]]) -> dict[str, Any]:
    total_rows = sum(s["row_count"] for s in sessions)
    total_alerts = sum(s["alert_count"] for s in sessions)
    return {
        "date_key": date_key,
        "date_utc": sessions[0]["session_end"].isoformat(),
        "sessions": sessions,
        "session_count": len(sessions),
        "row_count": total_rows,
        "alert_count": total_alerts,
        "has_alerts": total_alerts > 0,
    }


def build_user_action_sessions(
    rows: list[Any] | None,
    gap_seconds: int = 7200,
) -> list[dict[str, Any]]:
    """Group flat UserActionLog rows into sessions.

    A new session starts when the user changes, the time gap between consecutive
    actions exceeds gap_seconds (default 2 h), or an anonymous user changes IP.
    """
    flat = build_user_action_audit_view(rows)
    if not flat:
        return []

    sessions: list[dict[str, Any]] = []
    current: list[dict[str, Any]] = [flat[0]]

    for row in flat[1:]:
        last = current[-1]  # oldest so far in current session (DESC order)
        curr_user = row["actor_username"] or "system/anonymous"
        last_user = last["actor_username"] or "system/anonymous"

        same_user = curr_user == last_user
        gap = (last["created_at"] - row["created_at"]).total_seconds()
        within_gap = gap <= gap_seconds

        is_anon = not (row["actor_username"] or "").strip()
        diff_ip = is_anon and row.get("remote_addr") != last.get("remote_addr")

        if same_user and within_gap and not diff_ip:
            current.append(row)
        else:
            sessions.append(_make_session(current, len(sessions)))
            current = [row]

    sessions.append(_make_session(current, len(sessions)))
    return sessions


def build_user_action_day_groups(
    rows: list[Any] | None,
    gap_seconds: int = 7200,
) -> list[dict[str, Any]]:
    """Group sessions by calendar day (UTC). Returns DESC-ordered day groups."""
    sessions = build_user_action_sessions(rows, gap_seconds)
    if not sessions:
        return []

    groups: list[dict[str, Any]] = []
    current_date = sessions[0]["session_date"]
    current_sessions: list[dict[str, Any]] = [sessions[0]]

    for session in sessions[1:]:
        if session["session_date"] == current_date:
            current_sessions.append(session)
        else:
            groups.append(_make_day_group(current_date, current_sessions))
            current_date = session["session_date"]
            current_sessions = [session]

    groups.append(_make_day_group(current_date, current_sessions))
    return groups
