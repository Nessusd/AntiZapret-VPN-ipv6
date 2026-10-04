# Общая нормализация IP-адресов и времени для настроек панели.
import ipaddress


def normalize_ip_entry(raw_value):
    value = (raw_value or "").strip()
    if not value:
        return None
    try:
        if "/" in value:
            return str(ipaddress.ip_network(value, strict=False))
        return str(ipaddress.ip_address(value))
    except ValueError:
        return None


def nightly_time_from_cron(cron_expr):
    value = (cron_expr or "").strip()
    parts = value.split()
    if len(parts) == 5 and parts[0].isdigit() and parts[1].isdigit():
        minute_value = int(parts[0])
        hour_value = int(parts[1])
        if 0 <= minute_value <= 59 and 0 <= hour_value <= 23:
            return f"{hour_value:02d}:{minute_value:02d}"
    return "04:00"
