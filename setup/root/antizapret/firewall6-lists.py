#!/usr/bin/env python3
from __future__ import annotations

import glob
import ipaddress
import os
import sys
from pathlib import Path

ROOT = Path(os.environ.get("ANTIZAPRET_ROOT", "/root/antizapret"))
RESULT = ROOT / "result"
STATE = ROOT / "state"
DOWNLOAD_CACHE = STATE / "download-ips6.txt"
OPENVPN_DEFAULT = Path(
    os.environ.get("ANTIZAPRET_OPENVPN_DEFAULT", "/etc/openvpn/server/ccd/DEFAULT")
)
OPENVPN_BEGIN = "# BEGIN ANTIZAPRET MANAGED IPV6 ROUTES"
OPENVPN_END = "# END ANTIZAPRET MANAGED IPV6 ROUTES"


def read_paths(paths: list[Path]) -> set[ipaddress.IPv6Network]:
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


def write_result(filename: str, networks: set[ipaddress.IPv6Network]) -> None:
    write_file(RESULT / filename, networks)
    print(f"{len(networks)} - {filename}")


def write_openvpn_routes(
    destination: Path,
    networks: set[ipaddress.IPv6Network],
    *,
    enabled: bool = True,
) -> None:
    mode = 0o644
    try:
        original = destination.read_text(encoding="utf-8")
        mode = destination.stat().st_mode & 0o777
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
        retained.extend([OPENVPN_END])
    retained.append("")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text("\n".join(retained), encoding="utf-8")
    os.chmod(temporary, mode)
    temporary.replace(destination)


def downloaded_networks(refresh_download: bool) -> set[ipaddress.IPv6Network]:
    download_paths = matching_paths(["download/*ips.txt", "download/*ips6.txt"])
    if refresh_download or download_paths:
        networks = read_paths(download_paths)
        write_file(DOWNLOAD_CACHE, networks)
        return networks
    return read_paths([DOWNLOAD_CACHE])


def main() -> int:
    valid_arguments = {"--refresh-download", "--disable-openvpn"}
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1] not in valid_arguments):
        print(
            f"Usage: {sys.argv[0]} [--refresh-download|--disable-openvpn]",
            file=sys.stderr,
        )
        return 2

    if len(sys.argv) == 2 and sys.argv[1] == "--disable-openvpn":
        write_openvpn_routes(OPENVPN_DEFAULT, set(), enabled=False)
        return 0

    refresh_download = len(sys.argv) == 2
    route = downloaded_networks(refresh_download) | read_networks(["config/*include-ips.txt"])
    route.difference_update(read_networks(["config/*exclude-ips.txt"]))

    write_result("route-ips6.txt", route)
    write_openvpn_routes(OPENVPN_DEFAULT, route)
    write_result("allow-ips6.txt", read_networks(["config/*allow-ips.txt"]))
    write_result("deny-ips6.txt", read_networks(["config/*deny-ips.txt"]))
    write_result("drop-ips6.txt", read_networks(["config/*drop-ips.txt"]))
    write_result("forward-ips6.txt", route | read_networks(["config/*forward-ips.txt"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
