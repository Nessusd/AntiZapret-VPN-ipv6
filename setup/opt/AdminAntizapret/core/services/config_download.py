# Сохраняет короткие имена VPN-профилей при скачивании через веб-интерфейс.
import os
import re


def build_short_download_name(file_path: str) -> str:
    base = os.path.basename(file_path)
    pattern = re.compile(
        r"^(?P<prefix>antizapret|vpn)-(?P<client>[\w\-]+?)(?:_(?P<id>[\w\-]+))?(?:-\([^)]+\))?(?:-(?P<proto>udp|tcp))?(?:-(?P<suffix>wg|am))?\.(?P<ext>ovpn|conf)$",
        re.IGNORECASE,
    )
    match = pattern.match(base)

    if not match:
        return base

    prefix = (match.group("prefix") or "").lower()
    client = match.group("client") or "client"
    profile_id = match.group("id")
    proto = match.group("proto")
    ext = (match.group("ext") or "conf").lower()

    prefix_out = "az" if prefix == "antizapret" else "vpn"
    base_name = f"{prefix_out}-{client}_{profile_id}" if profile_id else f"{prefix_out}-{client}"
    if proto:
        return f"{base_name}-{proto}.{ext}"
    return f"{base_name}.{ext}"
