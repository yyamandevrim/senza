"""Persistent system-wide Tailscale exit-node tunnel (on/off/status/ensure)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .. import notify as _notify
from ..config import configured_exit_nodes
from ..state import atomic_write_json, read_json_dict
from . import bypass as _bypass
from . import probes as _probes
from . import tailscale as _tailscale
from . import warp as _warp
from .common import NO_EXIT_NODE_HINT, SYSTEM_TUNNEL_STATE_FILE, Runner, _default_runner
from .launchd import LAUNCH_AGENT_LABEL, LAUNCH_AGENT_PATH


def _read_json_file(path: Path) -> dict[str, Any]:
    return read_json_dict(path)


def system_tunnel_status(
    exit_node: str | None = None,
    runner: Runner = _default_runner,
    state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
    plist_path: Path = LAUNCH_AGENT_PATH,
    probe_network_checks: bool = False,
) -> dict[str, Any]:
    """Inspect current system-wide FortiGate/Tailscale bypass tunnel & LaunchAgent status."""
    saved = _read_json_file(state_file)
    target = _tailscale.resolve_exit_node(exit_node, runner, saved=str(saved.get("target_exit_node") or ""))

    ts_cli = _tailscale.find_tailscale_cli(runner)
    ts_info = (
        _tailscale.inspect_tailscale_exit_node(ts_cli, target=target, runner=runner)
        if ts_cli
        else {
            "backend_state": "NotInstalled",
            "ready": False,
            "active_exit_node": None,
            "available_exit_nodes": [],
            "status_text": "Tailscale CLI not installed",
        }
    )
    warp_connected = _warp._warp_is_connected(runner)

    active_exit = ts_info.get("active_exit_node")
    ts_running = ts_info.get("backend_state") == "Running"
    if ts_running and active_exit:
        active_backend = "tailscale"
    elif warp_connected:
        active_backend = "warp"
    else:
        active_backend = "none"

    result: dict[str, Any] = {
        "managed": state_file.exists(),
        "active": active_backend != "none",
        "active_backend": active_backend,
        "target_exit_node": target,
        "tailscale_state": ts_info.get("backend_state"),
        "tailscale_active_exit_node": active_exit,
        "tailscale_exit_node_ready": bool(ts_info.get("ready")),
        "tailscale_exit_node_status": str(ts_info.get("status_text") or ""),
        "warp_connected": warp_connected,
        "service_installed": plist_path.exists(),
        "service_label": LAUNCH_AGENT_LABEL,
        "service_plist": str(plist_path),
    }

    if probe_network_checks:
        cp_ok, cp_detail = _probes.probe_tailscale_controlplane(timeout=2.5)
        derp_ok, derp_nodes = _probes.probe_tailscale_derp(timeout=2.0)
        result["controlplane_ok"] = cp_ok
        result["controlplane_detail"] = cp_detail
        result["derp_ok"] = derp_ok
        result["derp_nodes"] = derp_nodes

    return result


def system_tunnel_up(
    exit_node: str | None = None,
    warp_bootstrap: str = "auto",
    fallback_warp: bool = True,
    dry_run: bool = False,
    runner: Runner = _default_runner,
    state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
) -> list[str]:
    """Activate persistent system-wide Tailscale exit-node bypass (with FortiGate WARP bootstrap & fallback)."""
    prev_saved = _read_json_file(state_file)
    target = _tailscale.resolve_exit_node(exit_node, runner, saved=str(prev_saved.get("target_exit_node") or ""))
    if not target:
        return [f"Warning: {NO_EXIT_NODE_HINT}."]

    # Pin the node only when the user asked for one; with a configured candidate list the bypass
    # picks the fastest online node itself.
    pinned = exit_node or (target if len(configured_exit_nodes()) < 2 else None)
    fb = _bypass.FirewallBypass(
        mode="tailscale",
        exit_node=pinned,
        dry_run=dry_run,
        runner=runner,
        state_file=state_file,
        warp_bootstrap=warp_bootstrap,
        fallback_warp=fallback_warp,
        persistent=True,
    )
    notes = fb.enter()

    if dry_run:
        return notes

    # If Tailscale exit-node became active while a previous WARP fallback was still up, disconnect WARP now
    # so macOS routes cleanly through the Tailscale exit node instead of double-tunneling.
    if fb._tailscale_exit_active and not fb._warp_connected_by_us and _warp._warp_is_connected(runner):
        warp = _warp.find_warp_cli()
        if warp:
            res = runner([warp, "disconnect"])
            if res.returncode == 0:
                notes.append("Disconnected previous WARP fallback (Tailscale exit-node is now primary)")

    active_backend = "tailscale" if fb._tailscale_exit_active else ("warp" if fb._warp_connected_by_us else "none")

    merged = {
        "persistent": True,
        "target_exit_node": fb.selected_exit_node or target,
        "active_backend": active_backend,
        "warp_bootstrap": warp_bootstrap,
        "fallback_warp": fallback_warp,
        "dns_service": fb._dns_service or prev_saved.get("dns_service"),
        "prev_dns": fb._prev_dns if fb._dns_service else prev_saved.get("prev_dns"),
        "warp_connected_by_us": bool(
            fb._warp_connected_by_us or (active_backend == "warp" and prev_saved.get("warp_connected_by_us"))
        ),
        "warp_cli": fb._warp_cli or prev_saved.get("warp_cli"),
        "tailscale_started_by_us": bool(fb._tailscale_started_by_us or prev_saved.get("tailscale_started_by_us")),
        "tailscale_exit_set_by_us": bool(fb._tailscale_exit_set_by_us or prev_saved.get("tailscale_exit_set_by_us")),
        "prev_tailscale_exit_node": (
            prev_saved.get("prev_tailscale_exit_node")
            if "prev_tailscale_exit_node" in prev_saved
            else fb._prev_tailscale_exit_node
        ),
        "tailscale_cli": fb._tailscale_cli or prev_saved.get("tailscale_cli"),
        "vpn_started_by_us": fb._vpn_started_by_us or prev_saved.get("vpn_started_by_us"),
    }
    atomic_write_json(state_file, merged)
    return notes


def system_tunnel_down(
    runner: Runner = _default_runner,
    state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
) -> list[str]:
    """Tear down persistent system-wide bypass tunnel and restore prior Tailscale/WARP state."""
    if state_file.exists():
        notes = _bypass.restore_firewall_bypass(gui_sudo=False, runner=runner, state_file=state_file)
        if not notes:
            notes.append("System tunnel state cleared (already inactive)")
        return notes

    notes: list[str] = []
    ts_cli = _tailscale.find_tailscale_cli(runner)
    if ts_cli:
        data = _tailscale._tailscale_status_json(ts_cli, runner)
        if data and _tailscale._tailscale_active_exit_node(data):
            res = runner([ts_cli, "set", "--exit-node="])
            if res.returncode == 0:
                notes.append("Cleared Tailscale exit-node routing")

    if _warp._warp_is_connected(runner):
        warp = _warp.find_warp_cli()
        if warp:
            res = runner([warp, "disconnect"])
            if res.returncode == 0:
                notes.append("Disconnected Cloudflare WARP")

    if not notes:
        notes.append("System tunnel is already off")
    return notes


def system_tunnel_ensure(
    exit_node: str | None = None,
    warp_bootstrap: str = "auto",
    fallback_warp: bool = True,
    runner: Runner = _default_runner,
    state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
) -> list[str]:
    """Idempotent health-check & auto-heal (designed for the macOS LaunchAgent watchdog)."""
    saved = _read_json_file(state_file)
    target = _tailscale.resolve_exit_node(exit_node, runner, saved=str(saved.get("target_exit_node") or ""))
    if not target:
        return [f"Warning: {NO_EXIT_NODE_HINT}."]

    ts_cli = _tailscale.find_tailscale_cli(runner)
    if ts_cli:
        data = _tailscale._tailscale_status_json(ts_cli, runner)
        if data and str(data.get("BackendState") or "") == "Running":
            active = _tailscale._tailscale_active_exit_node(data)
            ex_st = data.get("ExitNodeStatus")
            ex_online = isinstance(ex_st, dict) and bool(ex_st.get("Online"))
            candidates = [exit_node] if exit_node else (configured_exit_nodes() or [target])
            for cand in candidates:
                peer = _tailscale._tailscale_find_peer(data, cand)
                peer_ips = {str(ip).strip().lower() for ip in (peer.get("TailscaleIPs") or [])} if peer else set()
                if active and ex_online and (active.lower() == cand.lower() or active.lower() in peer_ips):
                    return [f"OK: Tailscale exit node {cand} already online & healthy"]

    prev_backend = saved.get("active_backend")
    notes = system_tunnel_up(
        exit_node=exit_node,
        warp_bootstrap=warp_bootstrap,
        fallback_warp=fallback_warp,
        dry_run=False,
        runner=runner,
        state_file=state_file,
    )
    new_backend = _read_json_file(state_file).get("active_backend")
    message = _backend_change_message(prev_backend, new_backend, target)
    if message and _notify.notify("Senza tunnel", message, runner=runner):
        notes.append(f"Notified: {message}")
    return notes


def _backend_change_message(prev: Any, new: Any, target: str) -> str | None:
    """User-facing text for a backend switch, or None when nothing changed / first run."""
    if not prev or prev == new:
        return None
    if new == "tailscale":
        return f"Back on Tailscale exit node {target}"
    if new == "warp":
        return "Tailscale exit node unreachable. Switched to Cloudflare WARP"
    return "Bypass tunnel is down. Retrying every 45 s"
