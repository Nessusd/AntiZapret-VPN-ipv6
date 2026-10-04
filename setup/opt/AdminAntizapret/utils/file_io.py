# Атомарная публикация файлов и общий межпроцессный lock для их изменения.
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import stat
import tempfile


@contextmanager
def file_lock(path):
    target = Path(path).resolve()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Lock находится рядом, а не в заменяемом файле: rename не меняет его inode.
    fd = os.open(str(target) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield target
    finally:
        os.close(fd)


def atomic_write_text(path, content, *, mode=0o600):
    target = Path(path).resolve()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        previous = target.stat()
    except FileNotFoundError:
        previous = None

    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(content)
            output.flush()
            if previous is not None:
                current = os.fstat(output.fileno())
                if (current.st_uid, current.st_gid) != (previous.st_uid, previous.st_gid):
                    os.fchown(output.fileno(), previous.st_uid, previous.st_gid)
                os.fchmod(output.fileno(), stat.S_IMODE(previous.st_mode))
            else:
                os.fchmod(output.fileno(), mode)
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
