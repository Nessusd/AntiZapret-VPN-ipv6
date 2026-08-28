"""Restrict the panel TCP port to IPv4 and IPv6 whitelist entries."""
from __future__ import annotations

import ipaddress
import logging
import os
import shlex
import subprocess
from dataclasses import dataclass
from typing import Iterable

logger = logging.getLogger(__name__)

CHAIN_V4 = "AA_PANEL_WHITELIST"
CHAIN_V6 = "AA_PANEL_WHITELIST6"
IPSET_ALLOW_V4 = "aa_panel_allow_v4"
IPSET_ALLOW_V6 = "aa_panel_allow_v6"
COMMENT_JUMP_V4 = "aa-panel-port-jump-v4"
COMMENT_JUMP_V6 = "aa-panel-port-jump-v6"


@dataclass(frozen=True)
class FirewallFamily:
    version: int
    table_command: str
    chain: str
    ipset: str
    ipset_family: str
    jump_comment: str


FAMILIES = {
    4: FirewallFamily(4, "iptables", CHAIN_V4, IPSET_ALLOW_V4, "inet", COMMENT_JUMP_V4),
    6: FirewallFamily(6, "ip6tables", CHAIN_V6, IPSET_ALLOW_V6, "inet6", COMMENT_JUMP_V6),
}


def _env_bool(name: str, default: bool = False) -> bool:
    raw = (os.getenv(name, "") or "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "y", "on"}


def _panel_port() -> int:
    raw = (os.getenv("APP_PORT", "5050") or "").strip()
    try:
        return max(1, min(65535, int(raw)))
    except ValueError:
        return 5050


class PanelPortFirewall:
    def __init__(
        self,
        *,
        firewall_enabled: bool | None = None,
        dry_run: bool | None = None,
    ) -> None:
        self.firewall_enabled = (
            firewall_enabled
            if firewall_enabled is not None
            else _env_bool("IP_SCANNER_FIREWALL_ENABLED", True)
        )
        self.dry_run = dry_run if dry_run is not None else _env_bool("IP_SCANNER_FIREWALL_DRY_RUN", False)
        self._active_port: int | None = None

    @staticmethod
    def _run_command(args: list[str]) -> tuple[bool, str]:
        try:
            result = subprocess.run(
                args,
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            if result.returncode == 0:
                return True, result.stdout or ""
            stderr = (result.stderr or result.stdout or "").strip()
            return False, stderr
        except (OSError, subprocess.SubprocessError) as exc:
            return False, str(exc)

    @staticmethod
    def _ipset_entry(entry: str) -> tuple[int, str] | None:
        value = (entry or "").strip()
        if not value:
            return None
        try:
            if "/" in value:
                network = ipaddress.ip_network(value, strict=False)
                return network.version, str(network)
            address = ipaddress.ip_address(value)
            prefix_length = 32 if address.version == 4 else 128
            return address.version, f"{address}/{prefix_length}"
        except ValueError:
            return None

    def _entries_by_family(self, allowed_ips: Iterable[str]) -> dict[int, list[str]]:
        result: dict[int, list[str]] = {4: [], 6: []}
        for raw in allowed_ips:
            normalized = self._ipset_entry(raw)
            if normalized:
                version, entry = normalized
                result[version].append(entry)
        return result

    @staticmethod
    def _active_versions() -> set[int]:
        versions: set[int] = set()
        bind_ipv4 = (os.getenv("BIND", "0.0.0.0") or "0.0.0.0").strip()
        bind_ipv6 = (os.getenv("BIND_IPV6", "") or "").strip()
        if bind_ipv4 not in {"127.0.0.1", "localhost"}:
            versions.add(4)
        if bind_ipv6 and bind_ipv6 not in {"::1", "localhost"}:
            versions.add(6)
        return versions

    def _ensure_ipset(self, family: FirewallFamily) -> bool:
        ok, error = self._run_command(
            [
                "ipset", "create", family.ipset, "hash:net", "family", family.ipset_family,
                "hashsize", "4096", "maxelem", "65536", "-exist",
            ]
        )
        if not ok:
            logger.warning("ipset create %s failed: %s", family.ipset, error)
        return ok

    def _flush_ipset(self, family: FirewallFamily) -> None:
        self._run_command(["ipset", "flush", family.ipset])

    def _populate_ipset(self, family: FirewallFamily, entries: list[str]) -> None:
        self._flush_ipset(family)
        for entry in entries:
            ok, error = self._run_command(["ipset", "add", family.ipset, entry, "-exist"])
            if not ok:
                logger.warning("ipset add %s -> %s failed: %s", family.ipset, entry, error)

    def _ensure_chain(self, family: FirewallFamily) -> None:
        command = family.table_command
        self._run_command([command, "-N", family.chain])
        self._run_command([command, "-F", family.chain])
        self._run_command(
            [
                command, "-A", family.chain,
                "-m", "set", "--match-set", family.ipset, "src",
                "-j", "RETURN",
            ]
        )
        self._run_command([command, "-A", family.chain, "-j", "DROP"])

    def _remove_jump_rules(self, family: FirewallFamily) -> None:
        ok, output = self._run_command([family.table_command, "-S", "INPUT"])
        if not ok:
            return
        for line in output.splitlines():
            if family.jump_comment not in line or not line.startswith("-A INPUT"):
                continue
            try:
                rule = shlex.split(line)
            except ValueError:
                logger.warning("Cannot parse firewall rule while removing %s: %s", family.jump_comment, line)
                continue
            self._run_command([family.table_command, "-D", *rule[1:]])

    def _ensure_jump(self, family: FirewallFamily, *, port: int) -> None:
        check = [
            family.table_command, "-C", "INPUT",
            "-p", "tcp", "--dport", str(port),
            "-m", "comment", "--comment", family.jump_comment,
            "-j", family.chain,
        ]
        exists, _ = self._run_command(check)
        if exists:
            return
        self._remove_jump_rules(family)
        self._run_command(
            [
                family.table_command, "-I", "INPUT",
                "-p", "tcp", "--dport", str(port),
                "-m", "comment", "--comment", family.jump_comment,
                "-j", family.chain,
            ]
        )

    def _disable_family(self, family: FirewallFamily) -> None:
        self._remove_jump_rules(family)
        self._flush_ipset(family)

    def disable(self, *, port: int | None = None) -> bool:
        port = port or self._active_port or _panel_port()
        if self.dry_run:
            logger.info("panel port firewall dry-run disable port=%s", port)
            self._active_port = None
            return True
        if not self.firewall_enabled:
            return True

        for family in FAMILIES.values():
            self._disable_family(family)
        self._active_port = None
        return True

    def sync(self, allowed_ips: Iterable[str], *, port: int | None = None) -> bool:
        port = port or _panel_port()
        entries = self._entries_by_family(allowed_ips)
        active_versions = self._active_versions()

        if self.dry_run:
            logger.info(
                "panel port firewall dry-run sync port=%s v4=%s v6=%s",
                port,
                len(entries[4]),
                len(entries[6]),
            )
            self._active_port = port
            return True

        if not self.firewall_enabled:
            return False

        configured = False
        for version, family in FAMILIES.items():
            family_entries = entries[version]
            if version not in active_versions:
                self._disable_family(family)
                continue
            if not self._ensure_ipset(family):
                return False
            self._populate_ipset(family, family_entries)
            self._ensure_chain(family)
            self._ensure_jump(family, port=port)
            configured = True

        if not configured:
            self._active_port = None
            return True

        self._active_port = port
        return True
