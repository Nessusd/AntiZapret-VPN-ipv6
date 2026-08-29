import os

INCLUDE_IPS_FILE = "/root/antizapret/config/include-ips.txt"

_IPV4_HEADER_BODY = """#
# Формат записи: A.B.C.D/M
# Где:
#   A.B.C.D - IPv4-адрес
#   M       - размер маски подсети (1-32)
#
# Примеры записи:
#   5.255.255.242/32  - добавление одного IPv4-адреса
#   66.22.192.0/18    - добавление подсети с маской 18 (16382 IPv4-адреса)
#   104.24.0.0/14     - добавление подсети с маской 14 (262142 IPv4-адреса)
#   34.3.3.0/24       - добавление подсети с маской 24 (254 IPv4-адреса)
#
# Строки начинающиеся с # это комментарии и они не обрабатываются
#
"""

_DUAL_STACK_HEADER_BODY = """#
# Формат записи:
#   A.B.C.D/M       - IPv4-сеть, M от 1 до 32
#   XXXX:...:XXXX/M - IPv6-сеть, M от 1 до 128
#
# Примеры записи:
#   5.255.255.242/32      - один IPv4-адрес
#   66.22.192.0/18        - IPv4-подсеть
#   2001:db8::1/128       - один IPv6-адрес
#   2001:db8:1234::/48    - IPv6-подсеть
#
# Строки, начинающиеся с #, являются комментариями и не обрабатываются
#
"""

default_header = (
    "# Добавление IP-адресов для маршрутизации через AntiZapret VPN\n"
    + _DUAL_STACK_HEADER_BODY
)

_LEGACY_HEADERS = (
    (
        "# Добавление IPv4-адресов для маршрутизации через AntiZapret VPN\n"
        + _IPV4_HEADER_BODY
    ),
    (
        "# Добавление IP-адресов для маршрутизации через AntiZapret VPN\n"
        + _IPV4_HEADER_BODY
    ),
    (
        "# Добавление IPv4- и IPv6-адресов для маршрутизации через "
        "AntiZapret VPN\n"
        + _DUAL_STACK_HEADER_BODY
    ),
)


def _header_lines(header):
    return header.rstrip().split("\n")


def _matched_header_length(lines):
    for header in (default_header, *_LEGACY_HEADERS):
        header_lines = _header_lines(header)
        if lines[: len(header_lines)] == header_lines:
            return len(header_lines)
    return None


def load_header():
    return default_header


def get_existing_comments(path):
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r") as f:
            lines = [line.rstrip() for line in f]
    except FileNotFoundError:
        return []

    header_length = _matched_header_length(lines)
    if header_length is None:
        return []

    comments = []
    for line in lines[header_length:]:
        if line.startswith("#"):
            comments.append(line[1:].strip())
        elif line.strip() == "":
            continue
        else:
            break
    return comments


def write_include_ips_file(path, ips, comments=None):
    if comments is None:
        comments = []
    elif isinstance(comments, str):
        comments = [comments]
    header = load_header()
    existing_comments = get_existing_comments(path)
    all_comments = existing_comments + comments
    # Keep only the last 5 comments
    all_comments = all_comments[-5:]
    with open(path, "w") as f:
        f.write(header)
        for c in all_comments:
            f.write(f"# {c}\n")
        for ip in sorted(ips):
            f.write(f"{ip}\n")
