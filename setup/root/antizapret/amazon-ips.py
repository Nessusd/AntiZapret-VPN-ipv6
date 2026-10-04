#!/usr/bin/env python3
"""Собирает IP-списки Amazon из одной официальной публикации AWS."""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

SOURCE_URL = "https://ip-ranges.amazonaws.com/ip-ranges.json"


def extract_networks(payload: dict, version: int) -> list:
    collection, field = (
        ("prefixes", "ip_prefix") if version == 4 else ("ipv6_prefixes", "ipv6_prefix")
    )
    records = payload.get(collection)
    if not isinstance(records, list) or not records:
        raise ValueError(f"AWS: empty or invalid {collection}")

    networks = set()
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get(field), str):
            raise ValueError(f"AWS: missing {field}")
        network = ipaddress.ip_network(record[field], strict=True)
        if network.version != version or network.prefixlen == 0:
            raise ValueError(f"AWS: invalid IPv{version} network {network}")
        networks.add(network)

    # Объединение только смежных сетей не добавляет адресов между ними.
    return list(ipaddress.collapse_addresses(networks))


def render_list(networks: list, version: int) -> str:
    header = (
        "# НЕ РЕДАКТИРУЙТЕ ЭТОТ ФАЙЛ!\n"
        f"# Amazon Web Services IPv{version} prefixes\n"
        f"# {SOURCE_URL}\n\n"
    )
    return header + "".join(f"{network}\n" for network in networks)


def write_lists(payload: dict, destination: Path, *, ipv6: bool = True) -> None:
    versions = (4, 6) if ipv6 else (4,)
    # Сначала проверяем весь ответ. Ошибка IPv6 не должна заменить IPv4-файл.
    contents = {
        version: render_list(extract_networks(payload, version), version)
        for version in versions
    }
    destination.mkdir(parents=True, exist_ok=True)
    staged = []
    backups = {}
    published = []
    recovery_directory = None
    keep_recovery = False
    try:
        for version, content in contents.items():
            filename = "amazon-ips.txt" if version == 4 else "amazon-ips6.txt"
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=destination, delete=False
            ) as temporary:
                staged.append((Path(temporary.name), destination / filename))
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
                os.fchmod(temporary.fileno(), 0o644)
        # Резервные копии живут вне staging-каталога: ошибка отката не должна
        # уничтожить их при последующей уборке неудачного обновления.
        recovery_directory = Path(
            tempfile.mkdtemp(prefix="amazon-recovery-", dir=destination.parent)
        )
        for _, target in staged:
            if target.exists():
                backup = recovery_directory / target.name
                shutil.copy2(target, backup)
                backups[target] = backup
            else:
                backups[target] = None
        try:
            for temporary, target in staged:
                os.replace(temporary, target)
                published.append(target)
        except OSError as publication_error:
            rollback_errors = []
            for target in reversed(published):
                try:
                    backup = backups[target]
                    if backup is None:
                        target.unlink(missing_ok=True)
                    else:
                        os.replace(backup, target)
                except OSError as rollback_error:
                    rollback_errors.append(str(rollback_error))
            if rollback_errors:
                keep_recovery = True
                raise OSError(
                    f"AWS publication and rollback failed; recovery copies: "
                    f"{recovery_directory}; {'; '.join(rollback_errors)}"
                ) from publication_error
            raise
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)
        if recovery_directory is not None and not keep_recovery:
            shutil.rmtree(recovery_directory)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="AWS ip-ranges.json")
    parser.add_argument("destination", type=Path, help="Output directory")
    parser.add_argument("--disable-ipv6", action="store_true")
    args = parser.parse_args(argv)
    try:
        with args.source.open(encoding="utf-8") as source:
            payload = json.load(source)
        if not isinstance(payload, dict):
            raise ValueError("AWS: expected a JSON object")
        write_lists(payload, args.destination, ipv6=not args.disable_ipv6)
    except (OSError, ValueError) as error:
        print(f"Failed to build Amazon IP lists: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
