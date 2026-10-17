"""Определяет адрес клиента, не доверяя заголовкам от посторонних узлов."""

import ipaddress
import os


def normalize_client_ip(value):
    try:
        address = ipaddress.ip_address((value or "").strip())
    except ValueError:
        return None
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        return str(address.ipv4_mapped)
    return str(address)


def is_trusted_proxy(address, entries):
    normalized = normalize_client_ip(address)
    if normalized is None:
        return False
    parsed = ipaddress.ip_address(normalized)
    for entry in entries:
        entry = str(entry).strip()
        if entry == "*":
            return True
        try:
            network = ipaddress.ip_network(entry, strict=False)
            if (
                isinstance(network, ipaddress.IPv6Network)
                and network.prefixlen >= 96
                and network.network_address.ipv4_mapped is not None
            ):
                network = ipaddress.ip_network(
                    (network.network_address.ipv4_mapped, network.prefixlen - 96)
                )
            if parsed in network:
                return True
        except ValueError:
            continue
    return False


def resolve_client_ip(request_obj, trusted_proxies):
    remote_ip = normalize_client_ip(request_obj.remote_addr)
    if remote_ip is None or not is_trusted_proxy(remote_ip, trusted_proxies):
        return remote_ip

    forwarded = request_obj.headers.get("X-Forwarded-For")
    if forwarded is not None:
        chain = [normalize_client_ip(value) for value in forwarded.split(",")]
        # Повреждённая цепочка не должна превращаться в разрешённый адрес прокси.
        if any(address is None for address in chain):
            return None
        client_ip = remote_ip
        for address in reversed(chain):
            if not is_trusted_proxy(client_ip, trusted_proxies):
                break
            client_ip = address
        return client_ip

    real_ip = request_obj.headers.get("X-Real-IP")
    return normalize_client_ip(real_ip) if real_ip is not None else remote_ip


def get_client_ip(request_obj=None):
    from flask import current_app, has_app_context, request

    trusted = os.getenv("TRUSTED_PROXY_IPS", "")
    if has_app_context():
        trusted = current_app.config.get("TRUSTED_PROXY_IPS", trusted)
    entries = [entry.strip() for entry in str(trusted).split(",") if entry.strip()]
    return resolve_client_ip(request_obj if request_obj is not None else request, entries)
