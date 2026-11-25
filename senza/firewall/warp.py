"""Cloudflare WARP CLI discovery and status."""

from __future__ import annotations

import shutil
from pathlib import Path

from .common import Runner, _default_runner


def find_warp_cli() -> str | None:
    found = shutil.which("warp-cli")
    if found:
        return found
    app_cli = Path("/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli")
    if app_cli.is_file():
        return str(app_cli)
    return None


def _warp_is_connected(runner: Runner = _default_runner) -> bool:
    warp = find_warp_cli()
    if not warp:
        return False
    st = runner([warp, "status"])
    return "Status update: Connected" in st.stdout or (
        "Connected" in st.stdout and "Connecting" not in st.stdout and "Disconnected" not in st.stdout
    )
