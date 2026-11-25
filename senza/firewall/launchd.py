"""LaunchAgent install/uninstall for the system-wide tunnel auto-heal watchdog."""

from __future__ import annotations

import os
import plistlib
import shutil
from pathlib import Path
from typing import Any

from .common import STATE_DIR, Runner, _default_runner

LAUNCH_AGENT_LABEL = "com.senza.fortigate-tailscale"


LAUNCH_AGENT_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"


TUNNEL_WATCHDOG_LOG = STATE_DIR / "tunnel_watchdog.log"


def _resolve_senza_cli_path() -> str:
    local_bin = Path.home() / ".local" / "bin" / "senza"
    if local_bin.exists():
        return str(local_bin)
    found = shutil.which("senza")
    if found:
        return found
    repo_bin = Path(__file__).resolve().parent.parent / "bin" / "senza"
    return str(repo_bin)


def install_tunnel_launch_agent(
    exit_node: str | None = None,
    fallback_warp: bool = True,
    runner: Runner = _default_runner,
    plist_path: Path = LAUNCH_AGENT_PATH,
    cli_path: str | None = None,
) -> list[str]:
    """Install a macOS LaunchAgent that keeps the FortiGate -> Tailscale exit-node bypass alive system-wide."""
    # Only pin --exit-node when given explicitly; otherwise `tunnel ensure` re-reads
    # ~/.config/senza/config.json on every run, so `senza config set exit-node` takes effect live.
    target = (exit_node or "").strip() or None
    senza_cli = cli_path or _resolve_senza_cli_path()

    prog_args = [senza_cli, "tunnel", "ensure"]
    if target:
        prog_args += ["--exit-node", target]
    if not fallback_warp:
        prog_args.append("--no-fallback-warp")

    TUNNEL_WATCHDOG_LOG.parent.mkdir(parents=True, exist_ok=True)
    plist_path.parent.mkdir(parents=True, exist_ok=True)

    plist_data: dict[str, Any] = {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": prog_args,
        "RunAtLoad": True,
        "StartInterval": 45,
        "StandardOutPath": str(TUNNEL_WATCHDOG_LOG),
        "StandardErrorPath": str(TUNNEL_WATCHDOG_LOG),
        "EnvironmentVariables": {
            "PATH": f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONUNBUFFERED": "1",
        },
    }
    plist_path.write_bytes(plistlib.dumps(plist_data))

    uid = os.getuid()
    domain = f"gui/{uid}"
    runner(["launchctl", "bootout", domain, str(plist_path)])
    res = runner(["launchctl", "bootstrap", domain, str(plist_path)])

    shown = target or "from ~/.config/senza/config.json"
    notes = [f"Installed macOS LaunchAgent: {plist_path} (target={shown}, interval=45s)"]
    if res.returncode == 0:
        notes.append(f"LaunchAgent '{LAUNCH_AGENT_LABEL}' loaded and active")
    else:
        notes.append(
            f"Warning: launchctl bootstrap returned {res.returncode} ({res.stderr.strip() or res.stdout.strip()})"
        )
    return notes


def uninstall_tunnel_launch_agent(
    runner: Runner = _default_runner,
    plist_path: Path = LAUNCH_AGENT_PATH,
) -> list[str]:
    """Unload and remove the system-wide FortiGate Tailscale LaunchAgent."""
    notes: list[str] = []
    uid = os.getuid()
    domain = f"gui/{uid}"
    if plist_path.exists():
        runner(["launchctl", "bootout", domain, str(plist_path)])
        try:
            plist_path.unlink()
            notes.append(f"Removed LaunchAgent: {plist_path}")
        except OSError as exc:
            notes.append(f"Warning: could not remove {plist_path} ({exc})")
    else:
        notes.append("System tunnel LaunchAgent is not installed")
    return notes


REPATCH_AGENT_LABEL = "com.senza.repatch-watch"
REPATCH_AGENT_PATH = Path.home() / "Library" / "LaunchAgents" / f"{REPATCH_AGENT_LABEL}.plist"
REPATCH_WATCH_PATHS = (
    "/Applications/RemotePlay.app/Contents/Info.plist",
    "/Applications/chiaki-ng.app/Contents/Info.plist",
)


def install_repatch_agent(
    runner: Runner = _default_runner, plist_path: Path = REPATCH_AGENT_PATH, cli_path: str | None = None
) -> list[str]:
    """Re-patch the Remote Play / chiaki-ng bundles as soon as the App Store updates them (launchd WatchPaths)."""
    senza_cli = cli_path or _resolve_senza_cli_path()
    TUNNEL_WATCHDOG_LOG.parent.mkdir(parents=True, exist_ok=True)
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    plist_data: dict[str, Any] = {
        "Label": REPATCH_AGENT_LABEL,
        "ProgramArguments": [senza_cli, "setup", "--if-needed"],
        "WatchPaths": list(REPATCH_WATCH_PATHS),
        "ThrottleInterval": 60,
        "StandardOutPath": str(TUNNEL_WATCHDOG_LOG.with_name("repatch.log")),
        "StandardErrorPath": str(TUNNEL_WATCHDOG_LOG.with_name("repatch.log")),
        "EnvironmentVariables": {
            "PATH": f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        },
    }
    plist_path.write_bytes(plistlib.dumps(plist_data))
    domain = f"gui/{os.getuid()}"
    runner(["launchctl", "bootout", domain, str(plist_path)])
    res = runner(["launchctl", "bootstrap", domain, str(plist_path)])
    if res.returncode == 0:
        return [f"Installed {REPATCH_AGENT_LABEL}: client updates are re-patched automatically"]
    return [f"Warning: launchctl bootstrap returned {res.returncode} ({res.stderr.strip() or res.stdout.strip()})"]


def uninstall_repatch_agent(runner: Runner = _default_runner, plist_path: Path = REPATCH_AGENT_PATH) -> list[str]:
    if not plist_path.exists():
        return ["Re-patch watcher is not installed"]
    runner(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)])
    plist_path.unlink(missing_ok=True)
    return [f"Removed {plist_path}"]
