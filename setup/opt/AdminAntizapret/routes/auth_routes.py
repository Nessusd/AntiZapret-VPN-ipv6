# Связывает парольный вход, CAPTCHA и общую политику веб-сессии.
import secrets
from datetime import timedelta
from typing import Any, Callable

from flask import (
    jsonify,
    make_response,
    redirect,
    render_template,
    request,
    session,
    url_for,
    flash,
)

from ip_blocked.constants import IP_BLOCKED_ACCESS_ENDPOINTS


def register_auth_routes(
    app,
    *,
    auth_manager,
    captcha_generator,
    ip_restriction,
    limiter,
    db,
    user_model,
    get_env_value,
    touch_active_web_session,
    remove_active_web_session,
    log_user_action_event=None,
) -> None:
    def _limit(rule: str) -> Callable:
        if limiter is None:
            return lambda fn: fn
        return limiter.limit(rule)

    def _get_remember_me_days() -> int:
        configured_value = app.config.get("REMEMBER_ME_DAYS")
        if isinstance(configured_value, int):
            return max(1, min(configured_value, 365))

        if configured_value is None:
            raw_value = (get_env_value("REMEMBER_ME_DAYS", "30") or "").strip()
        else:
            raw_value = str(configured_value).strip()

        try:
            return max(1, min(int(raw_value), 365))
        except (TypeError, ValueError):
            return 30

    def _finish_login(user: Any) -> None:
        # Новый идентификатор отличает этот вход от прежней веб-сессии.
        session["username"] = user.username
        session["user_role"] = user.role
        session["auth_sid"] = secrets.token_hex(16)
        session.pop("_active_session_touch_ts", None)
        session["attempts"] = 0

        try:
            touch_active_web_session(user.username, force=True)
        except Exception as e:
            db.session.rollback()
            app.logger.warning("Не удалось обновить активную сессию при входе: %s", e)

    @app.route("/login", methods=["GET", "POST"])
    @_limit("15 per minute;120 per hour")
    def login():
        if ip_restriction.is_enabled():
            client_ip = ip_restriction.get_client_ip()
            if not ip_restriction.is_ip_allowed(client_ip):
                return redirect(url_for("ip_blocked"))

        if "captcha" not in session:
            session["captcha"] = captcha_generator.generate_captcha()

        if request.method == "POST":
            attempts = session.get("attempts", 0)
            attempts += 1
            session["attempts"] = attempts
            if attempts > 2:
                user_captcha = request.form.get("captcha", "").upper()
                correct_captcha = session.get("captcha", "")

                if user_captcha != correct_captcha:
                    flash("Неверный код!", "error")
                    session["captcha"] = captcha_generator.generate_captcha()
                    return redirect(url_for("login"))

            username = request.form["username"]
            password = request.form["password"]
            remember_me = (request.form.get("remember_me") or "").strip().lower() in {
                "1",
                "true",
                "on",
                "yes",
            }

            user = user_model.query.filter_by(username=username).first()
            if user and user.check_password(password):
                if remember_me:
                    app.permanent_session_lifetime = timedelta(days=_get_remember_me_days())
                    session.permanent = True
                else:
                    session.permanent = False

                _finish_login(user)
                return redirect(url_for("index"))
            if callable(log_user_action_event):
                log_user_action_event(
                    "login_failed",
                    target_type="user",
                    target_name=username[:255] if username else None,
                    status="error",
                    details="invalid_credentials",
                )
            flash("Неверные учетные данные. Попробуйте снова.", "error")
            return redirect(url_for("login"))
        return render_template(
            "login.html",
            captcha=session["captcha"],
            remember_me_days=_get_remember_me_days(),
        )

    @app.route("/logout")
    def logout():
        try:
            remove_active_web_session()
        except Exception as e:
            db.session.rollback()
            app.logger.warning("Не удалось удалить активную сессию при logout: %s", e)

        session.pop("auth_sid", None)
        session.pop("_active_session_touch_ts", None)
        session.pop("username", None)
        return redirect(url_for("login"))

    @app.route("/api/session-heartbeat", methods=["GET"])
    @auth_manager.login_required
    def api_session_heartbeat():
        try:
            username = session.get("username")
            if username:
                touch_active_web_session(username, force=True)
            return jsonify({"success": True})
        except Exception as e:
            db.session.rollback()
            app.logger.warning("Ошибка heartbeat активной сессии: %s", e)
            return jsonify({"success": False}), 500

    @app.route("/refresh_captcha")
    def refresh_captcha():
        session["captcha"] = captcha_generator.generate_captcha()
        return session["captcha"]

    @app.route("/captcha.png")
    def captcha():
        session["captcha"] = captcha_generator.generate_captcha()
        img_io = captcha_generator.generate_captcha_image()

        response = make_response(img_io.getvalue())
        response.headers.set("Content-Type", "image/png")
        return response

    @app.before_request
    def check_ip_access():
        if request.endpoint == "static":
            return

        if not ip_restriction.is_enabled():
            return

        client_ip = ip_restriction.get_client_ip()

        if ip_restriction.is_ip_allowed(client_ip):
            ip_restriction.release_firewall_for_ip(client_ip)
            return

        if not ip_restriction.is_ip_allowed(client_ip):
            if ip_restriction.should_count_denied_access(client_ip, request.endpoint):
                ip_restriction.record_denied_access(client_ip)

            if ip_restriction.should_hard_deny(client_ip):
                if request.is_json:
                    return ip_restriction.build_denied_json_response(client_ip)
                return ip_restriction.build_hard_deny_response()

            if request.endpoint in IP_BLOCKED_ACCESS_ENDPOINTS:
                return

            if request.is_json:
                return ip_restriction.build_denied_json_response(client_ip)

            return redirect(url_for("ip_blocked"))

    @app.before_request
    def track_active_web_session():
        if request.endpoint == "static":
            return

        username = (session.get("username") or "").strip()
        if not username:
            return

        try:
            touch_active_web_session(username, force=False)
        except Exception as e:
            db.session.rollback()
            app.logger.warning("Не удалось обновить активную сессию: %s", e)
