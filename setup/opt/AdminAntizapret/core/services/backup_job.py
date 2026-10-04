"""Создаёт локальные резервные копии панели и, при необходимости, AntiZapret."""
import logging
import os

from core.services.antizapret_backup import AntizapretBackupService
from core.services.backup_manager import BackupManagerService

logger = logging.getLogger(__name__)


def load_env_map(env_path):
    env_map = {}
    if not os.path.isfile(env_path):
        return env_map
    with open(env_path, "r", encoding="utf-8") as source:
        for raw_line in source:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env_map[key.strip()] = value.strip().strip("'").strip('"')
    return env_map


def env_value(env_map, key, default=""):
    value = os.getenv(key)
    if value is not None and value != "":
        return value
    return env_map.get(key, default)


def to_bool(value, default=False):
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def az_install_dir(env_map):
    return (
        env_value(env_map, "APP_BACKUP_AZ_INSTALL_DIR", "").strip()
        or env_value(env_map, "ANTIZAPRET_INSTALL_DIR", "").strip()
        or "/root/antizapret"
    )


def create_az_backup(env_map):
    return AntizapretBackupService(install_dir=az_install_dir(env_map)).create_backup()


def run_backup_job(app_root, *, trigger="auto", require_auto_enabled=True):
    """Сохраняет архивы на сервере и возвращает результат для фоновой задачи."""
    app_root = os.path.abspath(app_root)
    env_map = load_env_map(os.path.join(app_root, ".env"))

    if require_auto_enabled and not to_bool(env_value(env_map, "APP_BACKUP_ENABLED", "false")):
        return {"skipped": True, "reason": "auto_backup_disabled"}

    backup_root = env_value(env_map, "APP_BACKUP_ROOT", "/var/backups/antizapret")
    service_name = env_value(env_map, "APP_BACKUP_SERVICE_NAME", "admin-antizapret")
    components_csv = env_value(env_map, "APP_BACKUP_COMPONENTS", "db,env,data")
    components = [item.strip().lower() for item in components_csv.split(",") if item.strip()]

    backup_service = BackupManagerService(
        app_root=app_root,
        backup_root=backup_root,
        service_name=service_name,
        retention_count=5,
    )
    panel_result = backup_service.create_backup(
        selected_components=components,
        trigger=trigger,
    )

    az_result = None
    az_error = ""
    if to_bool(env_value(env_map, "APP_BACKUP_AZ_ENABLED", "true")):
        try:
            az_result = create_az_backup(env_map)
        except Exception as exc:
            az_error = str(exc)
            logger.warning("AntiZapret backup (client.sh 8) failed: %s", exc)

    summary_parts = [f"панель: {panel_result.get('archive_name', '')}"]
    if az_result:
        summary_parts.append(f"AZ: {az_result.get('archive_name', '')}")
    elif az_error:
        summary_parts.append(f"AZ: ошибка ({az_error})")

    return {
        "panel": panel_result,
        "az": az_result,
        "az_error": az_error,
        "summary": "; ".join(summary_parts),
    }
