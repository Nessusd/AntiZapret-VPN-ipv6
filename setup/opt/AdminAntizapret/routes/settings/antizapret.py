# Отдаёт параметры AntiZapret из его setup и меняет их через штатный механизм применения.
import shlex

from flask import current_app, jsonify, request

from config.antizapret_params import ANTIZAPRET_PARAMS
from core.services.antizapret_settings import ANTIZAPRET_SETUP_FILE, read_antizapret_settings

from utils.endpoint_host import normalize_endpoint_host
from utils.file_io import atomic_write_text, file_lock
from utils.shell_config import parse_shell_assignment

FILE_PATH = ANTIZAPRET_SETUP_FILE


def normalize_flag(v):
    if isinstance(v, (bool, int)):
        return "y" if v else "n"
    s = str(v).lower().strip()
    return "y" if s in ("y", "yes", "true", "1", "on") else "n"


def register_settings_antizapret_routes(app, *, auth_manager):
    @app.route("/get_antizapret_settings")
    @auth_manager.admin_required
    def get_antizapret_settings():
        try:
            return jsonify(read_antizapret_settings())

        except Exception as e:
            current_app.logger.error(f"Ошибка чтения настроек antizapret: {e}", exc_info=True)
            return jsonify({"error": "Ошибка чтения настроек"}), 500

    @app.route("/update_antizapret_settings", methods=["POST"])
    @auth_manager.admin_required
    def update_antizapret_settings():
        try:
            new_settings = request.get_json(silent=True) or {}
            if not isinstance(new_settings, dict):
                return jsonify({"success": False, "message": "Ожидается JSON-объект"}), 400

            desired = {}
            for p in ANTIZAPRET_PARAMS:
                if p.get("managed_by_installer"):
                    continue
                if (k := p["key"]) in new_settings:
                    v = new_settings[k]
                    env = p["env"]
                    if p["type"] == "flag":
                        desired[env] = normalize_flag(v)
                    else:
                        try:
                            desired[env] = normalize_endpoint_host(v)
                        except ValueError as exc:
                            return jsonify({"success": False, "message": str(exc)}), 400

            if not desired:
                return jsonify({"success": True, "message": "Нечего обновлять", "changes": 0})

            with file_lock(FILE_PATH) as path:
                with path.open("r", encoding="utf-8") as source:
                    lines = source.readlines()

                new_lines = []
                found = set()
                changes = 0
                for line in lines:
                    assignment = parse_shell_assignment(line)
                    if assignment is None or assignment.key not in desired:
                        new_lines.append(line)
                        continue
                    value = desired[assignment.key]
                    comment = " " + assignment.comment if assignment.comment else ""
                    new_lines.append(
                        f"{assignment.prefix}{assignment.key}={shlex.quote(value)}{comment}\n"
                    )
                    found.add(assignment.key)
                    changes += 1

                for env, value in desired.items():
                    if env not in found:
                        if new_lines and not new_lines[-1].endswith("\n"):
                            new_lines[-1] += "\n"
                        new_lines.append(f"{env}={shlex.quote(value)}\n")
                        changes += 1

                if changes > 0:
                    atomic_write_text(path, "".join(new_lines))

            if changes > 0:
                user_action_logger = current_app.config.get("USER_ACTION_AUDIT_LOGGER")
                if callable(user_action_logger):
                    changed_keys = sorted(desired.keys())
                    sample = ",".join(changed_keys[:8])
                    if len(changed_keys) > 8:
                        sample += ",..."
                    details_text = f"changes={changes} keys={sample}"
                    user_action_logger(
                        "settings_antizapret_update",
                        target_type="antizapret",
                        target_name="setup",
                        details=details_text,
                    )

            return jsonify({
                "success": True,
                "message": "Настройки сохранены",
                "changes": changes,
                "needs_apply": True
            })

        except PermissionError:
            return jsonify({"success": False, "message": "Нет прав на запись"}), 403
        except Exception as e:
            current_app.logger.error(f"Ошибка обновления antizapret: {e}", exc_info=True)
            return jsonify({"success": False, "message": "Ошибка сервера"}), 500

    @app.route("/antizapret_settings_schema")
    @auth_manager.admin_required
    def antizapret_settings_schema():
        return jsonify([
            {
                "key": p["key"],
                "html_id": p["html_id"],
                "type": p["type"],
                "env": p.get("env", ""),
                "param_label": p.get("param_label", p.get("env", "")),
                "title": p.get("title", ""),
                "description": p.get("description", ""),
                "managed_by_installer": bool(p.get("managed_by_installer", False)),
            }
            for p in ANTIZAPRET_PARAMS
        ])
