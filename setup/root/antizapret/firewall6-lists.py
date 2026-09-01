#!/usr/bin/env python3
# Собирает IPv6-списки firewall и синхронизирует управляемые части OpenVPN CCD.
# Пользовательские строки вне маркерных блоков всегда сохраняются.
from __future__ import annotations

import argparse
import glob
import ipaddress
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("ANTIZAPRET_ROOT", "/root/antizapret"))
RESULT = ROOT / "result"
STATE = ROOT / "state"
DOWNLOAD_CACHE = STATE / "download-ips6.txt"
OPENVPN_DEFAULT = Path(
    os.environ.get("ANTIZAPRET_OPENVPN_DEFAULT", "/etc/openvpn/server/ccd/DEFAULT")
)
OPENVPN_CCD = OPENVPN_DEFAULT.parent
OPENVPN_CCD2 = Path(
    os.environ.get("ANTIZAPRET_OPENVPN_CCD2", "/etc/openvpn/server/ccd2")
)
OPENVPN_BEGIN = "# BEGIN ANTIZAPRET MANAGED IPV6 ROUTES"
OPENVPN_END = "# END ANTIZAPRET MANAGED IPV6 ROUTES"
OPENVPN_CLIENT_DEFAULT_BEGIN = "# BEGIN ANTIZAPRET MANAGED DEFAULT ROUTES"
OPENVPN_CLIENT_DEFAULT_END = "# END ANTIZAPRET MANAGED DEFAULT ROUTES"
OPENVPN_CLIENT_PREFIX_TAG = "# ANTIZAPRET ROUTED IPV6 PREFIX: "
OPENVPN_CLIENT_ROUTE_MODE_TAG = "# ANTIZAPRET ROUTE MODE: "
OPENVPN_CLIENT_PREFIX_BEGIN = "# BEGIN ANTIZAPRET MANAGED CLIENT IPV6"
OPENVPN_CLIENT_PREFIX_END = "# END ANTIZAPRET MANAGED CLIENT IPV6"
DEFAULT_IPV6_PREFIX = "fd3a:c9bc:6bcb::/48"
FAKE_IPV6_SUBNET = 0x29FF
FAKE_IPV6_PREFIX_LENGTH = 96
ALTERNATIVE_FAKE_IPV6_NETWORK = ipaddress.IPv6Network("2001:2::/48")
CLIENT_NAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")


def fake_ipv6_network(
    prefix: str, alternative: bool = False
) -> ipaddress.IPv6Network:
    if alternative:
        return ALTERNATIVE_FAKE_IPV6_NETWORK
    try:
        network = ipaddress.ip_network(prefix, strict=True)
    except ValueError as exc:
        raise RuntimeError(f"invalid VPN IPv6 prefix {prefix!r}: {exc}") from exc
    if not isinstance(network, ipaddress.IPv6Network) or network.prefixlen != 48:
        raise RuntimeError("VPN IPv6 prefix must be an IPv6 /48 network")
    if not network.subnet_of(ipaddress.IPv6Network("fc00::/7")):
        raise RuntimeError("VPN IPv6 prefix must be a private ULA /48 network")
    return ipaddress.IPv6Network(
        (
            int(network.network_address) | (FAKE_IPV6_SUBNET << 64),
            FAKE_IPV6_PREFIX_LENGTH,
        )
    )


def read_paths(paths: list[Path]) -> set[ipaddress.IPv6Network]:
    # Общие списки могут содержать оба семейства адресов; здесь выбирается
    # только IPv6, а повреждённые строки не останавливают штатное обновление.
    networks: set[ipaddress.IPv6Network] = set()
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for raw_line in lines:
            value = raw_line.split("#", 1)[0].strip()
            if not value:
                continue
            try:
                network = ipaddress.ip_network("".join(value.split()), strict=False)
            except ValueError:
                continue
            if isinstance(network, ipaddress.IPv6Network):
                networks.add(network)
    return networks


def matching_paths(patterns: list[str]) -> list[Path]:
    paths: list[Path] = []
    for pattern in patterns:
        paths.extend(Path(filename) for filename in glob.glob(str(ROOT / pattern)))
    return sorted({path for path in paths if path.is_file()})


def read_networks(patterns: list[str]) -> set[ipaddress.IPv6Network]:
    return read_paths(matching_paths(patterns))


def ordered(networks: set[ipaddress.IPv6Network]) -> list[ipaddress.IPv6Network]:
    return sorted(networks, key=lambda item: (int(item.network_address), item.prefixlen))


def write_file(destination: Path, networks: set[ipaddress.IPv6Network]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(
        "".join(f"{item.with_prefixlen}\n" for item in ordered(networks)),
        encoding="utf-8",
    )
    temporary.replace(destination)


def replace_text(destination: Path, content: str) -> None:
    # Символические ссылки не заменяем, чтобы управляемый путь не позволял
    # записать данные за пределы ожидаемого каталога.
    if destination.is_symlink():
        raise RuntimeError(f"refusing to replace symlink {destination}")
    mode = 0o644
    try:
        mode = destination.stat().st_mode & 0o777
        if destination.read_text(encoding="utf-8") == content:
            return
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RuntimeError(f"cannot inspect {destination}: {exc}") from exc
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, mode)
    temporary.replace(destination)


def write_result(filename: str, networks: set[ipaddress.IPv6Network]) -> None:
    write_file(RESULT / filename, networks)
    print(f"{len(networks)} - {filename}")


def write_openvpn_routes(
    destination: Path,
    networks: set[ipaddress.IPv6Network],
    *,
    enabled: bool = True,
    fake_network: ipaddress.IPv6Network | None = None,
) -> None:
    # Пересоздаётся только блок между маркерами. Ручные директивы администратора
    # до и после него остаются на своих местах.
    try:
        original = destination.read_text(encoding="utf-8")
    except FileNotFoundError:
        original = ""
    except OSError as exc:
        raise RuntimeError(f"cannot read {destination}: {exc}") from exc

    retained: list[str] = []
    managed = False
    for line in original.splitlines():
        if line == OPENVPN_BEGIN:
            managed = True
            continue
        if line == OPENVPN_END:
            managed = False
            continue
        if not managed:
            retained.append(line)
    if enabled:
        retained.extend([OPENVPN_BEGIN])
        retained.extend(
            f'push "route-ipv6 {item.with_prefixlen}"' for item in ordered(networks)
        )
        # RouterOS 7.19 retains only the final repeated route-ipv6 option.
        # Keeping the domain-mapping prefix last preserves domain lists there.
        if fake_network is not None and fake_network not in networks:
            retained.append(f'push "route-ipv6 {fake_network.with_prefixlen}"')
        retained.extend([OPENVPN_END])
    retained.append("")
    replace_text(destination, "\n".join(retained))


def validate_client_name(value: str) -> str:
    if not CLIENT_NAME_RE.fullmatch(value):
        raise RuntimeError(
            "OpenVPN client name must contain 1-32 ASCII letters, digits, "
            "underscores, or dashes"
        )
    return value


def parse_client_prefix(value: str) -> ipaddress.IPv6Network:
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise RuntimeError(f"invalid routed IPv6 prefix {value!r}: {exc}") from exc
    if not isinstance(network, ipaddress.IPv6Network):
        raise RuntimeError("routed client prefix must be IPv6")
    if not network.subnet_of(ipaddress.IPv6Network("2000::/3")):
        raise RuntimeError("routed client prefix must be global IPv6 unicast")
    if not 48 <= network.prefixlen <= 64:
        raise RuntimeError("routed client prefix length must be between /48 and /64")
    return network


def strip_managed_sections(text: str) -> list[str]:
    # Удаляем собственные секции перед повторной сборкой и считаем незакрытый
    # маркер ошибкой, а не молча отбрасываем остаток пользовательского файла.
    sections = {
        OPENVPN_CLIENT_DEFAULT_BEGIN: OPENVPN_CLIENT_DEFAULT_END,
        OPENVPN_CLIENT_PREFIX_BEGIN: OPENVPN_CLIENT_PREFIX_END,
    }
    retained: list[str] = []
    expected_end: str | None = None
    for line in text.splitlines():
        if expected_end is not None:
            if line == expected_end:
                expected_end = None
            continue
        if line in sections:
            expected_end = sections[line]
            continue
        if line.startswith(OPENVPN_CLIENT_PREFIX_TAG):
            continue
        if line.startswith(OPENVPN_CLIENT_ROUTE_MODE_TAG):
            continue
        retained.append(line)
    if expected_end is not None:
        raise RuntimeError(f"unterminated managed OpenVPN block ending with {expected_end}")
    while retained and not retained[-1]:
        retained.pop()
    return retained


def prefix_from_text(text: str, source: Path) -> ipaddress.IPv6Network | None:
    values = [
        line.removeprefix(OPENVPN_CLIENT_PREFIX_TAG).strip()
        for line in text.splitlines()
        if line.startswith(OPENVPN_CLIENT_PREFIX_TAG)
    ]
    if not values:
        return None
    if len(values) != 1:
        raise RuntimeError(f"multiple routed IPv6 prefixes in {source}")
    return parse_client_prefix(values[0])


def client_path(directory: Path, name: str) -> Path:
    return directory / validate_client_name(name)


def read_client_prefix(name: str) -> ipaddress.IPv6Network | None:
    prefixes: set[ipaddress.IPv6Network] = set()
    for directory in (OPENVPN_CCD, OPENVPN_CCD2):
        path = client_path(directory, name)
        try:
            value = prefix_from_text(path.read_text(encoding="utf-8"), path)
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise RuntimeError(f"cannot read {path}: {exc}") from exc
        if value is not None:
            prefixes.add(value)
    if len(prefixes) > 1:
        raise RuntimeError(f"inconsistent routed IPv6 prefixes for client {name!r}")
    return next(iter(prefixes), None)


def route_mode_from_text(text: str, source: Path) -> str:
    values = [
        line.removeprefix(OPENVPN_CLIENT_ROUTE_MODE_TAG).strip()
        for line in text.splitlines()
        if line.startswith(OPENVPN_CLIENT_ROUTE_MODE_TAG)
    ]
    if not values:
        return "static"
    if len(values) != 1 or values[0] != "bgp":
        raise RuntimeError(f"invalid AntiZapret route mode in {source}")
    return values[0]


def read_client_route_mode(name: str) -> str:
    path = client_path(OPENVPN_CCD, name)
    try:
        return route_mode_from_text(path.read_text(encoding="utf-8"), path)
    except FileNotFoundError:
        return "static"
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc


def managed_client_names() -> set[str]:
    names: set[str] = set()
    for directory in (OPENVPN_CCD, OPENVPN_CCD2):
        try:
            paths = list(directory.iterdir())
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise RuntimeError(f"cannot list {directory}: {exc}") from exc
        for path in paths:
            if not path.is_file() or path.name == "DEFAULT":
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except OSError as exc:
                raise RuntimeError(f"cannot read {path}: {exc}") from exc
            if (
                OPENVPN_CLIENT_PREFIX_TAG in text
                or OPENVPN_CLIENT_ROUTE_MODE_TAG in text
            ):
                names.add(validate_client_name(path.name))
    return names


def validate_unique_client_prefix(
    name: str, prefix: ipaddress.IPv6Network
) -> None:
    # Пересекающиеся routed-префиксы сделали бы выбор OpenVPN iroute неоднозначным.
    for other_name in managed_client_names():
        if other_name == name:
            continue
        other_prefix = read_client_prefix(other_name)
        if other_prefix is not None and prefix.overlaps(other_prefix):
            raise RuntimeError(
                f"routed IPv6 prefix {prefix} overlaps {other_prefix} "
                f"owned by OpenVPN client {other_name!r}"
            )


def read_openvpn_default() -> str:
    try:
        return OPENVPN_DEFAULT.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"cannot read {OPENVPN_DEFAULT}: {exc}") from exc


def render_client_config(
    path: Path,
    prefix: ipaddress.IPv6Network | None,
    *,
    default_routes: str | None,
    ipv6_enabled: bool,
    route_mode: str,
) -> str:
    # ccd и ccd2 имеют разные обязанности: первый получает маршруты по умолчанию,
    # второй — только адресный префикс клиента. Общая функция сохраняет их формат.
    try:
        original = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        original = ""
    except OSError as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc
    retained = strip_managed_sections(original)
    unmanaged_iroutes = [
        line for line in retained if line.strip().startswith("iroute-ipv6 ")
    ]
    if unmanaged_iroutes and prefix is not None:
        raise RuntimeError(
            f"{path} contains an unmanaged iroute-ipv6; remove it before "
            "assigning a managed routed prefix"
        )
    if default_routes is not None:
        if route_mode == "bgp":
            retained.append(f"{OPENVPN_CLIENT_ROUTE_MODE_TAG}bgp")
        elif prefix is not None or retained:
            retained.append(OPENVPN_CLIENT_DEFAULT_BEGIN)
            retained.extend(default_routes.rstrip("\n").splitlines())
            retained.append(OPENVPN_CLIENT_DEFAULT_END)
    if prefix is not None:
        retained.append(f"{OPENVPN_CLIENT_PREFIX_TAG}{prefix.with_prefixlen}")
        if ipv6_enabled:
            retained.extend(
                [
                    OPENVPN_CLIENT_PREFIX_BEGIN,
                    f"iroute-ipv6 {prefix.with_prefixlen}",
                    OPENVPN_CLIENT_PREFIX_END,
                ]
            )
    if not retained:
        return ""
    retained.append("")
    return "\n".join(retained)


def write_client_config(
    name: str,
    prefix: ipaddress.IPv6Network | None,
    *,
    ipv6_enabled: bool,
    route_mode: str,
) -> None:
    if route_mode not in {"static", "bgp"}:
        raise RuntimeError(f"unsupported OpenVPN route mode {route_mode!r}")
    default_routes = read_openvpn_default()
    destinations = (
        (client_path(OPENVPN_CCD, name), default_routes),
        (client_path(OPENVPN_CCD2, name), None),
    )
    rendered = [
        (
            path,
            render_client_config(
                path,
                prefix,
                default_routes=routes,
                ipv6_enabled=ipv6_enabled,
                route_mode=route_mode,
            ),
        )
        for path, routes in destinations
    ]
    for path, content in rendered:
        if content:
            replace_text(path, content)
        else:
            path.unlink(missing_ok=True)


def set_client_prefix(name: str, value: str) -> None:
    name = validate_client_name(name)
    prefix = parse_client_prefix(value)
    validate_unique_client_prefix(name, prefix)
    route_mode = read_client_route_mode(name)
    if os.environ.get("BGP_ENABLE", "n") != "y":
        route_mode = "static"
    write_client_config(
        name,
        prefix,
        ipv6_enabled=os.environ.get("DISABLE_IPV6", "n") != "y",
        route_mode=route_mode,
    )


def clear_client_prefix(name: str, *, delete: bool = False) -> None:
    name = validate_client_name(name)
    if not delete:
        route_mode = read_client_route_mode(name)
        if os.environ.get("BGP_ENABLE", "n") != "y":
            route_mode = "static"
        write_client_config(
            name,
            None,
            ipv6_enabled=os.environ.get("DISABLE_IPV6", "n") != "y",
            route_mode=route_mode,
        )
        return
    for directory in (OPENVPN_CCD, OPENVPN_CCD2):
        path = client_path(directory, name)
        try:
            original = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise RuntimeError(f"cannot read {path}: {exc}") from exc
        path.unlink()


def set_client_route_mode(name: str, mode: str) -> None:
    name = validate_client_name(name)
    if mode not in {"static", "bgp"}:
        raise RuntimeError("OpenVPN route mode must be static or bgp")
    if mode == "bgp" and os.environ.get("BGP_ENABLE", "n") != "y":
        raise RuntimeError("BGP is disabled in the AntiZapret setup")
    write_client_config(
        name,
        read_client_prefix(name),
        ipv6_enabled=os.environ.get("DISABLE_IPV6", "n") != "y",
        route_mode=mode,
    )


def sync_client_configs(*, ipv6_enabled: bool, bgp_enabled: bool = False) -> None:
    # Сначала проверяем весь набор префиксов и только затем начинаем запись,
    # чтобы конфликт одного клиента не оставил остальные файлы наполовину обновлёнными.
    names = managed_client_names()
    prefixes: dict[str, ipaddress.IPv6Network | None] = {}
    for name in names:
        prefix = read_client_prefix(name)
        if prefix is not None:
            validate_unique_client_prefix(name, prefix)
        prefixes[name] = prefix
    for name in sorted(prefixes):
        route_mode = read_client_route_mode(name) if bgp_enabled else "static"
        write_client_config(
            name,
            prefixes[name],
            ipv6_enabled=ipv6_enabled,
            route_mode=route_mode,
        )


def downloaded_networks(refresh_download: bool) -> set[ipaddress.IPv6Network]:
    # Кэш нужен для локальных запусков без нового download; при наличии свежих
    # файлов он всегда пересобирается из фактически загруженного набора.
    download_paths = matching_paths(["download/*ips.txt", "download/*ips6.txt"])
    if refresh_download or download_paths:
        networks = read_paths(download_paths)
        write_file(DOWNLOAD_CACHE, networks)
        return networks
    return read_paths([DOWNLOAD_CACHE])


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--refresh-download", action="store_true")
    actions.add_argument("--disable-openvpn", action="store_true")
    actions.add_argument(
        "--get-client-prefix",
        metavar="CLIENT",
        help="print the routed IPv6 prefix assigned to an OpenVPN client",
    )
    actions.add_argument(
        "--set-client-prefix",
        nargs=2,
        metavar=("CLIENT", "PREFIX"),
        help="assign a routed global IPv6 prefix to an OpenVPN router client",
    )
    actions.add_argument(
        "--clear-client-prefix",
        metavar="CLIENT",
        help="turn an OpenVPN router profile back into an endpoint profile",
    )
    actions.add_argument(
        "--delete-client-config",
        metavar="CLIENT",
        help="delete CCD files for a revoked OpenVPN client",
    )
    actions.add_argument(
        "--get-client-route-mode",
        metavar="CLIENT",
        help="print static or bgp for an OpenVPN client",
    )
    actions.add_argument(
        "--set-client-route-mode",
        nargs=2,
        metavar=("CLIENT", "MODE"),
        help="select static or bgp route delivery for an OpenVPN client",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.get_client_prefix:
        prefix = read_client_prefix(args.get_client_prefix)
        if prefix is not None:
            print(prefix.with_prefixlen)
        return 0
    if args.get_client_route_mode:
        print(read_client_route_mode(args.get_client_route_mode))
        return 0
    if args.set_client_route_mode:
        set_client_route_mode(*args.set_client_route_mode)
        return 0
    if args.set_client_prefix:
        set_client_prefix(*args.set_client_prefix)
        return 0
    if args.clear_client_prefix:
        clear_client_prefix(args.clear_client_prefix)
        return 0
    if args.delete_client_config:
        clear_client_prefix(args.delete_client_config, delete=True)
        return 0
    ipv6_enabled = os.environ.get("DISABLE_IPV6", "n") != "y"
    bgp_enabled = os.environ.get("BGP_ENABLE", "n") == "y"
    if args.disable_openvpn or not ipv6_enabled:
        write_openvpn_routes(OPENVPN_DEFAULT, set(), enabled=False)
        sync_client_configs(ipv6_enabled=False, bgp_enabled=bgp_enabled)
        return 0

    refresh_download = args.refresh_download
    # Маршрутный список строится как загруженные и явно добавленные сети за
    # вычетом исключений. Остальные списки используются отдельными цепочками.
    route = downloaded_networks(refresh_download) | read_networks(["config/*include-ips.txt"])
    route.difference_update(read_networks(["config/*exclude-ips.txt"]))
    fake_network = fake_ipv6_network(
        os.environ.get("VPN_IPV6_PREFIX") or DEFAULT_IPV6_PREFIX,
        os.environ.get("ALTERNATIVE_FAKE_IPV6", "y") == "y",
    )

    write_result("route-ips6.txt", route)
    write_openvpn_routes(OPENVPN_DEFAULT, route, fake_network=fake_network)
    sync_client_configs(ipv6_enabled=True, bgp_enabled=bgp_enabled)
    write_result("allow-ips6.txt", read_networks(["config/*allow-ips.txt"]))
    write_result("deny-ips6.txt", read_networks(["config/*deny-ips.txt"]))
    write_result("drop-ips6.txt", read_networks(["config/*drop-ips.txt"]))
    write_result("forward-ips6.txt", route | read_networks(["config/*forward-ips.txt"]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except RuntimeError as exc:
        print(f"{Path(sys.argv[0]).name}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
