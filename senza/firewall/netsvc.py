"""macOS network service helpers: active service, DNS servers, VPN services, DNS changes."""

from __future__ import annotations

import re
import shlex

from .. import privileged
from .common import Runner, _default_runner, _privileged_shell_cmd


def list_macos_vpns(runner: Runner = _default_runner) -> list[str]:
    res = runner(["scutil", "--nc", "list"])
    if res.returncode != 0:
        return []
    names: list[str] = []
    for line in res.stdout.splitlines():
        m = re.search(r'"([^"]+)"', line)
        if m:
            names.append(m.group(1))
    return names


def detect_active_network_service(runner: Runner = _default_runner) -> str | None:
    """Resolve the active default-route interface (e.g. en0) to its macOS networksetup service name (e.g. Wi-Fi)."""
    route_res = runner(["route", "-n", "get", "default"])
    iface_match = re.search(r"interface:\s+(\S+)", route_res.stdout) if route_res.returncode == 0 else None
    target_iface = iface_match.group(1) if iface_match else "en0"

    order_res = runner(["networksetup", "-listnetworkserviceorder"])
    if order_res.returncode != 0:
        return "Wi-Fi" if target_iface == "en0" else None

    current_service: str | None = None
    for line in order_res.stdout.splitlines():
        svc_match = re.match(r"^\(\d+\)\s+(.+)$", line.strip())
        if svc_match:
            current_service = svc_match.group(1).strip()
            continue
        if current_service and f"Device: {target_iface})" in line:
            return current_service

    return "Wi-Fi" if target_iface == "en0" else None


def get_dns_servers(service: str, runner: Runner = _default_runner) -> list[str]:
    res = runner(["networksetup", "-getdnsservers", service])
    if res.returncode != 0:
        return []
    lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]
    if not lines or any("aren't any" in ln.lower() for ln in lines):
        return []
    return lines


def _dns_cmd(service: str, servers: list[str], gui_sudo: bool, runner: Runner) -> list[str]:
    """Set DNS servers (["empty"] clears) + flush caches; passwordless via senza-priv when installed."""
    if privileged.helper_ready(runner):
        return privileged.helper_cmd("dns-set", service, *servers)
    script = (
        f"networksetup -setdnsservers {shlex.quote(service)} {' '.join(shlex.quote(x) for x in servers)} && "
        f"dscacheutil -flushcache && "
        f"(killall -HUP mDNSResponder 2>/dev/null || true)"
    )
    return _privileged_shell_cmd(script, gui_sudo)
