# Проверяет литеральный адрес сервера до записи в исполняемый shell setup.
import ipaddress
import re

_HOST_LABEL = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9])?")
_IPV6_SCOPE = re.compile(r"[A-Za-z0-9_.-]+")


def normalize_endpoint_host(value):
    if not isinstance(value, str):
        raise ValueError("Адрес сервера должен быть строкой")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Адрес сервера содержит управляющие символы")
    host = value.strip()
    if not host:
        return ""
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
        try:
            ipaddress.IPv6Address(host)
        except ValueError as exc:
            raise ValueError("В скобках должен быть IPv6-адрес") from exc
    if "%" in host and not _IPV6_SCOPE.fullmatch(host.split("%", 1)[1]):
        raise ValueError("Некорректная зона IPv6-адреса")
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        pass

    try:
        domain = host[:-1] if host.endswith(".") else host
        ascii_host = domain.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ValueError("Некорректное доменное имя сервера") from exc
    if len(ascii_host) > 253 or any(not _HOST_LABEL.fullmatch(label) for label in ascii_host.split(".")):
        raise ValueError("Укажите доменное имя, IPv4- или IPv6-адрес без порта")
    return ascii_host + ("." if host.endswith(".") else "")
