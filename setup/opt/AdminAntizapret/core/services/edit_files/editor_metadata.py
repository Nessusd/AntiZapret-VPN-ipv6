GROUP_ORDER = {
    "Домены": 10,
    "IP и маршрутизация": 20,
    "Рекламные фильтры": 30,
    "Безопасность": 40,
    "Прочее": 90,
}

_DEFAULT_SUBTITLE = (
    "Формат: по одному домену или IP в строке. Комментарии допускаются через #."
)

_IP_LIST_PURPOSES = {
    "include_ips": "Добавляет адреса и сети в маршрутизацию через AntiZapret VPN.",
    "exclude-ips": "Исключает адреса и сети из маршрутизации через AntiZapret VPN.",
    "forward-ips": "Добавляет адреса и сети, разрешённые для форвардинга через AntiZapret VPN.",
    "drop-ips": "Запрещает форвардинг адресов и сетей через AntiZapret VPN и полный VPN.",
    "allow-ips": "Исключает адреса и сети из проверки защиты от сканирования и сетевых атак.",
    "deny-ips": "Блокирует входящие подключения к серверу от указанных адресов и сетей.",
}

_IP_LIST_PATHS = {
    "include_ips": "config/include-ips.txt",
    "exclude-ips": "config/exclude-ips.txt",
    "forward-ips": "config/forward-ips.txt",
    "drop-ips": "config/drop-ips.txt",
    "allow-ips": "config/allow-ips.txt",
    "deny-ips": "config/deny-ips.txt",
}

_IP_LIST_TITLES = {
    "include_ips": "Добавление IP-адресов для маршрутизации через AntiZapret VPN",
    "exclude-ips": "Исключение IP-адресов из маршрутизации через AntiZapret VPN",
    "forward-ips": (
        "Добавление IP-адресов, неявно разрешённых для маршрутизации через "
        "AntiZapret VPN"
    ),
    "drop-ips": (
        "Добавление IP-адресов, запрещённых для форвардинга через AntiZapret VPN "
        "и полный VPN"
    ),
    "allow-ips": (
        "Исключение IP-адресов из проверки защиты от сканирования и сетевых атак"
    ),
    "deny-ips": (
        "Добавление IP-адресов, заблокированных для входящих подключений к серверу"
    ),
}


def _get_ip_list_subtitle(file_type: str) -> str:
    return (
        f"{_IP_LIST_PURPOSES[file_type]} Формат: по одной IPv4- или IPv6-сети в "
        "CIDR на строку (например, 149.154.160.0/20 или 2001:db8::/48); одиночный "
        "адрес указывается с /32 для IPv4 или /128 для IPv6. "
        f"Файл {_IP_LIST_PATHS[file_type]} общий для IPv4 и IPv6; отдельный IPv6-файл "
        "не требуется. Комментарии допускаются через #."
    )


def get_editor_subtitle(file_type: str) -> str:
    if file_type in _IP_LIST_PURPOSES:
        return _get_ip_list_subtitle(file_type)
    return _DEFAULT_SUBTITLE


def get_editor_title(file_type: str, fallback: str) -> str:
    return _IP_LIST_TITLES.get(file_type, fallback)
