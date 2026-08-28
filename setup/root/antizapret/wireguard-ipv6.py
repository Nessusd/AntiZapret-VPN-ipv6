#!/usr/bin/env python3
"""Add deterministic IPv6 addresses to existing WireGuard configurations."""

from __future__ import annotations

import argparse
import ipaddress
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Sequence


DEFAULT_PREFIX = "fd3a:c9bc:6bcb::/48"
MODE_SUBNETS = {"antizapret": 0x2908, "vpn": 0x2808}
FAKE_SUBNET = 0x29FF
FAKE_PREFIX_LENGTH = 96
BENCHMARK_FAKE_IPV6_NETWORK = ipaddress.IPv6Network("2001:2::/48")
ASSIGNMENT_RE = re.compile(
    r"^(?P<prefix>\s*)(?P<name>Address|AllowedIPs)"
    r"(?P<separator>\s*=\s*)(?P<value>.*?)(?P<newline>\r?\n)?$"
)


class MigrationError(RuntimeError):
    """A configuration cannot be migrated without risking existing access."""


def parse_base_prefix(value: str) -> ipaddress.IPv6Network:
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise MigrationError(f"invalid WireGuard IPv6 prefix {value!r}: {exc}") from exc
    if not isinstance(network, ipaddress.IPv6Network) or network.prefixlen != 48:
        raise MigrationError("WireGuard IPv6 prefix must be an IPv6 /48 network")
    if not network.subnet_of(ipaddress.IPv6Network("fc00::/7")):
        raise MigrationError("WireGuard IPv6 prefix must be a private ULA /48 network")
    return network


def mode_network(prefix: str, mode: str) -> ipaddress.IPv6Network:
    base = parse_base_prefix(prefix)
    try:
        subnet_id = MODE_SUBNETS[mode]
    except KeyError as exc:
        raise MigrationError(f"unsupported WireGuard mode: {mode}") from exc
    return ipaddress.IPv6Network((int(base.network_address) | (subnet_id << 64), 64))


def fake_network(prefix: str, alternative: bool = False) -> ipaddress.IPv6Network:
    if alternative:
        return BENCHMARK_FAKE_IPV6_NETWORK
    base = parse_base_prefix(prefix)
    return ipaddress.IPv6Network(
        (int(base.network_address) | (FAKE_SUBNET << 64), FAKE_PREFIX_LENGTH)
    )


def server_address(prefix: str, mode: str) -> ipaddress.IPv6Interface:
    network = mode_network(prefix, mode)
    return ipaddress.IPv6Interface((int(network.network_address) + 1, network.prefixlen))


def client_address(prefix: str, mode: str, ipv4: str) -> ipaddress.IPv6Interface:
    try:
        address = ipaddress.IPv4Address(ipv4)
    except ipaddress.AddressValueError as exc:
        raise MigrationError(f"invalid client IPv4 address {ipv4!r}") from exc
    host = int(str(address).rsplit(".", 1)[1])
    if not 2 <= host <= 254:
        raise MigrationError("client IPv4 last octet must be between 2 and 254")
    network = mode_network(prefix, mode)
    return ipaddress.IPv6Interface((int(network.network_address) + host, 128))


def split_addresses(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def parse_interface(
    value: str, where: str
) -> ipaddress.IPv4Interface | ipaddress.IPv6Interface:
    try:
        return ipaddress.ip_interface(value)
    except ValueError as exc:
        raise MigrationError(f"{where}: invalid address {value!r}") from exc


def append_address(line: str, address: str) -> str:
    match = ASSIGNMENT_RE.match(line)
    if match is None:
        raise AssertionError("assignment line expected")
    return (
        f"{match.group('prefix')}{match.group('name')}{match.group('separator')}"
        f"{match.group('value')}, {address}{match.group('newline') or ''}"
    )


def replace_addresses(line: str, addresses: Sequence[str]) -> str:
    match = ASSIGNMENT_RE.match(line)
    if match is None:
        raise AssertionError("assignment line expected")
    return (
        f"{match.group('prefix')}{match.group('name')}{match.group('separator')}"
        f"{', '.join(addresses)}{match.group('newline') or ''}"
    )


def migrate_text(text: str, prefix: str, mode: str) -> tuple[str, int]:
    expected_server = server_address(prefix, mode)
    lines = text.splitlines(keepends=True)
    section: str | None = None
    interface_address_line: int | None = None
    peer_allowed_line: int | None = None
    peer_number = 0
    changed = 0

    def migrate_peer(line_number: int | None, number: int) -> None:
        nonlocal changed
        if line_number is None:
            raise MigrationError(f"peer {number}: missing AllowedIPs")
        match = ASSIGNMENT_RE.match(lines[line_number])
        assert match is not None
        values = split_addresses(match.group("value"))
        parsed = [
            parse_interface(value, f"peer {number} AllowedIPs") for value in values
        ]
        ipv4_hosts = [
            item
            for item in parsed
            if isinstance(item, ipaddress.IPv4Interface)
            and item.network.prefixlen == 32
        ]
        ipv6_hosts = [
            item for item in parsed if isinstance(item, ipaddress.IPv6Interface)
        ]
        if not ipv4_hosts:
            raise MigrationError(f"peer {number}: no IPv4 /32 in AllowedIPs")
        expected = client_address(prefix, mode, str(ipv4_hosts[0].ip))
        if expected in ipv6_hosts:
            return
        if ipv6_hosts:
            raise MigrationError(
                f"peer {number}: existing IPv6 AllowedIPs do not contain {expected}"
            )
        lines[line_number] = append_address(lines[line_number], str(expected))
        changed += 1

    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if section == "peer":
                migrate_peer(peer_allowed_line, peer_number)
            section = stripped[1:-1].strip().lower()
            if section == "peer":
                peer_number += 1
                peer_allowed_line = None
            continue

        match = ASSIGNMENT_RE.match(line)
        if match is None:
            continue
        name = match.group("name").lower()
        if section == "interface" and name == "address":
            if interface_address_line is not None:
                raise MigrationError("interface has more than one Address assignment")
            interface_address_line = index
        elif section == "peer" and name == "allowedips":
            if peer_allowed_line is not None:
                raise MigrationError(
                    f"peer {peer_number}: more than one AllowedIPs assignment"
                )
            peer_allowed_line = index

    if section == "peer":
        migrate_peer(peer_allowed_line, peer_number)
    if interface_address_line is None:
        raise MigrationError("interface is missing Address")

    match = ASSIGNMENT_RE.match(lines[interface_address_line])
    assert match is not None
    interface_values = split_addresses(match.group("value"))
    parsed_interface = [
        parse_interface(value, "interface Address") for value in interface_values
    ]
    ipv6_interface = [
        item for item in parsed_interface if isinstance(item, ipaddress.IPv6Interface)
    ]
    if expected_server not in ipv6_interface:
        if ipv6_interface:
            raise MigrationError(
                f"interface existing IPv6 Address does not contain {expected_server}"
            )
        lines[interface_address_line] = append_address(
            lines[interface_address_line], str(expected_server)
        )
        changed += 1

    return "".join(lines), changed


def strip_text(text: str, prefix: str, mode: str) -> tuple[str, int]:
    expected_server = server_address(prefix, mode)
    lines = text.splitlines(keepends=True)
    section: str | None = None
    changed = 0

    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1].strip().lower()
            continue

        match = ASSIGNMENT_RE.match(line)
        if match is None:
            continue
        name = match.group("name").lower()
        values = split_addresses(match.group("value"))
        parsed = [
            parse_interface(
                value, f"{section or 'unknown'} {match.group('name')}"
            )
            for value in values
        ]
        remove: ipaddress.IPv6Interface | None = None
        if section == "interface" and name == "address":
            remove = expected_server
        elif section == "peer" and name == "allowedips":
            ipv4_hosts = [
                item
                for item in parsed
                if isinstance(item, ipaddress.IPv4Interface)
                and item.network.prefixlen == 32
            ]
            if not ipv4_hosts:
                raise MigrationError("peer has no IPv4 /32 in AllowedIPs")
            remove = client_address(prefix, mode, str(ipv4_hosts[0].ip))
        if remove is None or remove not in parsed:
            continue
        retained = [
            value for value, parsed_value in zip(values, parsed) if parsed_value != remove
        ]
        if not retained:
            raise MigrationError(f"refusing to empty {match.group('name')}")
        lines[index] = replace_addresses(line, retained)
        changed += 1

    return "".join(lines), changed


def atomic_write(path: Path, content: str) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary: Path | None = Path(temporary_name)
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        temporary = None
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def reconcile_file(
    path: Path,
    prefix: str,
    mode: str,
    *,
    enable: bool,
    write: bool = True,
) -> int:
    try:
        original = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise MigrationError(f"cannot read {path}: {exc}") from exc
    reconciled, changes = (
        migrate_text(original, prefix, mode)
        if enable
        else strip_text(original, prefix, mode)
    )
    if write and reconciled != original:
        try:
            atomic_write(path, reconciled)
        except OSError as exc:
            raise MigrationError(f"cannot update {path}: {exc}") from exc
    return changes


def migrate_file(path: Path, prefix: str, mode: str, *, write: bool = True) -> int:
    return reconcile_file(path, prefix, mode, enable=True, write=write)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", default=DEFAULT_PREFIX)
    parser.add_argument("--alternative-fake-ipv6", action="store_true")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("network", "server-address"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("mode", choices=sorted(MODE_SUBNETS))
    subparsers.add_parser("fake-network")
    client_parser = subparsers.add_parser("client-address")
    client_parser.add_argument("mode", choices=sorted(MODE_SUBNETS))
    client_parser.add_argument("ipv4")
    for command in ("migrate", "strip"):
        reconcile_parser = subparsers.add_parser(command)
        reconcile_parser.add_argument("mode", choices=sorted(MODE_SUBNETS))
        reconcile_parser.add_argument("path", type=Path)
        reconcile_parser.add_argument(
            "--check", action="store_true", help="validate without changing the file"
        )
    return parser.parse_args(argv)


def run(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.command == "network":
        print(mode_network(args.prefix, args.mode))
    elif args.command == "fake-network":
        print(fake_network(args.prefix, args.alternative_fake_ipv6))
    elif args.command == "server-address":
        print(server_address(args.prefix, args.mode))
    elif args.command == "client-address":
        print(client_address(args.prefix, args.mode, args.ipv4))
    elif args.command in {"migrate", "strip"}:
        changes = reconcile_file(
            args.path,
            args.prefix,
            args.mode,
            enable=args.command == "migrate",
            write=not args.check,
        )
        print("updated" if changes else "unchanged")
    return 0


def main() -> None:
    try:
        raise SystemExit(run(sys.argv[1:]))
    except MigrationError as exc:
        print(f"wireguard-ipv6.py: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
