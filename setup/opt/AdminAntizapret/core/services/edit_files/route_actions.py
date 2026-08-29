def build_route_download_actions(
    public_download_enabled: bool,
    url_for,
    *,
    ipv6_enabled: bool,
) -> list[dict]:
    actions = [
        {
            "label": "Общий список IP — IPv4",
            "href": url_for(
                "download",
                file_type="antizapret_result",
                filename="route-ips.txt",
            ),
            "open_in_new_tab": False,
        }
    ]

    if ipv6_enabled:
        actions.append(
            {
                "label": "Общий список IP — IPv6",
                "href": url_for(
                    "download",
                    file_type="antizapret_result",
                    filename="route-ips6.txt",
                ),
                "open_in_new_tab": False,
            }
        )

    if not public_download_enabled:
        return actions

    actions.append(
        {
            "label": "Публично: Общий список IP — IPv4",
            "href": url_for("public_download", router="ips"),
            "open_in_new_tab": True,
        }
    )
    if ipv6_enabled:
        actions.append(
            {
                "label": "Публично: Общий список IP — IPv6",
                "href": url_for("public_download", router="ips6"),
                "open_in_new_tab": True,
            }
        )
    return actions
