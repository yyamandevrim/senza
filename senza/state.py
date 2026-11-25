"""Crash-safe JSON state persistence shared by optimizer, firewall bypass and system tunnel."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


def atomic_write_text(path: Path, text: str) -> None:
    """Write text atomically: temp file in the same dir, fsync, then os.replace.

    A crash or power loss mid-write leaves either the old file or the new file, never a truncated one.
    Readers polling the file (e.g. the native hot-reload watcher) never observe a half-written file.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def atomic_write_json(path: Path, payload: Any) -> None:
    """Atomic JSON write so rollback state needed by `senza restore` survives crashes."""
    atomic_write_text(path, json.dumps(payload, indent=2))


def read_json_dict(path: Path) -> dict[str, Any]:
    """Read a JSON object; returns {} when missing, unreadable, corrupt or not a dict."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def remove_file(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        pass
