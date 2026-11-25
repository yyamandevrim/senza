"""Tailscale CLI discovery, status parsing, exit-node discovery and readiness inspection."""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from ..config import configured_exit_node
from .common import NO_EXIT_NODE_HINT, Runner, _default_runner


def _tailscale_cli_candidates() -> list[str]:
    """Return candidate Tailscale binaries with macOS Tailscale.app prioritized over Homebrew CLI."""
    cands: list[str] = []
    app_cli = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    if app_cli.is_file():
        cands.append(str(app_cli))
    which_cli = shutil.which("tailscale")
    if which_cli and which_cli not in cands:
        cands.append(which_cli)
    for extra in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"):
        if Path(extra).is_file() and extra not in cands:
            cands.append(extra)
    return cands


def _tailscale_status_json(ts_cli: str, runner: Runner = _default_runner) -> dict[str, Any] | None:
    res = runner([ts_cli, "status", "--json"])
    raw = (res.stdout or "").strip()
    if not raw.startswith("{"):
        return None
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if isinstance(data, dict) and "BackendState" in data:
        return data
    return None


def find_tailscale_cli(runner: Runner | None = None) -> str | None:
    """Find the Tailscale CLI that talks to the active macOS backend (GUI App Network Extension or tailscaled)."""
    cands = _tailscale_cli_candidates()
    if not cands:
        return None
    if len(cands) == 1 or runner is None:
        return cands[0]

    # Prefer the candidate that can actually speak to a live Tailscale backend (even if Stopped)
    for cand in cands:
        if _tailscale_status_json(cand, runner) is not None:
            return cand
    return cands[0]


def _tailscale_find_peer(data: dict[str, Any], target: str) -> dict[str, Any] | None:
    needle = target.strip().lower().rstrip(".")
    if not needle:
        return None
    peers = data.get("Peer") or {}
    for peer in peers.values():
        if not isinstance(peer, dict):
            continue
        ips = [str(ip).strip().lower() for ip in (peer.get("TailscaleIPs") or [])]
        if needle in ips:
            return peer
        host = str(peer.get("HostName") or "").strip().lower()
        dns = str(peer.get("DNSName") or "").strip().lower().rstrip(".")
        short_dns = dns.split(".", 1)[0] if dns else ""
        if needle in (host, dns, short_dns):
            return peer
    return None


def _tailscale_active_exit_node(data: dict[str, Any]) -> str | None:
    ex_status = data.get("ExitNodeStatus")
    if isinstance(ex_status, dict):
        ips = ex_status.get("TailscaleIPs") or []
        if ips:
            return str(ips[0]).split("/", 1)[0]
    peers = data.get("Peer") or {}
    for peer in peers.values():
        if isinstance(peer, dict) and peer.get("ExitNode"):
            ips = peer.get("TailscaleIPs") or []
            if ips:
                return str(ips[0])
    return None


def _tailscale_list_exit_nodes(data: dict[str, Any]) -> list[str]:
    nodes: list[str] = []
    peers = data.get("Peer") or {}
    for peer in peers.values():
        if isinstance(peer, dict) and peer.get("ExitNodeOption") and peer.get("Online"):
            ips = peer.get("TailscaleIPs") or []
            if ips:
                nodes.append(str(ips[0]))
            elif peer.get("DNSName"):
                nodes.append(str(peer["DNSName"]).rstrip("."))
    return nodes


def _tailscale_discover_exit_node(ts_cli: str, runner: Runner) -> str | None:
    data = _tailscale_status_json(ts_cli, runner)
    if not data:
        return None
    nodes = _tailscale_list_exit_nodes(data)
    preferred = configured_exit_node()
    if preferred and preferred in nodes:
        return preferred
    return nodes[0] if nodes else None


def resolve_exit_node(
    explicit: str | None = None,
    runner: Runner = _default_runner,
    saved: str | None = None,
    discover: bool = True,
) -> str | None:
    """explicit > $SENZA_EXIT_NODE > config file > saved tunnel state > first exit-node peer in tailnet."""
    node = configured_exit_node(explicit) or ((saved or "").strip() or None)
    if node or not discover:
        return node
    ts_cli = find_tailscale_cli(runner)
    return _tailscale_discover_exit_node(ts_cli, runner) if ts_cli else None


def inspect_tailscale_exit_node(
    ts_cli: str,
    target: str | None = None,
    runner: Runner = _default_runner,
) -> dict[str, Any]:
    """Return structured readiness status for Tailscale and a specific exit node."""
    info: dict[str, Any] = {
        "backend_state": "NotRunning",
        "target": target,
        "ready": False,
        "peer_found": False,
        "peer_online": False,
        "exit_node_option": False,
        "peer_name": None,
        "active_exit_node": None,
        "available_exit_nodes": [],
        "status_text": "Tailscale app not running",
    }
    data = _tailscale_status_json(ts_cli, runner)
    if not data:
        return info

    state = str(data.get("BackendState") or "Unknown")
    info["backend_state"] = state
    info["active_exit_node"] = _tailscale_active_exit_node(data)
    info["available_exit_nodes"] = _tailscale_list_exit_nodes(data)

    if state == "NeedsLogin":
        info["status_text"] = "Tailscale needs login (open Tailscale app)"
        return info
    if state == "Stopped":
        info["status_text"] = (
            f"Tailscale stopped (will auto-start & use {target} on Launch)"
            if target
            else f"Tailscale stopped · {NO_EXIT_NODE_HINT}"
        )
        return info
    if state != "Running":
        info["status_text"] = f"Tailscale state: {state}"
        return info
    if not target:
        avail = info["available_exit_nodes"]
        info["status_text"] = NO_EXIT_NODE_HINT + (f" (available: {', '.join(avail)})" if avail else "")
        return info

    peer = _tailscale_find_peer(data, target)
    if not peer:
        info["status_text"] = f"{target} not in tailnet yet (waiting for share/ACL access)"
        return info

    info["peer_found"] = True
    info["peer_online"] = bool(peer.get("Online"))
    info["exit_node_option"] = bool(peer.get("ExitNodeOption"))
    peer_name = str(peer.get("HostName") or str(peer.get("DNSName") or "").rstrip(".") or target)
    info["peer_name"] = peer_name

    if not info["exit_node_option"]:
        info["status_text"] = f"{target} ({peer_name}) visible, but Exit Node permission not enabled yet"
    elif not info["peer_online"]:
        info["status_text"] = f"{target} ({peer_name}) is offline"
    else:
        info["ready"] = True
        active_tag = " · ACTIVE" if info["active_exit_node"] == target else ""
        info["status_text"] = f"{target} ({peer_name}) ONLINE & READY{active_tag}"
    return info
