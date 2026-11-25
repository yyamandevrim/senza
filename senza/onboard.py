"""First-run readiness checklist shared by `senza onboard` and Senza.app's setup screen."""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from . import config as user_config
from . import networks, privileged
from .app_bridge import BUILD_CHIAKI_DYLIB, BUILD_SONY_DYLIB, bundle_status, find_chiaki_app, find_sony_app
from .firewall import find_tailscale_cli, find_warp_cli


@dataclass
class Check:
    id: str
    title: str
    ok: bool
    required: bool
    detail: str = ""
    fix: str = ""  # one shell command (also what the GUI's "Fix" button runs) or a short instruction


def _clt_installed() -> bool:
    try:
        return subprocess.run(["xcode-select", "-p"], capture_output=True, check=False).returncode == 0
    except OSError:
        return False


def run_checks() -> list[Check]:
    sony = find_sony_app()
    chiaki = find_chiaki_app()
    checks: list[Check] = []

    checks.append(
        Check(
            "clt",
            "Xcode Command Line Tools",
            _clt_installed(),
            True,
            "Needed to build the DualSense bridges",
            "xcode-select --install",
        )
    )
    built = BUILD_SONY_DYLIB.is_file() and BUILD_CHIAKI_DYLIB.is_file()
    checks.append(
        Check(
            "bridges",
            "DualSense bridges built",
            built,
            True,
            "libsenza_sony.dylib and libsenza_chiaki.dylib",
            "senza setup",
        )
    )
    client_detail = ", ".join(x for x in (sony and "PS Remote Play", chiaki and "chiaki-ng") if x) or "none found"
    checks.append(
        Check(
            "client",
            "Remote Play client installed",
            bool(sony or chiaki),
            True,
            client_detail,
            "Install PS Remote Play from remoteplay.dl.playstation.net or chiaki-ng",
        )
    )
    statuses = {c: bundle_status(app, c) for c, app in (("sony", sony), ("chiaki", chiaki)) if app}
    stale = [c for c, st in statuses.items() if st != "ready"]
    checks.append(
        Check(
            "bundle",
            "Client prepared for the bridge",
            bool(statuses) and not stale,
            True,
            "Up to date" if statuses and not stale else (f"Needs patching: {', '.join(stale)}" if stale else ""),
            "senza setup --if-needed",
        )
    )
    on_path = shutil.which("senza") is not None or (Path.home() / ".local/bin/senza").exists()
    checks.append(
        Check(
            "cli",
            "senza command installed",
            on_path,
            True,
            "~/.local/bin/senza",
            "make install  (then add ~/.local/bin to PATH)",
        )
    )

    helper = privileged.helper_status()
    checks.append(
        Check(
            "helper",
            "Passwordless helper",
            bool(helper["ready"]),
            False,
            "Skips the Touch ID prompt each session",
            "senza helper install --gui-sudo",
        )
    )
    if find_tailscale_cli() or find_warp_cli():
        node = user_config.configured_exit_node()
        checks.append(
            Check(
                "exit_node",
                "Tailscale exit node",
                bool(node),
                False,
                node or "Only needed when a firewall blocks Remote Play",
                "senza config set exit-node <ip>",
            )
        )
    net = networks.current_network()
    if net is not None:
        saved = bool(networks.get_profile(net.id))
        checks.append(
            Check(
                "network",
                "This network has a profile",
                saved,
                False,
                net.name or f"router {net.router_ip}",
                "senza network save --name <Name> --bypass off --privileged on",
            )
        )
    return checks


def summary(checks: list[Check]) -> dict[str, Any]:
    missing_required = [c.id for c in checks if c.required and not c.ok]
    return {
        "ready": not missing_required,
        "missing_required": missing_required,
        "checks": [asdict(c) for c in checks],
        "first_run": not os.path.exists(user_config.config_path()),
    }
