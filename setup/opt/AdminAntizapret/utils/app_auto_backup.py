#!/usr/bin/env python3
import os
import sys

APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if APP_ROOT not in sys.path:
    sys.path.insert(0, APP_ROOT)

from core.services.backup_job import run_backup_job  # noqa: E402


def main():
    try:
        result = run_backup_job(APP_ROOT, trigger="auto", require_auto_enabled=True)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if result.get("skipped"):
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
