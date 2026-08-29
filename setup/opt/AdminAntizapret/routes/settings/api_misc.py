"""Settings API: экспорт журналов, мониторинг и проверка Telegram."""

import csv
import io
import os
from datetime import datetime, timezone

from flask import Response, jsonify, request, session

from core.services.audit_view_presenter import build_user_action_audit_view
from core.services.tg_notify import send_tg_message


def register_settings_misc_api_routes(
    app,
    *,
    auth_manager,
    user_model,
    user_action_log_model,
    set_env_value,
    get_env_value,
    log_user_action_event,
):
    @app.route("/api/settings/action-logs/export", methods=["GET"])
    @auth_manager.admin_required
    def api_settings_action_logs_export():
        q = (request.args.get("q") or "").strip().lower()
        src = (request.args.get("src") or "").strip().lower()
        user = (request.args.get("user") or "").strip()
        status = (request.args.get("status") or "").strip().lower()
        sort = (request.args.get("sort") or "time_desc").strip().lower()
        alert_only = (request.args.get("alert_only") or "").strip() in {"1", "true", "yes", "on"}

        rows = user_action_log_model.query.order_by(
            user_action_log_model.created_at.desc()
        ).limit(300).all()
        view_rows = build_user_action_audit_view(rows)

        filtered_rows = []
        for row in view_rows:
            row_src = str(row.get("source_kind") or "").lower()
            row_user = str(row.get("actor_display") or "")
            row_status = str(row.get("status") or "").lower()
            row_alert = bool(row.get("is_security_alert"))
            row_search = str(row.get("search_blob") or "").lower()
            if src and row_src != src:
                continue
            if user and row_user != user:
                continue
            if status and row_status != status:
                continue
            if alert_only and not row_alert:
                continue
            if q and q not in row_search:
                continue
            filtered_rows.append(row)

        if sort == "time_asc":
            filtered_rows.sort(key=lambda r: int(r.get("created_at_ts") or 0))
        elif sort == "user_asc":
            filtered_rows.sort(key=lambda r: str(r.get("actor_display") or "").lower())
        elif sort == "result_asc":
            filtered_rows.sort(key=lambda r: str(r.get("status_display") or "").lower())
        else:
            filtered_rows.sort(key=lambda r: int(r.get("created_at_ts") or 0), reverse=True)

        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["Дата/время", "Пользователь", "Действие", "IP", "Результат", "Детали"])
        for row in filtered_rows:
            csv_row = row.get("csv_row") or {}
            writer.writerow(
                [
                    csv_row.get("timestamp", ""),
                    csv_row.get("username", ""),
                    csv_row.get("action", ""),
                    csv_row.get("ip", "—"),
                    csv_row.get("result", ""),
                    csv_row.get("details", "—"),
                ]
            )

        csv_payload = "\ufeff" + output.getvalue()
        filename = f"action_logs_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.csv"
        return Response(
            csv_payload,
            mimetype="text/csv; charset=utf-8",
            headers={
                "Content-Disposition": f'attachment; filename="{filename}"',
                "Cache-Control": "no-store",
            },
        )

    @app.route("/api/monitor-settings", methods=["POST"])
    @auth_manager.admin_required
    def api_monitor_settings():
        data = request.get_json(silent=True) or {}

        def _int_clamp(val, lo, hi, default):
            try:
                v = int(str(val).strip())
                return max(lo, min(hi, v))
            except (TypeError, ValueError):
                return default

        cpu_threshold = _int_clamp(data.get("cpu_threshold"), 1, 100, 90)
        ram_threshold = _int_clamp(data.get("ram_threshold"), 1, 100, 90)
        interval_sec  = _int_clamp(data.get("interval_seconds"), 10, 3600, 60)
        cooldown_min  = _int_clamp(data.get("cooldown_minutes"), 1, 1440, 30)

        set_env_value("MONITOR_CPU_THRESHOLD", str(cpu_threshold))
        set_env_value("MONITOR_RAM_THRESHOLD", str(ram_threshold))
        set_env_value("MONITOR_CHECK_INTERVAL_SECONDS", str(interval_sec))
        set_env_value("MONITOR_COOLDOWN_MINUTES", str(cooldown_min))
        os.environ["MONITOR_CPU_THRESHOLD"] = str(cpu_threshold)
        os.environ["MONITOR_RAM_THRESHOLD"] = str(ram_threshold)
        os.environ["MONITOR_CHECK_INTERVAL_SECONDS"] = str(interval_sec)
        os.environ["MONITOR_COOLDOWN_MINUTES"] = str(cooldown_min)

        log_user_action_event(
            "settings_monitor_update",
            target_type="monitor",
            target_name="resource_monitor",
            details=f"cpu={cpu_threshold}% ram={ram_threshold}% interval={interval_sec}с cooldown={cooldown_min}мин",
        )
        return jsonify({"success": True, "message": "Настройки мониторинга сохранены"})

    @app.route("/api/tg-notify-test", methods=["POST"])
    @auth_manager.admin_required
    def api_tg_notify_test():
        data = request.get_json(silent=True) or {}
        target_username = (data.get("username") or "").strip()
        current_username = session.get("username", "")
        if not target_username or target_username != current_username:
            return jsonify({"success": False, "message": "Тест разрешён только для собственного аккаунта"}), 403

        user = user_model.query.filter_by(username=target_username).first()
        if not user or not user.telegram_id:
            return jsonify({"success": False, "message": "Telegram ID не привязан"}), 400

        bot_token = (get_env_value("TELEGRAM_AUTH_BOT_TOKEN", "") or "").strip()
        if not bot_token:
            return jsonify({"success": False, "message": "Бот не настроен"}), 400

        _ev_labels = [
            ("login_success",   "Успешный вход"),
            ("login_failed",    "Неверный пароль"),
            ("tg_unlinked",     "Вход с непривязанным TG ID"),
            ("config_create",   "Создание / пересоздание конфига"),
            ("config_delete",   "Удаление конфига"),
            ("user_create",     "Добавление пользователя"),
            ("user_delete",     "Удаление пользователя"),
            ("client_ban",      "Блокировка / разблокировка клиента"),
            ("traffic_limit",   "Лимит трафика (блок / авторазблокировка)"),
            ("settings_change", "Изменение настроек"),
            ("high_cpu",        "Высокая нагрузка CPU"),
            ("high_ram",        "Высокая нагрузка RAM"),
        ]
        enabled = [label for key, label in _ev_labels if user.has_tg_notify_event(key)]
        events_text = "\n".join(f"  ✓ {l}" for l in enabled) if enabled else "  (нет включённых событий)"

        text = (
            "🔔 <b>Тест уведомлений AdminAntiZapret</b>\n\n"
            f"Аккаунт: <code>{target_username}</code>\n\n"
            f"Включённые события:\n{events_text}"
        )
        send_tg_message(bot_token, user.telegram_id, text)
        return jsonify({"success": True, "message": "Тестовое сообщение отправлено"})
