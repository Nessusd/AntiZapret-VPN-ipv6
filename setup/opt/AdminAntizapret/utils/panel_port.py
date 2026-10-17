"""Согласованная смена порта панели во внешнем systemd-процессе."""
import argparse
from contextlib import contextmanager
import fcntl
import http.client
import logging
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import sys
import time
import uuid

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from utils.file_io import atomic_write_text, file_lock
from utils.shell_config import parse_shell_assignment, read_shell_assignments

_OWNER_MARKER = "# Managed by AntiZapret integrated installer"
_PROXY_PASS = re.compile(r"(?m)^(\s*proxy_pass http://127\.0\.0\.1:)([0-9]+)(;[ \t]*)$")
_SERVICE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@:-]{0,254}")
_APP_ROOT = Path(__file__).resolve().parent.parent
_SETUP_LOCK = Path("/run/antizapret-setup.lock")
_SETUP_DEFER_MARKER = Path("/run/antizapret-setup.defer-custom-hooks")


@contextmanager
def _setup_guard():
    # Используем тот же inode, что и flock установщика, без второго .lock-суффикса.
    descriptor = os.open(_SETUP_LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Установщик AntiZapret уже работает; смена порта отменена") from error
        if _SETUP_DEFER_MARKER.exists():
            raise RuntimeError("Установщик AntiZapret не завершил переключение; смена порта отменена")
        yield
    finally:
        os.close(descriptor)


def _port(value):
    raw = str(value)
    if not raw.isascii() or not raw.isdigit() or not 1 <= int(raw) <= 65535:
        raise ValueError("Порт должен быть целым числом в диапазоне 1..65535")
    return str(int(raw))


def _read_text(path):
    # Не меняем переводы строк при сохранении и откате .env.
    with path.open("r", encoding="utf-8", newline="") as source:
        return source.read()


def _env_with_port(content, new_port):
    lines = []
    found = False
    for line in content.splitlines(keepends=True):
        assignment = parse_shell_assignment(line)
        if assignment is not None and assignment.key == "APP_PORT":
            lines.append(f"APP_PORT={new_port}\n")
            found = True
        else:
            lines.append(line)
    if not found:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"APP_PORT={new_port}\n")
    return "".join(lines)


def _nginx_change(env, old_port, new_port, nginx_root):
    domain = (env.get("DOMAIN") or "").strip()
    bind = (env.get("BIND") or "0.0.0.0").strip()
    bind_ipv6 = (env.get("BIND_IPV6") or "").strip()
    loopbacks = {"127.0.0.1", "localhost", "::1"}
    proxied = (
        domain and bind in loopbacks and (not bind_ipv6 or bind_ipv6 in loopbacks)
        and env.get("USE_HTTPS", "false").lower() != "true"
    )
    if not proxied:
        return None
    labels = domain.split(".")
    if len(labels) < 2 or len(domain) > 253 or re.fullmatch(r"[A-Za-z]{2,63}", labels[-1]) is None or any(
        re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label) is None
        for label in labels
    ):
        raise ValueError("Некорректный домен панели")
    config_name = domain.replace(".", "_")
    site = Path(nginx_root) / "sites-available" / config_name
    enabled = Path(nginx_root) / "sites-enabled" / config_name
    if site.is_symlink() or not site.is_file() or not enabled.is_symlink() or enabled.resolve() != site.resolve():
        raise RuntimeError("Не найдена собственная активная конфигурация Nginx панели")
    content = _read_text(site)
    legacy_owned = all(fragment in content for fragment in (
        f"server_name {domain};",
        f"ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;",
        f"ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;",
    ))
    if _OWNER_MARKER not in content.splitlines() and not legacy_owned:
        raise RuntimeError("Отказ изменять чужую конфигурацию Nginx")
    ports = [match[2] for match in _PROXY_PASS.finditer(content)]
    if not ports or any(_port(value) != old_port for value in ports):
        raise RuntimeError("Upstream Nginx не соответствует текущему порту панели")
    replacement = _PROXY_PASS.sub(lambda match: f"{match[1]}{new_port}{match[3]}", content)
    return site, content, replacement


def _command(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"Не удалось выполнить {command[0]}: {error}") from error
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout or "Ошибка системной команды").strip())


def _listen_hosts(env):
    host = (env.get("BIND") or "0.0.0.0").strip()
    hosts = ["127.0.0.1" if host == "0.0.0.0" else "::1" if host == "::" else host]
    ipv6 = (env.get("BIND_IPV6") or "").strip()
    if ipv6:
        hosts.append("::1" if ipv6 == "::" else ipv6)
    return list(dict.fromkeys(hosts))


def _require_free_port(env, port):
    for host in _listen_hosts(env):
        try:
            with socket.create_connection((host, int(port)), timeout=1):
                raise RuntimeError(f"Порт {port} уже занят на {host}")
        except (ConnectionRefusedError, TimeoutError):
            pass


def _require_unreserved_port(env, port):
    if port not in {"80", "443", "504", "508"}:
        return
    install_dir = env.get("ANTIZAPRET_INSTALL_DIR") or env.get("APP_BACKUP_AZ_INSTALL_DIR") or "/root/antizapret"
    try:
        settings = read_shell_assignments(_read_text(Path(install_dir) / "setup"))
    except FileNotFoundError:
        return
    if all(str(settings.get(key) or "n").lower() == "y" for key in ("OPENVPN_TCP_ENABLE", "OPENVPN_BACKUP_TCP")):
        raise RuntimeError(f"Порт {port} зарезервирован резервными TCP-портами OpenVPN")


def _wait_for_panel(env, port, timeout=60):
    pending = set(_listen_hosts(env))
    deadline = time.monotonic() + timeout
    while pending and time.monotonic() < deadline:
        for host in list(pending):
            secure = env.get("USE_HTTPS", "false").lower() == "true" and env.get("SSL_CERT") and env.get("SSL_KEY")
            connection = (
                http.client.HTTPSConnection(host, int(port), timeout=2, context=ssl._create_unverified_context())
                if secure else http.client.HTTPConnection(host, int(port), timeout=2)
            )
            try:
                connection.request("GET", "/login", headers={"Host": env.get("DOMAIN") or host})
                if 200 <= connection.getresponse().status < 500:
                    pending.remove(host)
            except (OSError, http.client.HTTPException):
                pass
            finally:
                connection.close()
        if pending:
            time.sleep(0.5)
    if pending:
        raise RuntimeError(f"Панель не отвечает на новом порту {port}")


def change_panel_port(app_root, old_port, new_port, *, nginx_root="/etc/nginx"):
    old_port, new_port = _port(old_port), _port(new_port)
    env_path = Path(app_root) / ".env"
    # При запуске панель тоже меняет .env. Его lock нельзя держать при restart.
    with _setup_guard(), file_lock(Path(app_root) / ".panel-port-change"):
        with file_lock(env_path):
            content = _read_text(env_path)
        env = read_shell_assignments(content)
        if _port(env.get("APP_PORT") or "5050") != old_port:
            raise RuntimeError("Порт уже изменён другой операцией; обновите страницу")
        if old_port == new_port:
            return
        service = env.get("ADMIN_ANTIZAPRET_SERVICE_NAME") or "admin-antizapret.service"
        if _SERVICE_NAME.fullmatch(service) is None:
            raise ValueError("Некорректное имя systemd-службы панели")
        _require_unreserved_port(env, new_port)
        nginx = _nginx_change(env, old_port, new_port, nginx_root)
        _require_free_port(env, new_port)
        env_published = nginx_published = restart_attempted = False
        published_content = None
        try:
            if nginx:
                if _read_text(nginx[0]) != nginx[1]:
                    raise RuntimeError("Конфигурация Nginx изменена другой операцией")
                atomic_write_text(nginx[0], nginx[2])
                nginx_published = True
                _command(["nginx", "-t"])
            with file_lock(env_path):
                current = _read_text(env_path)
                if current != content:
                    raise RuntimeError("Настройки уже изменены другой операцией; повторите смену порта")
                published_content = _env_with_port(content, new_port)
                atomic_write_text(env_path, published_content)
                env_published = True
            restart_attempted = True
            _command(["systemctl", "restart", service])
            _wait_for_panel(env, new_port)
            _command(["systemctl", "is-active", "--quiet", service])
            if nginx:
                _command(["systemctl", "reload", "nginx.service"])
        except Exception as error:
            failures = []
            if env_published:
                try:
                    with file_lock(env_path):
                        current = _read_text(env_path)
                        if _port(read_shell_assignments(current).get("APP_PORT") or "5050") != new_port:
                            raise RuntimeError("Порт изменён другой операцией; его откат пропущен")
                        # При параллельной записи возвращаем только наш ключ, а не весь snapshot.
                        restored = content if current == published_content else _env_with_port(current, old_port)
                        atomic_write_text(env_path, restored)
                except Exception as rollback_error:
                    failures.append(str(rollback_error))
            if nginx_published:
                try:
                    current_nginx = _nginx_change(env, new_port, old_port, nginx_root)
                    restored = nginx[1] if current_nginx[1] == nginx[2] else current_nginx[2]
                    atomic_write_text(nginx[0], restored)
                except Exception as rollback_error:
                    failures.append(str(rollback_error))
            if restart_attempted:
                try:
                    _command(["systemctl", "restart", service])
                    _wait_for_panel(env, old_port)
                    _command(["systemctl", "is-active", "--quiet", service])
                except Exception as rollback_error:
                    failures.append(str(rollback_error))
            if nginx_published:
                try:
                    _command(["nginx", "-t"])
                    _command(["systemctl", "reload", "nginx.service"])
                except Exception as rollback_error:
                    failures.append(str(rollback_error))
            if failures:
                raise RuntimeError(f"{error}; ошибка отката: {'; '.join(failures)}") from error
            raise


def queue_panel_port_change(old_port, new_port):
    old_port, new_port = _port(old_port), _port(new_port)
    # systemd запускает независимый процесс: restart панели не прерывает откат.
    unit = "admin-antizapret-port-" + uuid.uuid4().hex
    _command([
        "systemd-run", "--quiet", "--unit", unit,
        "/usr/bin/python3", str(Path(__file__).resolve()),
        "--app-root", str(_APP_ROOT), "--old-port", old_port, "--new-port", new_port,
    ])
    return unit


def main():
    parser = argparse.ArgumentParser(description="Согласованная смена порта панели")
    parser.add_argument("--app-root", required=True)
    parser.add_argument("--old-port", required=True)
    parser.add_argument("--new-port", required=True)
    args = parser.parse_args()
    def interrupted(signum, _frame):
        raise RuntimeError(f"Смена порта прервана сигналом {signal.Signals(signum).name}")

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    try:
        # Даём HTTP-обработчику завершить ответ до остановки его службы.
        time.sleep(1)
        change_panel_port(args.app_root, args.old_port, args.new_port)
    except Exception:
        logging.exception("Не удалось изменить порт панели")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
