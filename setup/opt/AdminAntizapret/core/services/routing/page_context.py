# Показывает маршрутизацию с учётом фактического IPv6-режима AntiZapret.
from config.antizapret_params import ANTIZAPRET_PARAMS
from core.services.antizapret_settings import (
    is_antizapret_ipv6_enabled,
    read_antizapret_settings,
)


def build_routing_page_context():
    antizapret_settings = read_antizapret_settings()
    return {
        "antizapret_settings": antizapret_settings,
        "antizapret_params": {param["key"]: param for param in ANTIZAPRET_PARAMS},
        "antizapret_ipv6_enabled": is_antizapret_ipv6_enabled(antizapret_settings),
    }
