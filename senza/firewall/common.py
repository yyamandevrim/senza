"""Shared constants, paths and the command Runner type for the firewall package."""

from __future__ import annotations

import subprocess
from collections.abc import Callable
from pathlib import Path

from .. import privileged

STATE_DIR = Path.home() / ".local" / "share" / "senza"


BYPASS_STATE_FILE = STATE_DIR / "bypass_state.json"


SYSTEM_TUNNEL_STATE_FILE = STATE_DIR / "system_tunnel.json"


CLEAN_DNS_SERVERS: tuple[str, ...] = ("1.1.1.1", "1.0.0.1")


NO_EXIT_NODE_HINT = (
    "No Tailscale exit node configured — run `senza config set exit-node <tailscale-ip-or-hostname>` "
    "or pass --exit-node"
)


TAILSCALE_DERP_PROBE_HOSTS: tuple[str, ...] = (
    "derp9.tailscale.com",
    "derp1.tailscale.com",
    "derp12.tailscale.com",
)


Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


_privileged_shell_cmd = privileged.shell_cmd
