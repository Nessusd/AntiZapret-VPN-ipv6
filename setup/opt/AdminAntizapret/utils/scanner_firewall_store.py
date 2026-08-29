"""Персистентные блокировки сканеров на базе JSON, ipset и iptables."""

from __future__ import annotations

import fcntl
import ipaddress
import json
import logging
import os
import subprocess
import tempfile
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

DEFAULT_DATA_VERSION = 2
DEFAULT_STRIKES_FOR_YEAR = 5
DEFAULT_YEAR_BAN_SECONDS = 365 * 24 * 3600
DEFAULT_UNBAN_GRACE_SECONDS = 1800

LEGACY_IPSET_V4 = "aa_scanner_v4"
LEGACY_IPSET_V6 = "aa_scanner_v6"
IPSET_V4 = "aa_scanner_v4_v2"
IPSET_V6 = "aa_scanner_v6_v2"

_FIREWALL_FAMILIES = {
    4: {
        "ipset": IPSET_V4,
        "sync_ipset": "aa_scanner_v4_v2_next",
        "legacy_ipset": LEGACY_IPSET_V4,
        "family": "inet",
        "firewall": "iptables",
    },
    6: {
        "ipset": IPSET_V6,
        "sync_ipset": "aa_scanner_v6_v2_next",
        "legacy_ipset": LEGACY_IPSET_V6,
        "family": "inet6",
        "firewall": "ip6tables",
    },
}


def _env_bool(name: str, default: bool = False) -> bool:
    raw = (os.getenv(name, "") or "").strip().lower()
    if not raw:
        return default
    return raw in {"1", "true", "yes", "y", "on"}


def _env_int(name: str, default: int, *, minimum: int = 1, maximum: int = 10**9) -> int:
    raw = (os.getenv(name, "") or "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(minimum, min(maximum, value))


class ScannerFirewallStore:
    def __init__(
        self,
        data_path: Path | str | None = None,
        *,
        strikes_for_year: int | None = None,
        year_ban_seconds: int | None = None,
        firewall_enabled: bool | None = None,
        dry_run: bool | None = None,
    ) -> None:
        root = Path(__file__).resolve().parent.parent
        default_path = root / "data" / "scanner_blocks.json"
        self.data_path = Path(
            data_path or os.getenv("SCANNER_BLOCKS_FILE", str(default_path))
        )
        self.strikes_for_year = strikes_for_year or _env_int(
            "IP_SCANNER_STRIKES_FOR_YEAR_BAN",
            DEFAULT_STRIKES_FOR_YEAR,
            minimum=1,
            maximum=100,
        )
        self.year_ban_seconds = year_ban_seconds or _env_int(
            "IP_SCANNER_YEAR_BAN_SECONDS",
            DEFAULT_YEAR_BAN_SECONDS,
            minimum=3600,
            maximum=10 * 365 * 86400,
        )
        self.firewall_enabled = (
            firewall_enabled
            if firewall_enabled is not None
            else _env_bool("IP_SCANNER_FIREWALL_ENABLED", True)
        )
        self.dry_run = (
            dry_run
            if dry_run is not None
            else _env_bool("IP_SCANNER_FIREWALL_DRY_RUN", False)
        )
        self.unban_grace_seconds = _env_int(
            "IP_SCANNER_UNBAN_GRACE_SECONDS",
            DEFAULT_UNBAN_GRACE_SECONDS,
            minimum=60,
            maximum=86400,
        )

        self._thread_lock = threading.RLock()
        self._lock_depth = threading.local()
        self._data: dict[str, Any] = {"version": DEFAULT_DATA_VERSION, "entries": {}}

        self.data_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock_path = Path(f"{self.data_path}.lock")
        self._lock_fd = os.open(self._lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        with self._state_lock():
            if not self.data_path.exists():
                self._save_unlocked()

    @contextmanager
    def _state_lock(self) -> Iterator[None]:
        """Сериализует JSON и firewall-операции между потоками и процессами."""

        with self._thread_lock:
            depth = int(getattr(self._lock_depth, "value", 0))
            if depth == 0:
                fcntl.flock(self._lock_fd, fcntl.LOCK_EX)
                self._load_unlocked()
            self._lock_depth.value = depth + 1
            try:
                yield
            finally:
                self._lock_depth.value -= 1
                if self._lock_depth.value == 0:
                    fcntl.flock(self._lock_fd, fcntl.LOCK_UN)

    def _load_unlocked(self) -> None:
        if not self.data_path.exists():
            self._data = {"version": DEFAULT_DATA_VERSION, "entries": {}}
            return
        try:
            raw = json.loads(self.data_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning("Не удалось прочитать %s: %s", self.data_path, exc)
            return
        if isinstance(raw, dict) and isinstance(raw.get("entries"), dict):
            raw.setdefault("version", DEFAULT_DATA_VERSION)
            self._data = raw

    def _save_unlocked(self) -> None:
        self.data_path.parent.mkdir(parents=True, exist_ok=True)
        self._data["version"] = DEFAULT_DATA_VERSION
        payload = json.dumps(self._data, ensure_ascii=False, indent=2, sort_keys=True)
        fd, temp_path = tempfile.mkstemp(
            prefix=f".{self.data_path.name}.",
            dir=str(self.data_path.parent),
            text=True,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, self.data_path)
            directory_fd = os.open(self.data_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)

    @staticmethod
    def _normalize_ip(ip: str) -> str:
        try:
            return str(ipaddress.ip_address(str(ip or "").strip()))
        except ValueError as exc:
            raise ValueError("Некорректный IP-адрес") from exc

    @classmethod
    def _ip_version(cls, ip: str) -> int:
        return ipaddress.ip_address(cls._normalize_ip(ip)).version

    @classmethod
    def _family_spec(cls, ip_or_version: str | int) -> dict[str, str]:
        version = (
            ip_or_version
            if isinstance(ip_or_version, int)
            else cls._ip_version(ip_or_version)
        )
        return _FIREWALL_FAMILIES[version]

    @classmethod
    def _ipset_name(cls, ip: str) -> str:
        return cls._family_spec(ip)["ipset"]

    def _entry_unlocked(self, ip: str) -> dict[str, Any]:
        entries = self._data.setdefault("entries", {})
        record = entries.get(ip)
        if not isinstance(record, dict):
            record = {
                "ip": ip,
                "strikes": 0,
                "ban_until": 0.0,
                "long_term": False,
                "recent_attempts": [],
                "ip_blocked_since": None,
                "unban_grace_until": 0.0,
                "firewall_applied": False,
                "events": [],
            }
            entries[ip] = record
        return record

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
        except (OSError, subprocess.SubprocessError) as exc:
            return False, str(exc)
        if result.returncode == 0:
            return True, (result.stdout or "").strip()
        return False, (result.stderr or result.stdout or "").strip()

    def _ipset_exists(self, ipset_name: str) -> bool | None:
        ok, output = self._run_command(["ipset", "list", "-name"])
        if not ok:
            logger.warning("Не удалось получить список ipset: %s", output)
            return None
        return ipset_name in output.splitlines()

    @staticmethod
    def _rule_args(firewall: str, action: str, ipset_name: str) -> list[str]:
        args = [
            firewall,
            "-w",
            action,
            "INPUT",
        ]
        if action == "-I":
            args.append("1")
        args.extend(["-m", "set", "--match-set", ipset_name, "src", "-j", "DROP"])
        return args

    def _create_family_ipset(self, version: int, ipset_name: str) -> bool:
        spec = self._family_spec(version)
        created, create_error = self._run_command(
            [
                "ipset",
                "create",
                ipset_name,
                "hash:ip",
                "family",
                spec["family"],
                "timeout",
                "0",
                "hashsize",
                "4096",
                "maxelem",
                "65536",
                "-exist",
            ]
        )
        if not created:
            logger.warning("Не удалось создать ipset %s: %s", ipset_name, create_error)
        return created

    def _ensure_family_infrastructure(self, version: int) -> bool:
        if not self.firewall_enabled or self.dry_run:
            return True

        spec = self._family_spec(version)
        if not self._create_family_ipset(version, spec["ipset"]):
            return False

        exists, _ = self._run_command(
            self._rule_args(spec["firewall"], "-C", spec["ipset"])
        )
        if exists:
            return True

        inserted, insert_error = self._run_command(
            self._rule_args(spec["firewall"], "-I", spec["ipset"])
        )
        if not inserted:
            logger.warning(
                "Не удалось добавить правило %s для %s: %s",
                spec["firewall"],
                spec["ipset"],
                insert_error,
            )
        return inserted

    def ensure_firewall_infrastructure(self) -> bool:
        with self._state_lock():
            results = [
                self._ensure_family_infrastructure(version) for version in (4, 6)
            ]
            return all(results)

    def _add_to_ipset(self, ipset_name: str, ip: str, timeout_seconds: int) -> bool:
        args = ["ipset", "add", ipset_name, ip, "-exist"]
        if timeout_seconds > 0:
            args.extend(["timeout", str(int(timeout_seconds))])
        ok, error = self._run_command(args)
        if not ok:
            logger.warning("ipset add failed for %s in %s: %s", ip, ipset_name, error)
        return ok

    def _firewall_add(self, ip: str, timeout_seconds: int) -> bool:
        if not self.firewall_enabled:
            return False
        if self.dry_run:
            logger.info(
                "scanner firewall dry-run add %s timeout=%s", ip, timeout_seconds
            )
            return True

        version = self._ip_version(ip)
        if not self._ensure_family_infrastructure(version):
            return False
        return self._add_to_ipset(self._ipset_name(ip), ip, timeout_seconds)

    def _firewall_remove(self, ip: str) -> bool:
        if not self.firewall_enabled:
            return False
        if self.dry_run:
            logger.info("scanner firewall dry-run del %s", ip)
            return True
        spec = self._family_spec(ip)
        result = True
        for ipset_name in (spec["ipset"], spec["legacy_ipset"]):
            exists = self._ipset_exists(ipset_name)
            if exists is None:
                result = False
                continue
            if not exists:
                continue
            removed, error = self._run_command(
                ["ipset", "del", ipset_name, ip, "-exist"]
            )
            if not removed:
                logger.warning(
                    "ipset del failed for %s in %s: %s", ip, ipset_name, error
                )
            result = result and removed
        return result

    def _firewall_contains(self, ip: str) -> bool:
        if not self.firewall_enabled:
            return False
        if self.dry_run:
            return True
        spec = self._family_spec(ip)
        for ipset_name in (spec["ipset"], spec["legacy_ipset"]):
            member_exists, _ = self._run_command(["ipset", "test", ipset_name, ip])
            if not member_exists:
                continue
            rule_exists, _ = self._run_command(
                self._rule_args(spec["firewall"], "-C", ipset_name)
            )
            if rule_exists:
                return True
        return False

    def _family_infrastructure_present(self, version: int) -> bool:
        if not self.firewall_enabled:
            return False
        if self.dry_run:
            return True
        spec = self._family_spec(version)
        if self._ipset_exists(spec["ipset"]) is not True:
            return False
        rule_exists, _ = self._run_command(
            self._rule_args(spec["firewall"], "-C", spec["ipset"])
        )
        return rule_exists

    def _remove_legacy_family(self, version: int) -> bool:
        spec = self._family_spec(version)
        legacy_exists = self._ipset_exists(spec["legacy_ipset"])
        if legacy_exists is None:
            return False
        if not legacy_exists:
            return True

        firewalls = [spec["firewall"]]
        if version == 6:
            firewalls.append("iptables")

        for firewall in firewalls:
            for _ in range(32):
                exists, _ = self._run_command(
                    self._rule_args(firewall, "-C", spec["legacy_ipset"])
                )
                if not exists:
                    break
                deleted, error = self._run_command(
                    self._rule_args(firewall, "-D", spec["legacy_ipset"])
                )
                if not deleted:
                    logger.warning("Не удалось удалить legacy firewall rule: %s", error)
                    return False

        flushed, flush_error = self._run_command(
            ["ipset", "flush", spec["legacy_ipset"]]
        )
        if not flushed:
            logger.warning("Не удалось очистить legacy ipset: %s", flush_error)
            return False
        destroyed, destroy_error = self._run_command(
            ["ipset", "destroy", spec["legacy_ipset"]]
        )
        if not destroyed:
            logger.warning("Не удалось удалить legacy ipset: %s", destroy_error)
        return destroyed

    def _sync_family_ipset(
        self,
        version: int,
        active_entries: list[tuple[str, int]],
    ) -> bool:
        spec = self._family_spec(version)
        staging_name = spec["sync_ipset"]
        staging_exists = self._ipset_exists(staging_name)
        if staging_exists is None:
            return False
        if staging_exists:
            destroyed, error = self._run_command(["ipset", "destroy", staging_name])
            if not destroyed:
                logger.warning(
                    "Не удалось удалить временный ipset %s: %s",
                    staging_name,
                    error,
                )
                return False
        if not self._create_family_ipset(version, staging_name):
            return False

        populated = True
        for ip, timeout_seconds in active_entries:
            populated = (
                self._add_to_ipset(staging_name, ip, timeout_seconds) and populated
            )
        if not populated:
            destroyed, error = self._run_command(["ipset", "destroy", staging_name])
            if not destroyed:
                logger.warning(
                    "Не удалось удалить неполный ipset %s: %s", staging_name, error
                )
            return False

        swapped, swap_error = self._run_command(
            ["ipset", "swap", staging_name, spec["ipset"]]
        )
        if not swapped:
            logger.warning(
                "Не удалось атомарно заменить ipset %s: %s",
                spec["ipset"],
                swap_error,
            )
            self._run_command(["ipset", "destroy", staging_name])
            return False

        destroyed, destroy_error = self._run_command(["ipset", "destroy", staging_name])
        if not destroyed:
            logger.warning(
                "Не удалось удалить прежнее содержимое ipset %s: %s",
                staging_name,
                destroy_error,
            )
        return destroyed

    def sync_firewall_from_store(self) -> bool:
        if not self.firewall_enabled:
            return False

        now = time.time()
        with self._state_lock():
            entries = self._data.get("entries") or {}
            overall_ok = True

            for version in (4, 6):
                infrastructure_ready = self._ensure_family_infrastructure(version)
                family_records: list[tuple[str, dict[str, Any], int]] = []

                for raw_ip, record in entries.items():
                    if not isinstance(record, dict):
                        continue
                    try:
                        ip = self._normalize_ip(raw_ip)
                    except ValueError:
                        continue
                    if self._ip_version(ip) != version:
                        continue
                    ban_until = float(record.get("ban_until") or 0)
                    if ban_until <= now:
                        record["firewall_applied"] = False
                        continue
                    timeout_seconds = max(1, int(ban_until - now))
                    family_records.append((ip, record, timeout_seconds))

                if self.dry_run:
                    family_ok = infrastructure_ready
                    for ip, record, timeout_seconds in family_records:
                        applied = self._firewall_add(ip, timeout_seconds)
                        record["firewall_applied"] = bool(applied)
                        family_ok = bool(applied) and family_ok
                else:
                    family_ok = infrastructure_ready and self._sync_family_ipset(
                        version,
                        [(ip, timeout) for ip, _, timeout in family_records],
                    )
                    for ip, record, _ in family_records:
                        record["firewall_applied"] = (
                            True if family_ok else self._firewall_contains(ip)
                        )
                    if family_ok:
                        family_ok = self._remove_legacy_family(version)
                overall_ok = overall_ok and family_ok

            self._save_unlocked()
            return overall_ok

    def is_in_unban_grace(self, ip: str, *, now: float | None = None) -> bool:
        ip = self._normalize_ip(ip)
        current_time = time.time() if now is None else now
        with self._state_lock():
            record = (self._data.get("entries") or {}).get(ip)
            return (
                isinstance(record, dict)
                and float(record.get("unban_grace_until") or 0) > current_time
            )

    def _can_apply_firewall_ban(self, ip: str, *, now: float | None = None) -> bool:
        return not self.is_in_unban_grace(ip, now=now)

    def is_banned(self, ip: str, *, now: float | None = None) -> bool:
        ip = self._normalize_ip(ip)
        current_time = time.time() if now is None else now
        with self._state_lock():
            record = (self._data.get("entries") or {}).get(ip)
            if not isinstance(record, dict):
                return False
            ban_until = float(record.get("ban_until") or 0)
            if ban_until > current_time:
                return True
            if ban_until > 0:
                record["ban_until"] = 0.0
                record["firewall_applied"] = False
                self._firewall_remove(ip)
                self._save_unlocked()
            return False

    def get_ban_until(self, ip: str) -> float:
        ip = self._normalize_ip(ip)
        with self._state_lock():
            record = (self._data.get("entries") or {}).get(ip)
            if not isinstance(record, dict):
                return 0.0
            return float(record.get("ban_until") or 0)

    def prune_attempts(
        self, ip: str, window_seconds: int, *, now: float | None = None
    ) -> list[float]:
        ip = self._normalize_ip(ip)
        current_time = time.time() if now is None else now
        cutoff = current_time - window_seconds
        with self._state_lock():
            record = self._entry_unlocked(ip)
            attempts = [
                float(timestamp)
                for timestamp in (record.get("recent_attempts") or [])
                if float(timestamp) >= cutoff
            ]
            record["recent_attempts"] = attempts
            return attempts

    def record_attempt(
        self, ip: str, window_seconds: int, *, now: float | None = None
    ) -> int:
        ip = self._normalize_ip(ip)
        current_time = time.time() if now is None else now
        with self._state_lock():
            attempts = self.prune_attempts(ip, window_seconds, now=current_time)
            record = self._entry_unlocked(ip)
            attempts.append(current_time)
            record["recent_attempts"] = attempts
            self._save_unlocked()
            return len(attempts)

    def touch_ip_blocked(self, ip: str, *, now: float | None = None) -> float | None:
        ip = self._normalize_ip(ip)
        current_time = time.time() if now is None else now
        with self._state_lock():
            record = self._entry_unlocked(ip)
            since = record.get("ip_blocked_since")
            if since is None:
                record["ip_blocked_since"] = current_time
                self._save_unlocked()
                return current_time
            return float(since)

    def register_ban(
        self,
        ip: str,
        *,
        reason: str,
        short_ban_seconds: int,
        now: float | None = None,
    ) -> dict[str, Any] | None:
        ip = self._normalize_ip(ip)
        current_time = time.time() if now is None else now
        with self._state_lock():
            record = self._entry_unlocked(ip)
            if float(record.get("unban_grace_until") or 0) > current_time:
                return None

            strikes = int(record.get("strikes") or 0) + 1
            long_term = strikes >= self.strikes_for_year
            ban_seconds = (
                self.year_ban_seconds if long_term else max(60, int(short_ban_seconds))
            )
            ban_until = current_time + ban_seconds

            record.update(
                {
                    "strikes": strikes,
                    "ip_blocked_since": None,
                    "recent_attempts": [],
                    "long_term": long_term,
                    "ban_until": ban_until,
                }
            )
            applied = self._firewall_add(ip, ban_seconds)
            record["firewall_applied"] = bool(applied)

            events = list(record.get("events") or [])
            events.append(
                {
                    "at": current_time,
                    "reason": reason,
                    "ban_seconds": ban_seconds,
                    "strike": strikes,
                    "long_term": long_term,
                    "firewall": bool(applied),
                }
            )
            record["events"] = events[-50:]
            self._save_unlocked()

            return {
                "ip": ip,
                "strikes": strikes,
                "ban_until": ban_until,
                "remaining_seconds": int(ban_until - current_time),
                "long_term": long_term,
                "firewall": bool(applied),
                "firewall_enabled": self.firewall_enabled,
            }

    def get_active_bans(self, *, now: float | None = None) -> list[dict[str, Any]]:
        current_time = time.time() if now is None else now
        active: list[dict[str, Any]] = []
        with self._state_lock():
            changed = False
            for raw_ip, record in (self._data.get("entries") or {}).items():
                if not isinstance(record, dict):
                    continue
                try:
                    ip = self._normalize_ip(raw_ip)
                except ValueError:
                    continue
                ban_until = float(record.get("ban_until") or 0)
                if ban_until <= current_time:
                    if ban_until > 0:
                        record["ban_until"] = 0.0
                        record["firewall_applied"] = False
                        self._firewall_remove(ip)
                        changed = True
                    continue
                firewall_applied = self._firewall_contains(ip)
                if bool(record.get("firewall_applied")) != firewall_applied:
                    record["firewall_applied"] = firewall_applied
                    changed = True
                active.append(
                    {
                        "ip": ip,
                        "ban_until": ban_until,
                        "remaining_seconds": int(ban_until - current_time),
                        "strikes": int(record.get("strikes") or 0),
                        "long_term": bool(record.get("long_term")),
                        "firewall_applied": firewall_applied,
                    }
                )
            if changed:
                self._save_unlocked()
        active.sort(key=lambda item: item["ban_until"], reverse=True)
        return active

    def get_grace_entries(self, *, now: float | None = None) -> list[dict[str, Any]]:
        current_time = time.time() if now is None else now
        grace_entries: list[dict[str, Any]] = []
        with self._state_lock():
            for ip, record in (self._data.get("entries") or {}).items():
                if not isinstance(record, dict):
                    continue
                ban_until = float(record.get("ban_until") or 0)
                grace_until = float(record.get("unban_grace_until") or 0)
                if ban_until > current_time or grace_until <= current_time:
                    continue
                grace_entries.append(
                    {
                        "ip": ip,
                        "strikes": int(record.get("strikes") or 0),
                        "grace_remaining_seconds": int(grace_until - current_time),
                    }
                )
        grace_entries.sort(
            key=lambda item: item["grace_remaining_seconds"], reverse=True
        )
        return grace_entries

    def get_display_state(self, *, now: float | None = None) -> dict[str, Any]:
        active_bans = self.get_active_bans(now=now)
        grace_entries = self.get_grace_entries(now=now)
        infrastructure_healthy = self.firewall_enabled and all(
            self._family_infrastructure_present(version) for version in (4, 6)
        )
        return {
            "active_bans": active_bans,
            "grace_entries": grace_entries,
            "has_firewall_entries": bool(active_bans or grace_entries),
            "firewall_healthy": infrastructure_healthy
            and all(item["firewall_applied"] for item in active_bans),
        }

    def flush_firewall_sets(self) -> bool:
        if not self.firewall_enabled:
            return False
        if self.dry_run:
            return True
        with self._state_lock():
            result = True
            for version, spec in _FIREWALL_FAMILIES.items():
                exists = self._ipset_exists(spec["ipset"])
                if exists is None:
                    result = False
                elif exists:
                    ok, error = self._run_command(["ipset", "flush", spec["ipset"]])
                    if not ok:
                        logger.warning(
                            "Не удалось очистить %s: %s", spec["ipset"], error
                        )
                    result = result and ok
                staging_exists = self._ipset_exists(spec["sync_ipset"])
                if staging_exists is None:
                    result = False
                elif staging_exists:
                    ok, error = self._run_command(
                        ["ipset", "destroy", spec["sync_ipset"]]
                    )
                    if not ok:
                        logger.warning(
                            "Не удалось удалить временный ipset %s: %s",
                            spec["sync_ipset"],
                            error,
                        )
                    result = result and ok
                result = self._remove_legacy_family(version) and result
            return result

    def release_firewall_only(self, ip: str) -> bool:
        ip = self._normalize_ip(ip)
        with self._state_lock():
            if self.firewall_enabled and not self._firewall_remove(ip):
                return False
            record = (self._data.get("entries") or {}).get(ip)
            if isinstance(record, dict):
                record.update(
                    {
                        "ban_until": 0.0,
                        "long_term": False,
                        "recent_attempts": [],
                        "ip_blocked_since": None,
                        "firewall_applied": False,
                    }
                )
                self._save_unlocked()
            return True

    def unban_ip(
        self,
        ip: str,
        *,
        clear_strikes: bool = True,
        grace_seconds: int | None = None,
    ) -> bool:
        ip = self._normalize_ip(ip)
        grace = grace_seconds if grace_seconds is not None else self.unban_grace_seconds
        grace_until = time.time() + max(60, int(grace))

        with self._state_lock():
            if self.firewall_enabled and not self._firewall_remove(ip):
                return False
            record = self._entry_unlocked(ip)
            record.update(
                {
                    "ban_until": 0.0,
                    "long_term": False,
                    "recent_attempts": [],
                    "ip_blocked_since": None,
                    "unban_grace_until": grace_until,
                    "firewall_applied": False,
                }
            )
            if clear_strikes:
                record["strikes"] = 0
                record["events"] = []
            self._save_unlocked()
            return True

    def clear_all(self) -> bool:
        with self._state_lock():
            if self.firewall_enabled and not self.flush_firewall_sets():
                return False
            self._data["entries"] = {}
            self._save_unlocked()
        return True

    def get_settings_snapshot(self) -> dict[str, Any]:
        return {
            "strikes_for_year": self.strikes_for_year,
            "year_ban_seconds": self.year_ban_seconds,
            "unban_grace_seconds": self.unban_grace_seconds,
            "firewall_enabled": self.firewall_enabled,
            "dry_run": self.dry_run,
            "data_path": str(self.data_path),
            "ipset_v4": IPSET_V4,
            "ipset_v6": IPSET_V6,
        }
