#!/usr/bin/env python3
"""Build and publish the private BIRD configuration used by AntiZapret."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Mapping, Sequence


PROGRAM = "antizapret-bgp"
DEFAULT_VPN_PREFIX = "fd3a:c9bc:6bcb::/48"
DEFAULT_SERVER_ASN = 4_200_000_290
DEFAULT_CLIENT_ASN = 4_200_000_291
MAX_PREFIXES = 500_000
ASSIGNMENT_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")
SAFE_VALUE_RE = re.compile(r"^[A-Za-z0-9_.:/-]*$")


class BGPError(RuntimeError):
    pass


def environment_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default))


ROOT = environment_path("ANTIZAPRET_ROOT", "/root/antizapret")
SETUP_PATH = environment_path("ANTIZAPRET_SETUP", str(ROOT / "setup"))
CONFIG_DIR = environment_path("ANTIZAPRET_BGP_CONFIG_DIR", "/etc/antizapret-bgp")
CONFIG_PATH = environment_path(
    "ANTIZAPRET_BGP_CONFIG", str(CONFIG_DIR / "bird.conf")
)
STATE_DIR = environment_path("ANTIZAPRET_BGP_STATE_DIR", "/var/lib/antizapret-bgp")
SOCKET_PATH = environment_path(
    "ANTIZAPRET_BGP_SOCKET", "/run/antizapret-bgp/bird.ctl"
)
BIRD = os.environ.get("ANTIZAPRET_BIRD", "/usr/sbin/bird")
BIRDC = os.environ.get("ANTIZAPRET_BIRDC", "/usr/sbin/birdc")


# setup — shell-файл, поэтому разбираем только простые безопасные присваивания,
# не выполняя его содержимое с правами процесса обновления.
def read_setup(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise BGPError(f"cannot read {path}: {exc}") from exc
    result: dict[str, str] = {}
    for line in lines:
        match = ASSIGNMENT_RE.fullmatch(line.strip())
        if not match:
            continue
        name, value = match.groups()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if not SAFE_VALUE_RE.fullmatch(value):
            continue
        result[name] = value
    return result


def yes_no(config: Mapping[str, str], name: str, default: str = "n") -> bool:
    value = config.get(name, default)
    if value not in {"y", "n"}:
        raise BGPError(f"{name} must be y or n")
    return value == "y"


def private_asn(config: Mapping[str, str], name: str, default: int) -> int:
    raw = config.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise BGPError(f"{name} must be an integer") from exc
    if not (64_512 <= value <= 65_534 or 4_200_000_000 <= value <= 4_294_967_294):
        raise BGPError(f"{name} must be a private 16-bit or 32-bit ASN")
    return value


def vpn_prefix(config: Mapping[str, str]) -> ipaddress.IPv6Network:
    raw = config.get("VPN_IPV6_PREFIX", DEFAULT_VPN_PREFIX) or DEFAULT_VPN_PREFIX
    try:
        value = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        raise BGPError(f"invalid VPN_IPV6_PREFIX {raw!r}: {exc}") from exc
    if not isinstance(value, ipaddress.IPv6Network) or value.prefixlen != 48:
        raise BGPError("VPN_IPV6_PREFIX must be an IPv6 /48 network")
    if not value.subnet_of(ipaddress.IPv6Network("fc00::/7")):
        raise BGPError("VPN_IPV6_PREFIX must be a private ULA /48 network")
    return value


def ipv6_subnet(prefix: ipaddress.IPv6Network, subnet: int) -> ipaddress.IPv6Network:
    return ipaddress.IPv6Network((int(prefix.network_address) | (subnet << 64), 64))


def fake_ipv6_network(
    prefix: ipaddress.IPv6Network, alternative: bool = False
) -> ipaddress.IPv6Network:
    if alternative:
        return ipaddress.IPv6Network("2001:2::/48")
    return ipaddress.IPv6Network(
        (int(prefix.network_address) | (0x29FF << 64), 96)
    )


def read_networks(path: Path, version: int) -> set[ipaddress._BaseNetwork]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return set()
    except OSError as exc:
        raise BGPError(f"cannot read {path}: {exc}") from exc
    result: set[ipaddress._BaseNetwork] = set()
    for number, raw in enumerate(lines, 1):
        value = raw.split("#", 1)[0].strip()
        if not value:
            continue
        try:
            network = ipaddress.ip_network(value, strict=False)
        except ValueError as exc:
            raise BGPError(f"invalid prefix in {path}:{number}: {value!r}") from exc
        if network.version != version:
            raise BGPError(f"wrong address family in {path}:{number}: {value!r}")
        result.add(network)
        if len(result) > MAX_PREFIXES:
            raise BGPError(f"too many prefixes in {path}; limit is {MAX_PREFIXES}")
    return result


def ordered(networks: set[ipaddress._BaseNetwork]) -> list[ipaddress._BaseNetwork]:
    collapsed = ipaddress.collapse_addresses(networks)
    return sorted(collapsed, key=lambda item: (int(item.network_address), item.prefixlen))


def route_include(networks: set[ipaddress._BaseNetwork]) -> str:
    return "".join(f"    route {network.with_prefixlen} blackhole;\n" for network in ordered(networks))


# Каждый включённый VPN-транспорт получает отдельную пассивную BGP-сессию.
# IPv6-канал добавляется только при включённом IPv6 во всей установке.
def protocol_config(
    name: str,
    interface: str,
    local4: ipaddress.IPv4Address,
    range4: ipaddress.IPv4Network,
    local6: ipaddress.IPv6Address | None,
    server_asn: int,
    client_asn: int,
) -> str:
    ipv6_channel = ""
    if local6 is not None:
        ipv6_channel = f"""
    ipv6 {{
        table antizapret6;
        import none;
        export filter antizapret_export6;
        next hop address {local6};
        export limit {MAX_PREFIXES} action block;
    }};
"""
    return f"""
protocol bgp {name} {{
    local {local4} as {server_asn};
    neighbor range {range4.with_prefixlen} as {client_asn};
    interface \"{interface}\";
    strict bind on;
    passive on;
    direct;
    dynamic name \"{name}_\";

    ipv4 {{
        table antizapret4;
        import none;
        export filter antizapret_export4;
        next hop address {local4};
        export limit {MAX_PREFIXES} action block;
    }};
{ipv6_channel}}}
"""


def render_config(
    config: Mapping[str, str],
    routes4_path: Path,
    routes6_path: Path,
) -> tuple[str, int, int]:
    server_asn = private_asn(config, "BGP_SERVER_ASN", DEFAULT_SERVER_ASN)
    client_asn = private_asn(config, "BGP_CLIENT_ASN", DEFAULT_CLIENT_ASN)
    if server_asn == client_asn:
        raise BGPError("BGP_SERVER_ASN and BGP_CLIENT_ASN must differ")
    prefix = vpn_prefix(config)
    ipv6_enabled = not yes_no(config, "DISABLE_IPV6")
    base = 172 if yes_no(config, "ALTERNATIVE_CLIENT_IP") else 10
    protocols: list[str] = []
    definitions = (
        ("antizapret_udp", "antizapret-udp", 0, 22, "OPENVPN_UDP_ENABLE", 0x2900),
        ("antizapret_tcp", "antizapret-tcp", 4, 22, "OPENVPN_TCP_ENABLE", 0x2904),
        ("antizapret_wg", "antizapret", 8, 24, "WIREGUARD_ENABLE", 0x2908),
    )
    for name, interface, third, mask, enabled_name, subnet6 in definitions:
        if not yes_no(config, enabled_name):
            continue
        local4 = ipaddress.IPv4Address(f"{base}.29.{third}.1")
        range4 = ipaddress.IPv4Network(f"{base}.29.{third}.0/{mask}")
        local6 = (
            ipaddress.IPv6Address(int(ipv6_subnet(prefix, subnet6).network_address) + 1)
            if ipv6_enabled
            else None
        )
        protocols.append(
            protocol_config(
                name, interface, local4, range4, local6, server_asn, client_asn
            )
        )
    if not protocols:
        raise BGPError("BGP requires at least one enabled VPN protocol")

    route6_protocol = ""
    filter6 = ""
    if ipv6_enabled:
        route6_protocol = f"""
protocol static antizapret_routes6 {{
    ipv6 {{ table antizapret6; }};
include \"{routes6_path}\";
}}
"""
        filter6 = f"""
filter antizapret_export6 {{
    if source = RTS_STATIC then {{
        bgp_large_community.add(({server_asn}, 29, 6));
        accept;
    }}
    reject;
}}
"""
    text = f"""# Generated by {PROGRAM}; do not edit.
log syslog name \"antizapret-bgp\" all;
router id {base}.29.0.1;

ipv4 table antizapret4;
ipv6 table antizapret6;

protocol device {{
    scan time 10;
}}

filter antizapret_export4 {{
    if source = RTS_STATIC then {{
        bgp_large_community.add(({server_asn}, 29, 4));
        accept;
    }}
    reject;
}}
{filter6}
protocol static antizapret_routes4 {{
    ipv4 {{ table antizapret4; }};
include \"{routes4_path}\";
}}
{route6_protocol}
{"".join(protocols)}"""
    return text, server_asn, client_asn


def atomic_write(path: Path, content: str, mode: int = 0o644) -> None:
    # BIRD не должен увидеть частично записанную конфигурацию или список маршрутов.
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def run(command: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(command),
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except FileNotFoundError as exc:
        raise BGPError(f"command not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stdout or "").strip()
        raise BGPError(f"command failed ({' '.join(command)}): {detail}") from exc


def validate_config(path: Path) -> None:
    run((BIRD, "-p", "-c", str(path)))


def replace_symlink(link: Path, target: str) -> None:
    temporary = link.with_name(f".{link.name}.{os.getpid()}.tmp")
    try:
        temporary.symlink_to(target)
        os.replace(temporary, link)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def socket_is_live() -> bool:
    if not SOCKET_PATH.exists():
        return False
    result = run((BIRDC, "-s", str(SOCKET_PATH), "show", "status"), check=False)
    return result.returncode == 0


def reload_bird() -> None:
    run((BIRDC, "-s", str(SOCKET_PATH), "configure"))


def remove_generation(path: Path) -> None:
    if path.is_dir() and path.parent == STATE_DIR / "generations":
        shutil.rmtree(path)


def publish(config: Mapping[str, str], *, prepare_only: bool) -> str:
    # Блокировка объединяет проверку и публикацию в одну транзакцию: параллельный
    # update не сможет заменить current между валидацией и reload BIRD.
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o755)
    generations = STATE_DIR / "generations"
    generations.mkdir(mode=0o755, exist_ok=True)
    lock_path = STATE_DIR / "update.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        route4_path = ROOT / "result/route-ips.txt"
        route6_path = ROOT / "result/route-ips6.txt"
        if not route4_path.is_file():
            raise BGPError(f"required route list is missing: {route4_path}")
        ipv6_enabled = not yes_no(config, "DISABLE_IPV6")
        if ipv6_enabled and not route6_path.is_file():
            raise BGPError(f"required route list is missing: {route6_path}")
        network4 = read_networks(route4_path, 4)
        network6 = read_networks(route6_path, 6) if ipv6_enabled else set()
        base = 172 if yes_no(config, "ALTERNATIVE_CLIENT_IP") else 10
        fake4 = (
            ipaddress.IPv4Network("198.18.0.0/15")
            if yes_no(config, "ALTERNATIVE_FAKE_IP", "y")
            else ipaddress.IPv4Network(f"{base}.30.0.0/15")
        )
        network4.add(fake4)
        if ipv6_enabled:
            network6.add(
                fake_ipv6_network(
                    vpn_prefix(config),
                    yes_no(config, "ALTERNATIVE_FAKE_IPV6", "y"),
                )
            )
        if len(ordered(network4)) > MAX_PREFIXES or len(ordered(network6)) > MAX_PREFIXES:
            raise BGPError(f"too many advertised prefixes; limit is {MAX_PREFIXES}")

        generation = Path(tempfile.mkdtemp(prefix="gen-", dir=generations))
        os.chmod(generation, 0o755)
        routes4 = generation / "routes4.conf"
        routes6 = generation / "routes6.conf"
        candidate = generation / "candidate.conf"
        try:
            atomic_write(routes4, route_include(network4))
            atomic_write(routes6, route_include(network6))
            candidate_text, server_asn, client_asn = render_config(
                config, routes4, routes6
            )
            atomic_write(candidate, candidate_text)
            validate_config(candidate)

            # Хеш строится с постоянными путями current, чтобы имя временного
            # каталога поколения не превращало неизменную конфигурацию в новую.
            stable_text, _, _ = render_config(
                config, STATE_DIR / "current/routes4.conf", STATE_DIR / "current/routes6.conf"
            )
            digest = hashlib.sha256(
                (stable_text + route_include(network4) + route_include(network6)).encode()
            ).hexdigest()
            manifest = {
                "sha256": digest,
                "ipv4_prefixes": len(ordered(network4)),
                "ipv6_prefixes": len(ordered(network6)),
                "server_asn": server_asn,
                "client_asn": client_asn,
                "created_at": int(time.time()),
            }
            atomic_write(generation / "manifest.json", json.dumps(manifest, indent=2) + "\n")

            current = STATE_DIR / "current"
            old_target = os.readlink(current) if current.is_symlink() else None
            old_config = CONFIG_PATH.read_bytes() if CONFIG_PATH.is_file() else None
            old_manifest: dict[str, object] = {}
            if current.is_symlink():
                try:
                    old_manifest = json.loads(
                        (current / "manifest.json").read_text(encoding="utf-8")
                    )
                except (OSError, json.JSONDecodeError):
                    old_manifest = {}
            unchanged = False
            if old_manifest.get("sha256") == digest and CONFIG_PATH.is_file():
                try:
                    unchanged = (
                        CONFIG_PATH.read_text(encoding="utf-8") == stable_text
                        and (current / "routes4.conf").read_text(encoding="utf-8")
                        == route_include(network4)
                        and (current / "routes6.conf").read_text(encoding="utf-8")
                        == route_include(network6)
                    )
                except OSError:
                    unchanged = False
            if unchanged:
                remove_generation(generation)
                return "unchanged"

            # Сначала переключаем атомарную ссылку и основной конфиг, затем
            # проверяем уже опубликованное состояние. При ошибке возвращаем оба.
            target = str(generation.relative_to(STATE_DIR))
            replace_symlink(current, target)
            atomic_write(CONFIG_PATH, stable_text)
            try:
                validate_config(CONFIG_PATH)
                if not prepare_only and socket_is_live():
                    reload_bird()
            except BGPError:
                if old_target is not None:
                    replace_symlink(current, old_target)
                else:
                    current.unlink(missing_ok=True)
                if old_config is not None:
                    atomic_write(CONFIG_PATH, old_config.decode("utf-8"))
                else:
                    CONFIG_PATH.unlink(missing_ok=True)
                if not prepare_only and old_target is not None and socket_is_live():
                    try:
                        reload_bird()
                    except BGPError:
                        pass
                raise

            keep = {generation.resolve()}
            if old_target is not None:
                keep.add((STATE_DIR / old_target).resolve())
            for path in generations.iterdir():
                if path.resolve() not in keep:
                    remove_generation(path)
            return "updated"
        except Exception:
            if not (STATE_DIR / "current").is_symlink() or (STATE_DIR / "current").resolve() != generation.resolve():
                remove_generation(generation)
            raise


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="publish a validated config without reloading a running BIRD instance",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    config = read_setup(SETUP_PATH)
    if not yes_no(config, "BGP_ENABLE"):
        return 0
    result = publish(config, prepare_only=args.prepare_only)
    print(f"BGP routes: {result}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except BGPError as exc:
        print(f"{Path(sys.argv[0]).name}: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
