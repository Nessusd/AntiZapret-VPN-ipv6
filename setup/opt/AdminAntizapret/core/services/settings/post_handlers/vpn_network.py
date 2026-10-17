# Меняет только собственные сетевые параметры панели, не дублируя конфигурацию AntiZapret.
import os
import platform

from core.services.feature_toggles import app_module_disabled_message, is_app_module_enabled
from utils.panel_port import queue_panel_port_change


def handle_vpn_network_port(form, *, flash, get_env_value, set_env_value, log_user_action_event):
    new_port_raw = (form.get("port") or "").strip()
    if not new_port_raw:
        return None

    if not is_app_module_enabled("vpn_network", get_env_value=get_env_value):
        flash(app_module_disabled_message("vpn_network"), "error")
        return None

    if new_port_raw.isascii() and new_port_raw.isdigit() and 1 <= int(new_port_raw) <= 65535:
        old_port = (get_env_value("APP_PORT", os.getenv("APP_PORT", "5050")) or "5050").strip()
        try:
            if int(old_port) == int(new_port_raw):
                flash("Порт не изменился", "info")
                return None
            if platform.system() != "Linux":
                raise RuntimeError("Смена порта доступна в установленной systemd-службе")
            unit = queue_panel_port_change(old_port, new_port_raw)
        except (OSError, RuntimeError, ValueError) as error:
            flash(f"Не удалось поставить смену порта в очередь: {error}", "error")
            return None
        flash("Смена порта поставлена в очередь. При ошибке настройки будут восстановлены. "
              f"Результат: journalctl -u {unit}", "success")
        log_user_action_event(
            "settings_port_update",
            target_type="app",
            target_name="APP_PORT",
            details=f"{old_port} → {new_port_raw}; unit={unit}",
        )
    else:
        flash("Порт должен быть целым числом в диапазоне 1..65535", "error")
    return None
