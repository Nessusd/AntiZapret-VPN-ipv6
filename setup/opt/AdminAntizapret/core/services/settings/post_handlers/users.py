# Выполняет административные действия с пользователями через один валидируемый POST.
from core.services.feature_toggles import app_module_disabled_message, is_app_module_enabled

_USER_SETTINGS_FORM_KEYS = (
    "username",
    "delete_username",
    "change_role_username",
    "change_password_username",
)


def handle_users_settings(
    form,
    *,
    flash,
    session,
    db,
    user_model,
    log_user_action_event,
    redirect_url,
    get_env_value=None,
):
    if get_env_value is not None and not is_app_module_enabled("user_management", get_env_value=get_env_value):
        if any(form.get(key) for key in _USER_SETTINGS_FORM_KEYS):
            flash(app_module_disabled_message("user_management"), "error")
            return redirect_url
        return None

    username = form.get("username")
    password = form.get("password")
    if username and password:
        if len(password) < 8:
            flash("Пароль должен содержать минимум 8 символов!", "error")
        else:
            role = form.get("role", "admin")
            if role not in ("admin", "viewer"):
                role = "admin"
            if user_model.query.filter_by(username=username).first():
                flash(f"Пользователь '{username}' уже существует!", "error")
            else:
                user = user_model(
                    username=username,
                    role=role,
                )
                user.set_password(password)
                db.session.add(user)
                db.session.commit()
                flash(f"Пользователь '{username}' ({role}) успешно добавлен!", "success")
                log_user_action_event(
                    "settings_user_create",
                    target_type="user",
                    target_name=username,
                    details=f"роль={role}",
                )

    delete_username = form.get("delete_username")
    if delete_username:
        if delete_username == session.get("username"):
            flash("Нельзя удалить собственный аккаунт!", "error")
        else:
            user = user_model.query.filter_by(username=delete_username).first()
            if user:
                db.session.delete(user)
                db.session.commit()
                flash(f"Пользователь '{delete_username}' успешно удалён!", "success")
                log_user_action_event(
                    "settings_user_delete",
                    target_type="user",
                    target_name=delete_username,
                )
            else:
                flash(f"Пользователь '{delete_username}' не найден!", "error")

    change_role_username = form.get("change_role_username")
    new_role = form.get("new_role")
    if change_role_username and new_role:
        if new_role not in ("admin", "viewer"):
            flash("Неверная роль!", "error")
        elif change_role_username == session.get("username"):
            flash("Нельзя изменить собственную роль!", "error")
        else:
            role_user = user_model.query.filter_by(username=change_role_username).first()
            if role_user:
                old_role = role_user.role
                role_user.role = new_role
                db.session.commit()
                flash(f"Роль пользователя '{change_role_username}' изменена на '{new_role}'!", "success")
                log_user_action_event(
                    "settings_user_role_update",
                    target_type="user",
                    target_name=change_role_username,
                    details=f"{old_role} → {new_role}",
                )
            else:
                flash(f"Пользователь '{change_role_username}' не найден!", "error")

    change_password_username = form.get("change_password_username")
    new_password = form.get("new_password")
    if change_password_username and new_password:
        if len(new_password) < 8:
            flash("Пароль должен содержать минимум 8 символов!", "error")
        else:
            pw_user = user_model.query.filter_by(username=change_password_username).first()
            if pw_user:
                pw_user.set_password(new_password)
                db.session.commit()
                flash(f"Пароль пользователя '{change_password_username}' изменён!", "success")
                log_user_action_event(
                    "settings_user_password_update",
                    target_type="user",
                    target_name=change_password_username,
                    details="пароль изменён",
                )
            else:
                flash(f"Пользователь '{change_password_username}' не найден!", "error")

    return None
