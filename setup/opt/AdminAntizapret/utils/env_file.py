# Один механизм записи .env для веб-панели, CLI и shell-менеджера.
import argparse
from pathlib import Path
import re
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from utils.file_io import atomic_write_text, file_lock

_KEY_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ASSIGNMENT_PATTERN = re.compile(r"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=")


def update_env_file(path, updates=None, *, only_if_missing=False, unset_keys=()):
    values = {key: str(value) for key, value in (updates or {}).items()}
    removals = set(unset_keys)
    for key in values.keys() | removals:
        if not _KEY_PATTERN.fullmatch(key):
            raise ValueError("Некорректное имя параметра .env")
    if any("\n" in value or "\r" in value or "\x00" in value for value in values.values()):
        raise ValueError("Значение .env должно занимать одну строку")

    with file_lock(path) as target:
        try:
            with target.open("r", encoding="utf-8") as source:
                lines = source.readlines()
        except FileNotFoundError:
            lines = []

        found = set()
        new_lines = []
        for line in lines:
            assignment = _ASSIGNMENT_PATTERN.match(line)
            key = assignment[1] if assignment else None
            if key in removals:
                continue
            if key in values:
                found.add(key)
                new_lines.append(line if only_if_missing else f"{key}={values[key]}\n")
            else:
                new_lines.append(line)

        for key, value in values.items():
            if key not in found:
                if new_lines and not new_lines[-1].endswith("\n"):
                    new_lines[-1] += "\n"
                new_lines.append(f"{key}={value}\n")

        if new_lines != lines:
            atomic_write_text(target, "".join(new_lines))


def main():
    parser = argparse.ArgumentParser(description="Атомарное изменение параметра .env")
    parser.add_argument("path")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--set", metavar="KEY")
    action.add_argument("--default", metavar="KEY")
    action.add_argument("--unset", metavar="KEY")
    args = parser.parse_args()
    if args.unset is not None:
        update_env_file(args.path, unset_keys=(args.unset,))
    else:
        key = args.set if args.set is not None else args.default
        # Значение, в том числе SECRET_KEY, не попадает в argv процесса.
        update_env_file(args.path, {key: sys.stdin.read()}, only_if_missing=args.default is not None)


if __name__ == "__main__":
    main()
