from config.antizapret_params import ANTIZAPRET_PARAMS
from utils.shell_config import read_shell_assignments

ANTIZAPRET_SETUP_FILE = "/root/antizapret/setup"


def _read_setup_assignments(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return read_shell_assignments(f.read())
    except OSError:
        return {}


def read_antizapret_settings(path=ANTIZAPRET_SETUP_FILE):
    """Читает antizapret setup и возвращает dict {key: value}."""
    assignments = _read_setup_assignments(path)
    settings = {}
    for p in ANTIZAPRET_PARAMS:
        key, env, typ, default = p["key"], p["env"], p["type"], p["default"]
        value = assignments.get(env)
        if typ == "string":
            settings[key] = value if value is not None else default
        else:
            settings[key] = value.lower() if value is not None and value.lower() in {"y", "n"} else default
    return settings


def is_antizapret_ipv6_enabled(settings=None):
    """Возвращает положительное состояние IPv6 из конфигурации AntiZapret."""
    current_settings = (
        settings if settings is not None else read_antizapret_settings()
    )
    return str(current_settings.get("disable_ipv6", "n")).strip().lower() != "y"


def is_antizapret_bgp_enabled(path=ANTIZAPRET_SETUP_FILE):
    """Общий BGP-флаг принадлежит AntiZapret, а не окружению панели."""
    value = _read_setup_assignments(path).get("BGP_ENABLE")
    return isinstance(value, str) and value.strip().lower() == "y"
