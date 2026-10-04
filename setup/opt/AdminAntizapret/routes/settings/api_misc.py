"""Settings API: экспорт журнала действий пользователей."""

import csv
import io
from datetime import datetime, timezone

from flask import Response, request

from core.services.audit_view_presenter import build_user_action_audit_view


def register_settings_misc_api_routes(
    app,
    *,
    auth_manager,
    user_action_log_model,
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
