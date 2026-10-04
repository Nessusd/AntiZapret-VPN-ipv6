"""Регистрация действующих API страницы настроек."""

from routes.settings.api_misc import register_settings_misc_api_routes


def register_settings_api_routes(
    app,
    *,
    auth_manager,
    user_action_log_model,
):
    register_settings_misc_api_routes(
        app,
        auth_manager=auth_manager,
        user_action_log_model=user_action_log_model,
    )
