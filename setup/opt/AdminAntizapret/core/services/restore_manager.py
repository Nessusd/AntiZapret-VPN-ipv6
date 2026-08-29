"""Восстановление runtime-данных панели во внешнем systemd-процессе."""

from __future__ import annotations

import fcntl
import json
import os
import re
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager, suppress
from datetime import datetime, timezone
from pathlib import Path

_JOB_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_SYSTEMD_SERVICE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,254}$")
_SQLITE_SUFFIXES = (".db", ".db-wal", ".db-shm")
_MAX_ARCHIVE_MEMBERS = 10_000
_MAX_RESTORE_BYTES = 8 * 1024 * 1024 * 1024
_DEFAULT_STATE_ROOT = "/var/lib/admin-antizapret/restore-jobs"
_DEFAULT_LOCK_PATH = "/run/admin-antizapret-restore.lock"


class RestoreJobService:
    def __init__(
        self,
        *,
        app_root: str,
        backup_root: str,
        service_name: str,
        state_root: str = _DEFAULT_STATE_ROOT,
        lock_path: str | None = None,
        unit_prefix: str = "admin-antizapret-restore",
    ) -> None:
        normalized_service_name = str(service_name or "")
        if not _SYSTEMD_SERVICE_RE.fullmatch(normalized_service_name):
            raise ValueError("Некорректное имя systemd-службы панели")

        self.app_root = os.path.abspath(app_root)
        self.backup_root = os.path.abspath(backup_root)
        self.service_name = normalized_service_name
        self.state_root = os.path.abspath(state_root)
        self.lock_path = os.path.abspath(
            lock_path
            or (
                _DEFAULT_LOCK_PATH
                if self.state_root == os.path.abspath(_DEFAULT_STATE_ROOT)
                else os.path.join(self.state_root, ".restore.lock")
            )
        )
        self.unit_prefix = unit_prefix

    def queue(self, backup_name: str) -> dict:
        job_id = self._create_job(backup_name)
        status_token = self._read_status_token(job_id)
        unit_name = f"{self.unit_prefix}@{job_id}.service"
        try:
            self._run_command(["systemctl", "start", "--no-block", unit_name])
        except Exception as exc:
            self._write_status(job_id, status="failed", stage="launch", error=str(exc))
            raise
        return {
            "job_id": job_id,
            "status_url": f"/api/backups/restore/{job_id}",
            "status_token": status_token,
            "message": "Восстановление поставлено в системную очередь",
        }

    def run_synchronous(self, backup_name: str) -> dict:
        job_id = self._create_job(backup_name)
        result = self.run_job(job_id)
        result["job_id"] = job_id
        return result

    def read_status(self, job_id: str) -> dict:
        job_id = self._validate_job_id(job_id)
        status_path = self._job_dir(job_id) / "status.json"
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise FileNotFoundError("Задача восстановления не найдена") from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError("Не удалось прочитать состояние восстановления") from exc
        if not isinstance(payload, dict):
            raise RuntimeError(  # noqa: TRY004 - это повреждённое persisted state
                "Некорректное состояние восстановления"
            )
        return payload

    def read_status_with_token(self, job_id: str, status_token: str) -> dict:
        expected_token = self._read_status_token(job_id)
        supplied_token = str(status_token or "")
        if not supplied_token or not secrets.compare_digest(
            supplied_token, expected_token
        ):
            raise PermissionError("Недействительный ключ состояния восстановления")
        return self.read_status(job_id)

    def run_job(self, job_id: str) -> dict:
        job_id = self._validate_job_id(job_id)
        job_dir = self._job_dir(job_id)
        archive_path = ""
        staging_dir = job_dir / "staging"
        rollback_dir = job_dir / "rollback"
        service_maintenance_started = False
        published = False
        rollback_manifest: list[dict] = []
        allowed_external_targets: set[str] = set()

        with self._global_restore_lock(job_id):
            try:
                allowed_external_targets = self._external_data_targets()
                self._write_status(
                    job_id, status="running", stage="prepare", progress=10
                )
                request_payload = self._read_request(job_id)
                archive_path = str(request_payload["archive_path"])
                manifest = self._prepare_archive(
                    archive_path,
                    staging_dir,
                    allowed_external_targets,
                )

                self._write_status(job_id, status="running", stage="stop", progress=35)
                service_maintenance_started = True
                self._service_control("stop")
                self._require_service_stopped()

                self._write_status(
                    job_id, status="running", stage="snapshot", progress=45
                )
                rollback_manifest = self._snapshot_targets(
                    manifest,
                    rollback_dir,
                    allowed_external_targets,
                )

                self._write_status(
                    job_id, status="running", stage="publish", progress=55
                )
                published = True
                self._publish_manifest(manifest, staging_dir, allowed_external_targets)

                self._write_status(
                    job_id, status="running", stage="migrate", progress=70
                )
                self._run_database_migration()

                self._write_status(job_id, status="running", stage="start", progress=82)
                self._service_control("start")
                self._wait_for_service_active()

                self._write_status(
                    job_id, status="running", stage="health", progress=92
                )
                self._require_panel_health()

                result = {
                    "archive_path": archive_path,
                    "message": "Восстановление завершено",
                    "restored_files": sum(1 for item in manifest if item.get("source")),
                }
                self._write_status(
                    job_id,
                    status="completed",
                    stage="done",
                    progress=100,
                    result=result,
                )
                return result
            except Exception as exc:
                rollback_errors: list[str] = []
                if published:
                    rollback_ready = False
                    try:
                        self._service_control("stop")
                        self._require_service_stopped()
                        rollback_ready = True
                    except Exception as stop_exc:  # noqa: BLE001 - rollback boundary
                        rollback_errors.append(str(stop_exc))
                    if rollback_ready:
                        try:
                            self._restore_snapshot(
                                rollback_manifest,
                                rollback_dir,
                                allowed_external_targets,
                            )
                        except Exception as rollback_exc:  # noqa: BLE001 - rollback boundary
                            rollback_errors.append(str(rollback_exc))

                if service_maintenance_started:
                    try:
                        self._service_control("start")
                        self._wait_for_service_active()
                        self._require_panel_health()
                    except Exception as start_exc:  # noqa: BLE001 - recovery boundary
                        rollback_errors.append(str(start_exc))

                self._write_status(
                    job_id,
                    status="failed",
                    stage="rollback" if published else "prepare",
                    progress=100,
                    error=str(exc),
                    rollback_success=not rollback_errors,
                    rollback_errors=rollback_errors,
                )
                if rollback_errors:
                    raise RuntimeError(
                        f"{exc}; восстановление прежнего состояния завершилось с ошибками: "
                        + "; ".join(rollback_errors)
                    ) from exc
                raise
            finally:
                shutil.rmtree(staging_dir, ignore_errors=True)
                shutil.rmtree(rollback_dir, ignore_errors=True)

    def _create_job(self, backup_name: str) -> str:
        archive_path = self._resolve_backup_path(backup_name)
        self._validate_archive(archive_path)

        self._ensure_state_root()
        job_id = secrets.token_hex(16)
        job_dir = self._job_dir(job_id)
        job_dir.mkdir(mode=0o700)
        request_payload = {
            "job_id": job_id,
            "archive_path": archive_path,
            "status_token": secrets.token_urlsafe(32),
            "created_at": self._utc_now(),
        }
        self._atomic_json_write(job_dir / "request.json", request_payload)
        self._write_status(job_id, status="queued", stage="queued", progress=0)
        return job_id

    def _resolve_backup_path(self, backup_name: str) -> str:
        raw = str(backup_name or "").strip()
        if not raw:
            raise ValueError("Не выбран файл бэкапа")
        path = (
            os.path.abspath(raw)
            if os.path.isabs(raw)
            else os.path.abspath(os.path.join(self.backup_root, os.path.basename(raw)))
        )
        real_backup_root = os.path.realpath(self.backup_root)
        real_path = os.path.realpath(path)
        if os.path.commonpath([real_backup_root, real_path]) != real_backup_root:
            raise ValueError("Недопустимый путь к бэкапу")
        if os.path.islink(path):
            raise ValueError("Файл бэкапа не должен быть символической ссылкой")
        if not os.path.isfile(real_path):
            raise FileNotFoundError(f"Файл бэкапа не найден: {path}")
        return real_path

    def _validate_archive(self, archive_path: str) -> list[dict]:
        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                return self._build_manifest(
                    archive.getmembers(),
                    self._external_data_targets(),
                )
        except (OSError, tarfile.TarError) as exc:
            raise RuntimeError("Не удалось открыть архив резервной копии") from exc

    def _prepare_archive(
        self,
        archive_path: str,
        staging_dir: Path,
        allowed_external_targets: set[str],
    ) -> list[dict]:
        staging_dir.mkdir(mode=0o700)
        (staging_dir / "files").mkdir(mode=0o700)

        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
            manifest = self._build_manifest(members, allowed_external_targets)
            by_member = {
                item["member"]: item for item in manifest if item.get("member")
            }
            for member in members:
                item = by_member.get(member.name)
                if item is None:
                    continue
                source = archive.extractfile(member)
                if source is None:
                    raise RuntimeError(
                        f"Не удалось прочитать файл из архива: {member.name}"
                    )
                target = staging_dir / item["source"]
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                    output.flush()
                    os.fsync(output.fileno())
                os.chmod(target, int(item["mode"]))

        self._atomic_json_write(staging_dir / "manifest.json", manifest)
        return manifest

    def _build_manifest(
        self,
        members: list[tarfile.TarInfo],
        allowed_external_targets: set[str],
    ) -> list[dict]:
        if len(members) > _MAX_ARCHIVE_MEMBERS:
            raise RuntimeError("В архиве слишком много файлов")

        manifest: list[dict] = []
        targets: set[str] = set()
        total_size = 0
        for member in members:
            member_target = self._member_target(member.name)
            if member.isdir():
                app_prefix = f"{self.app_root}{os.sep}"
                if member_target != self.app_root and not member_target.startswith(
                    app_prefix
                ):
                    raise RuntimeError(
                        f"Архив содержит каталог вне runtime панели: {member.name}"
                    )
                continue
            if not member.isfile():
                raise RuntimeError(
                    f"Архив содержит неподдерживаемую запись: {member.name}"
                )
            target = member_target
            if not self._is_allowed_target(target, allowed_external_targets):
                raise RuntimeError(
                    f"Архив содержит файл вне runtime панели: {member.name}"
                )
            if target in targets:
                raise RuntimeError(f"Архив содержит повторяющийся файл: {member.name}")
            if member.size < 0:
                raise RuntimeError(f"Некорректный размер файла в архиве: {member.name}")
            total_size += member.size
            if total_size > _MAX_RESTORE_BYTES:
                raise RuntimeError("Распакованный архив превышает допустимый размер")
            targets.add(target)
            manifest.append(
                {
                    "member": member.name,
                    "target": target,
                    "source": f"files/{len(manifest):06d}",
                    "mode": 0o600,
                }
            )

        if not manifest:
            raise RuntimeError("Архив не содержит поддерживаемых runtime-файлов панели")
        return self._with_sqlite_sidecars(manifest)

    def _member_target(self, member_name: str) -> str:
        name = str(member_name or "")
        path = Path(name)
        if not name or path.is_absolute() or ".." in path.parts:
            raise RuntimeError("Архив содержит недопустимый путь")
        target = os.path.abspath(os.path.join("/", name))
        if target == "/":
            raise RuntimeError("Архив содержит недопустимый путь")
        return target

    def _is_allowed_target(
        self, target: str, allowed_external_targets: set[str]
    ) -> bool:
        app_root = Path(self.app_root)
        target_path = Path(target)
        try:
            relative = target_path.relative_to(app_root)
        except ValueError:
            return target in allowed_external_targets

        parts = relative.parts
        if parts == (".env",):
            return True
        if len(parts) == 1 and relative.name.endswith(_SQLITE_SUFFIXES):
            return True
        if (
            len(parts) == 2
            and parts[0] == "instance"
            and relative.name.endswith(_SQLITE_SUFFIXES)
        ):
            return True
        return len(parts) == 2 and parts[0] == "data" and relative.suffix == ".json"

    def _external_data_targets(self) -> set[str]:
        env_map = self._load_env_map(Path(self.app_root) / ".env")
        result = set()
        for key in ("TEMPORARY_WHITELIST_FILE", "SCANNER_BLOCKS_FILE"):
            raw = str(env_map.get(key) or "").strip()
            if raw:
                result.add(
                    os.path.abspath(
                        raw if os.path.isabs(raw) else os.path.join(self.app_root, raw)
                    )
                )
        return result

    @staticmethod
    def _load_env_map(path: Path) -> dict[str, str]:
        result: dict[str, str] = {}
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return result
        for raw_line in lines:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip().strip("'").strip('"')
        return result

    def _with_sqlite_sidecars(self, manifest: list[dict]) -> list[dict]:
        targets = {item["target"] for item in manifest}
        for target in targets:
            if target.endswith((".db-wal", ".db-shm")) and target[:-4] not in targets:
                raise RuntimeError(
                    f"Архив содержит SQLite sidecar без основного файла БД: {target}"
                )
        additions = []
        for item in manifest:
            target = str(item["target"])
            if not target.endswith(".db"):
                continue
            for suffix in ("-wal", "-shm"):
                sidecar = f"{target}{suffix}"
                if sidecar in targets:
                    continue
                targets.add(sidecar)
                additions.append(
                    {
                        "member": None,
                        "target": sidecar,
                        "source": None,
                        "mode": 0o600,
                    }
                )
        return manifest + additions

    def _snapshot_targets(
        self,
        manifest: list[dict],
        rollback_dir: Path,
        allowed_external_targets: set[str],
    ) -> list[dict]:
        rollback_dir.mkdir(mode=0o700)
        files_dir = rollback_dir / "files"
        files_dir.mkdir(mode=0o700)
        rollback_manifest = []
        for index, item in enumerate(manifest):
            target = Path(item["target"])
            self._validate_target_parent(target, allowed_external_targets)
            if target.is_symlink():
                raise RuntimeError(
                    f"Runtime-файл является символической ссылкой: {target}"
                )
            snapshot = {
                "target": str(target),
                "existed": target.is_file(),
                "source": None,
                "mode": None,
            }
            if target.exists() and not target.is_file():
                raise RuntimeError(f"Runtime-путь не является обычным файлом: {target}")
            if target.is_file():
                source_name = f"files/{index:06d}"
                shutil.copy2(target, rollback_dir / source_name)
                snapshot["source"] = source_name
                snapshot["mode"] = target.stat().st_mode & 0o777
            rollback_manifest.append(snapshot)
        self._atomic_json_write(rollback_dir / "manifest.json", rollback_manifest)
        return rollback_manifest

    def _publish_manifest(
        self,
        manifest: list[dict],
        staging_dir: Path,
        allowed_external_targets: set[str],
    ) -> None:
        for item in manifest:
            target = Path(item["target"])
            self._validate_target_parent(target, allowed_external_targets)
            source_name = item.get("source")
            if not source_name:
                if target.exists():
                    if not target.is_file() or target.is_symlink():
                        raise RuntimeError(
                            f"Нельзя удалить небезопасный runtime-путь: {target}"
                        )
                    target.unlink()
                continue
            self._atomic_copy(
                staging_dir / source_name,
                target,
                int(item["mode"]),
                allowed_external_targets,
            )

    def _restore_snapshot(
        self,
        manifest: list[dict],
        rollback_dir: Path,
        allowed_external_targets: set[str],
    ) -> None:
        errors = []
        for item in manifest:
            target = Path(item["target"])
            try:
                if item["existed"]:
                    self._atomic_copy(
                        rollback_dir / str(item["source"]),
                        target,
                        int(item["mode"] or 0o600),
                        allowed_external_targets,
                    )
                elif target.exists():
                    if not target.is_file() or target.is_symlink():
                        raise RuntimeError(
                            f"Нельзя удалить небезопасный runtime-путь: {target}"
                        )
                    target.unlink()
            except Exception as exc:  # noqa: BLE001 - restore every remaining target
                errors.append(f"{target}: {exc}")
        if errors:
            raise RuntimeError("; ".join(errors))

    def _atomic_copy(
        self,
        source: Path,
        target: Path,
        mode: int,
        allowed_external_targets: set[str],
    ) -> None:
        self._validate_target_parent(target, allowed_external_targets)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            raise RuntimeError(f"Целевой runtime-файл является ссылкой: {target}")
        fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as output, source.open("rb") as input_file:
                shutil.copyfileobj(input_file, output, length=1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, mode & 0o777)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.remove(temporary)

    def _validate_target_parent(
        self,
        target: Path,
        allowed_external_targets: set[str],
    ) -> None:
        target_path = os.path.abspath(target)
        if target_path in allowed_external_targets:
            return
        real_root = os.path.realpath(self.app_root)
        real_parent = os.path.realpath(target.parent)
        if os.path.commonpath([real_root, real_parent]) != real_root:
            raise RuntimeError(
                f"Родитель runtime-файла выходит за каталог панели: {target}"
            )

    def _run_database_migration(self) -> None:
        python = os.path.join(self.app_root, "venv", "bin", "python")
        init_db = os.path.join(self.app_root, "utils", "init_db.py")
        if not os.path.isfile(python) or not os.path.isfile(init_db):
            raise RuntimeError("Не найден штатный инструмент миграции базы панели")
        migration_env = os.environ.copy()
        migration_env["ADMIN_ANTIZAPRET_SKIP_APP_BOOTSTRAP"] = "1"
        self._run_command(
            [python, init_db, "--ensure-schema"],
            cwd=self.app_root,
            env=migration_env,
            timeout=300,
        )

    def _service_control(self, action: str) -> None:
        self._run_command(["systemctl", action, self.service_name], timeout=90)

    def _require_service_stopped(self) -> None:
        state = self._service_state()
        if state not in {"inactive", "failed"}:
            raise RuntimeError(
                f"Служба {self.service_name} не остановлена (state={state})"
            )

    def _wait_for_service_active(self, timeout: int = 45) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._service_state() == "active":
                return
            time.sleep(1)
        raise RuntimeError(f"Служба {self.service_name} не запустилась за {timeout} с")

    def _service_state(self) -> str:
        result = subprocess.run(
            ["systemctl", "is-active", self.service_name],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        return (result.stdout or "unknown").strip() or "unknown"

    def _require_panel_health(self) -> None:
        env_map = self._load_env_map(Path(self.app_root) / ".env")
        port = str(env_map.get("APP_PORT") or "5050").strip()
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            raise RuntimeError("Некорректный APP_PORT после восстановления")
        scheme = (
            "https" if str(env_map.get("USE_HTTPS") or "").lower() == "true" else "http"
        )
        bind = str(env_map.get("BIND") or "127.0.0.1").strip()
        if bind in {"0.0.0.0", ""}:
            host = "127.0.0.1"
        elif bind == "::":
            host = "[::1]"
        elif ":" in bind:
            host = f"[{bind}]"
        else:
            host = bind
        result = self._run_command(
            [
                "curl",
                "-k",
                "-sS",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "--max-time",
                "10",
                f"{scheme}://{host}:{port}/",
            ],
            timeout=20,
            return_result=True,
        )
        status = (result.stdout or "").strip()
        if status not in {"200", "302"}:
            raise RuntimeError(
                f"Проверка панели после восстановления вернула HTTP {status or 'unknown'}"
            )

    @staticmethod
    def _run_command(
        args: list[str],
        *,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        timeout: int = 60,
        return_result: bool = False,
    ):
        try:
            result = subprocess.run(
                args,
                cwd=cwd,
                env=env,
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise RuntimeError(f"Не удалось выполнить {args[0]}: {exc}") from exc
        if result.returncode != 0:
            message = (result.stderr or result.stdout or "").strip()
            raise RuntimeError(
                message or f"Команда завершилась с кодом {result.returncode}: {args[0]}"
            )
        return result if return_result else None

    @contextmanager
    def _global_restore_lock(self, job_id: str | None = None) -> Iterator[None]:
        lock_path = Path(self.lock_path)
        fd: int | None = None
        acquired = False
        try:
            lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            os.chmod(lock_path, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            acquired = True
            yield
        except Exception as exc:
            if not acquired and job_id:
                with suppress(Exception):
                    self._write_status(
                        job_id,
                        status="failed",
                        stage="lock",
                        progress=100,
                        error=str(exc),
                        rollback_success=True,
                        rollback_errors=[],
                    )
            raise
        finally:
            if fd is not None:
                if acquired:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def _read_request(self, job_id: str) -> dict:
        payload = self._read_request_payload(job_id)
        if not payload.get("archive_path"):
            raise RuntimeError("Некорректный запрос восстановления")
        archive_path = self._resolve_backup_path(str(payload["archive_path"]))
        payload["archive_path"] = archive_path
        return payload

    def _read_status_token(self, job_id: str) -> str:
        payload = self._read_request_payload(job_id)
        status_token = str(payload.get("status_token") or "")
        if not status_token:
            raise RuntimeError("В запросе восстановления отсутствует ключ состояния")
        return status_token

    def _read_request_payload(self, job_id: str) -> dict:
        request_path = self._job_dir(job_id) / "request.json"
        try:
            payload = json.loads(request_path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise FileNotFoundError("Задача восстановления не найдена") from exc
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError("Не удалось прочитать запрос восстановления") from exc
        if not isinstance(payload, dict) or payload.get("job_id") != job_id:
            raise RuntimeError("Некорректный запрос восстановления")
        return payload

    def _write_status(self, job_id: str, **fields) -> None:
        job_id = self._validate_job_id(job_id)
        status_path = self._job_dir(job_id) / "status.json"
        payload = {}
        if status_path.exists():
            try:
                payload = json.loads(status_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                payload = {}
        payload.update(fields)
        payload["job_id"] = job_id
        payload["updated_at"] = self._utc_now()
        payload.setdefault("created_at", payload["updated_at"])
        self._atomic_json_write(status_path, payload)

    @staticmethod
    def _atomic_json_write(path: Path, payload) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(
            prefix=f".{path.name}.", dir=path.parent, text=True
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump(payload, output, ensure_ascii=False, indent=2, sort_keys=True)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.remove(temporary)

    def _ensure_state_root(self) -> None:
        Path(self.state_root).mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state_root, 0o700)

    def _job_dir(self, job_id: str) -> Path:
        return Path(self.state_root) / self._validate_job_id(job_id)

    @staticmethod
    def _validate_job_id(job_id: str) -> str:
        normalized = str(job_id or "").strip().lower()
        if not _JOB_ID_RE.fullmatch(normalized):
            raise ValueError("Некорректный идентификатор восстановления")
        return normalized

    @staticmethod
    def _utc_now() -> str:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
