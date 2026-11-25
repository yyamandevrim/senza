"""macOS user notifications (used by the headless tunnel watchdog, which has no other way to tell you)."""

from __future__ import annotations

import os
import subprocess
from collections.abc import Callable

Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def _applescript_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(title: str, body: str, runner: Runner = _default_runner) -> bool:
    """Post a Notification Center banner. Disabled with SENZA_NO_NOTIFY=1. Never raises."""
    if os.environ.get("SENZA_NO_NOTIFY") == "1":
        return False
    script = f"display notification {_applescript_string(body)} with title {_applescript_string(title)}"
    try:
        return runner(["osascript", "-e", script]).returncode == 0
    except OSError:
        return False
