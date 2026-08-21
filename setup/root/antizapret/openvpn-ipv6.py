#!/usr/bin/env python3
"""Reconcile OpenVPN server configs with the managed IPv6 configuration."""

from __future__ import annotations

import argparse
import ipaddress
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple, Sequence


DEFAULT_PREFIX = "fd3a:c9bc:6bcb::/48"


class Mode(NamedTuple):
    subnet_id: int
    ipv4_proto: str
    neutral_proto: str
    ipv6_proto: str
    full_vpn: bool

    @property
    def managed_protos(self) -> frozenset[str]:
        return frozenset((self.ipv4_proto, self.neutral_proto, self.ipv6_proto))


MODES = {
    "antizapret-udp": Mode(0x2900, "udp4", "udp", "udp6", False),
    "antizapret-tcp": Mode(0x2904, "tcp4", "tcp-server", "tcp6-server", False),
    "vpn-udp": Mode(0x2800, "udp4", "udp", "udp6", True),
    "vpn-tcp": Mode(0x2804, "tcp4", "tcp-server", "tcp6-server", True),
}

# OpenVPN accepts both spellings in server mode.  The repository historically
# used ``tcp4``, while some existing installations may contain the explicit
# ``tcp4-server`` form.
TCP_SERVER_COMPAT_PROTOS = frozenset(("tcp4-server",))


class ReconcileError(RuntimeError):
    """A config cannot be changed without risking compatibility."""


def directive_tokens(line: str) -> tuple[str, ...]:
    """Return active OpenVPN directive tokens without an inline comment."""
    content = line
    for marker in ("#", ";"):
        content = content.split(marker, 1)[0]
    return tuple(content.split())


def parse_prefix(value: str) -> ipaddress.IPv6Network:
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise ReconcileError(f"invalid OpenVPN IPv6 prefix {value!r}: {exc}") from exc
    if not isinstance(network, ipaddress.IPv6Network) or network.prefixlen != 48:
        raise ReconcileError("OpenVPN IPv6 prefix must be an IPv6 /48 network")
    if not network.subnet_of(ipaddress.IPv6Network("fc00::/7")):
        raise ReconcileError("OpenVPN IPv6 prefix must be a ULA /48 network")
    return network


def mode_network(prefix: str, name: str) -> ipaddress.IPv6Network:
    base = parse_prefix(prefix)
    try:
        mode = MODES[name]
    except KeyError as exc:
        raise ReconcileError(f"unsupported OpenVPN mode: {name}") from exc
    return ipaddress.IPv6Network(
        (int(base.network_address) | (mode.subnet_id << 64), 64)
    )


def reconcile_text(
    text: str, prefix: str, name: str, *, enable: bool
) -> tuple[str, int]:
    mode = MODES[name]
    network = mode_network(prefix, name)
    managed_server = f"server-ipv6 {network}"
    managed_redirect = 'push "redirect-gateway ipv6"'
    lines = text.splitlines(keepends=True)
    changes = 0

    parsed_lines = [directive_tokens(line) for line in lines]
    proto_lines = [
        index for index, tokens in enumerate(parsed_lines) if tokens[:1] == ("proto",)
    ]
    server_lines = [
        index for index, tokens in enumerate(parsed_lines) if tokens[:1] == ("server",)
    ]
    if len(proto_lines) != 1 or len(server_lines) != 1:
        raise ReconcileError(f"{name}: expected exactly one proto and one IPv4 server")

    proto_index = proto_lines[0]
    newline = "\r\n" if lines[proto_index].endswith("\r\n") else "\n"
    proto_tokens = parsed_lines[proto_index]
    if len(proto_tokens) != 2:
        raise ReconcileError(f"{name}: malformed proto directive")
    current_proto = proto_tokens[1].lower()
    managed_protos = mode.managed_protos
    if mode.neutral_proto == "tcp-server":
        managed_protos = managed_protos | TCP_SERVER_COMPAT_PROTOS
    if current_proto not in managed_protos:
        raise ReconcileError(f"{name}: unmanaged proto value {current_proto!r}")

    target_proto = mode.ipv6_proto if enable else mode.ipv4_proto
    if current_proto != target_proto:
        lines[proto_index] = f"proto {target_proto}{newline}"
        changes += 1

    if any(directive_tokens(line)[:2] == ("bind", "ipv6only") for line in lines):
        raise ReconcileError(
            f"{name}: bind ipv6only would reject existing IPv4 clients"
        )

    if enable and any(tokens[:1] == ("local",) for tokens in parsed_lines):
        raise ReconcileError(
            f"{name}: local bind is incompatible with the managed dual-stack listener; "
            "remove the local directive"
        )

    managed_server_indexes = [
        index for index, line in enumerate(lines) if line.strip() == managed_server
    ]
    other_server_ipv6 = [
        line.strip()
        for line in lines
        if line.lstrip().startswith("server-ipv6 ") and line.strip() != managed_server
    ]
    if len(managed_server_indexes) > 1:
        raise ReconcileError(f"{name}: duplicate managed server-ipv6 directives")
    if other_server_ipv6:
        raise ReconcileError(f"{name}: unmanaged server-ipv6 is already configured")
    if enable:
        if not managed_server_indexes:
            insert_at = server_lines[0] + 1
            server_newline = "\r\n" if lines[server_lines[0]].endswith("\r\n") else "\n"
            lines.insert(insert_at, f"{managed_server}{server_newline}")
            changes += 1
    elif managed_server_indexes:
        lines = [line for line in lines if line.strip() != managed_server]
        changes += len(managed_server_indexes)

    if mode.full_vpn:
        redirect_indexes = [
            index for index, line in enumerate(lines) if line.strip() == managed_redirect
        ]
        if len(redirect_indexes) > 1:
            raise ReconcileError(f"{name}: duplicate IPv6 redirect-gateway pushes")
        if enable and not redirect_indexes:
            ipv4_redirect = next(
                (
                    index
                    for index, line in enumerate(lines)
                    if line.strip().startswith('push "redirect-gateway def1')
                ),
                None,
            )
            if ipv4_redirect is None:
                raise ReconcileError(f"{name}: IPv4 redirect-gateway push is missing")
            redirect_newline = (
                "\r\n" if lines[ipv4_redirect].endswith("\r\n") else "\n"
            )
            lines.insert(ipv4_redirect + 1, f"{managed_redirect}{redirect_newline}")
            changes += 1
        elif not enable and redirect_indexes:
            lines = [line for line in lines if line.strip() != managed_redirect]
            changes += len(redirect_indexes)

    return "".join(lines), changes


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
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def reconcile_file(
    path: Path, prefix: str, name: str, *, enable: bool, write: bool
) -> int:
    try:
        original = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ReconcileError(f"cannot read {path}: {exc}") from exc
    reconciled, changes = reconcile_text(original, prefix, name, enable=enable)
    if write and reconciled != original:
        try:
            atomic_write(path, reconciled)
        except OSError as exc:
            raise ReconcileError(f"cannot update {path}: {exc}") from exc
    return changes


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", default=DEFAULT_PREFIX)
    parser.add_argument("action", choices=("migrate", "strip"))
    parser.add_argument("mode", choices=sorted(MODES))
    parser.add_argument("path", type=Path)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args(argv)


def run(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    changes = reconcile_file(
        args.path,
        args.prefix,
        args.mode,
        enable=args.action == "migrate",
        write=not args.check,
    )
    print("updated" if changes else "unchanged")
    return 0


def main() -> None:
    try:
        raise SystemExit(run(sys.argv[1:]))
    except ReconcileError as exc:
        print(f"openvpn-ipv6.py: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
