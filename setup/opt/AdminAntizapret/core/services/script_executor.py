import os
import ipaddress
import subprocess


class ScriptExecutor:
    def __init__(
        self,
        min_cert_expire=1,
        max_cert_expire=3650,
        client_sh_cwd=None,
    ):
        self.min_cert_expire = min_cert_expire
        self.max_cert_expire = max_cert_expire
        self.client_sh_cwd = os.path.abspath(
            client_sh_cwd
            or os.environ.get("APP_BACKUP_AZ_INSTALL_DIR")
            or os.environ.get("ANTIZAPRET_INSTALL_DIR")
            or "/root/antizapret"
        )

    @staticmethod
    def _validate_routed_ipv6_prefix(value):
        if not value:
            return ""
        try:
            network = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise ValueError("Некорректный маршрутизируемый IPv6-префикс") from exc
        if not isinstance(network, ipaddress.IPv6Network):
            raise ValueError("Маршрутизируемый префикс должен быть IPv6")
        if not network.subnet_of(ipaddress.IPv6Network("2000::/3")):
            raise ValueError("Маршрутизируемый префикс должен быть глобальным IPv6 unicast")
        if not 48 <= network.prefixlen <= 64:
            raise ValueError("Длина маршрутизируемого IPv6-префикса должна быть от /48 до /64")
        return network.with_prefixlen

    def run_bash_script(
        self,
        option,
        client_name,
        cert_expire=None,
        *,
        routed_ipv6_prefix=None,
        route_mode=None,
    ):
        if not option.isdigit():
            raise ValueError("Некорректный параметр option")

        # argv-list передаётся в subprocess с shell=False, поэтому shlex.quote()
        # здесь не нужен — кавычки стали бы частью самого аргумента.
        command = ["./client.sh", option, client_name]

        if str(option) == "1":
            if cert_expire:
                if not cert_expire.isdigit() or not (
                    self.min_cert_expire <= int(cert_expire) <= self.max_cert_expire
                ):
                    raise ValueError("Некорректный срок действия сертификата")
                command.append(cert_expire)
            elif routed_ipv6_prefix is not None or route_mode is not None:
                # client.sh expects the routed prefix in argv[4], after the
                # optional certificate lifetime in argv[3].
                command.append("")

        if route_mode is not None and route_mode not in {"static", "bgp"}:
            raise ValueError("Некорректный режим доставки маршрутов")

        if str(option) == "1" and (routed_ipv6_prefix is not None or route_mode is not None):
            command.append(self._validate_routed_ipv6_prefix(routed_ipv6_prefix))
            if route_mode is not None:
                command.append(route_mode)
        elif str(option) == "4" and route_mode is not None:
            command.extend(["", route_mode])

        result = subprocess.run(
            command,
            cwd=self.client_sh_cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            shell=False,
        )
        if result.returncode != 0:
            raise subprocess.CalledProcessError(
                result.returncode, command, output=result.stdout, stderr=result.stderr
            )
        return result.stdout, result.stderr
