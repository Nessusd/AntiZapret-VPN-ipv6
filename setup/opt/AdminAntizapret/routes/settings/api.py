"""Регистрация действующих API страницы настроек."""

from routes.settings.api_misc import register_settings_misc_api_routes


def register_settings_api_routes(
    app,
    *,
    auth_manager,
    user_model,
    user_action_log_model,
    set_env_value,
    get_env_value,
    log_user_action_event,
):
    register_settings_misc_api_routes(
        app,
        auth_manager=auth_manager,
        user_model=user_model,
        user_action_log_model=user_action_log_model,
        set_env_value=set_env_value,
        get_env_value=get_env_value,
        log_user_action_event=log_user_action_event,
    )
