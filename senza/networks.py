"""Per-network profiles: recognise the network you're on and apply its saved launch settings.

The fingerprint is the MAC address of the physical interface's router (no Location permission needed, unlike
the SSID on modern macOS, and stable while a VPN/Tailscale owns the default route). Profiles live in
~/.config/senza/config.json under `networks.<id>`.
"""

from __future__ import annotations

import hashlib
import re
import subprocess
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Any

from . import config as user_config

Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]

PHYSICAL_PREFIXES = ("en",)
PROFILE_KEYS = ("name", "bypass", "privileged", "preset", "exit_node", "warp_bootstrap", "fallback_warp")
BYPASS_CHOICES = ("off", "auto", "dns", "warp", "tailscale")


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


@dataclass
class NetworkId:
    id: str
    interface: str
    router_ip: str
    router_mac: str
    name: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


_MAC_RE = re.compile(r"RouterHardwareAddress=([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5})")


def _normalize_mac(mac: str) -> str:
    return ":".join(part.zfill(2) for part in mac.lower().split(":"))


def network_id_for(router_mac: str) -> str:
    return hashlib.sha256(_normalize_mac(router_mac).encode()).hexdigest()[:12]


def _scutil(command: str, runner: Runner) -> str:
    # scutil reads commands from stdin; the Runner only takes argv, so go through sh with a here-string.
    return runner(["/bin/sh", "-c", f"printf '%s\\n' {command!r} | /usr/sbin/scutil"]).stdout or ""


def _ipv4_services(runner: Runner) -> list[dict[str, str]]:
    """IPv4 state of every active network service from the SystemConfiguration dynamic store.

    macOS itself publishes `NetworkSignature` (router IP + router hardware address) here; unlike the ARP table
    or the SSID it is readable without Local Network / Location permission.
    """
    listing = _scutil("list State:/Network/Service/[^/]+/IPv4", runner)
    services = []
    for key in re.findall(r"(State:/Network/Service/[0-9A-Fa-f-]+/IPv4)", listing):
        info: dict[str, str] = {}
        for line in _scutil(f"show {key}", runner).splitlines():
            m = re.match(r"\s*(\w+)\s*:\s*(.*)$", line)
            if m:
                info[m.group(1)] = m.group(2).strip()
        services.append(info)
    return services


def current_network(runner: Runner = _default_runner) -> NetworkId | None:
    """Fingerprint the physical LAN by its router's MAC (from macOS' own NetworkSignature)."""
    services = _ipv4_services(runner)
    services.sort(key=lambda svc: svc.get("InterfaceName", "~"))  # en0 before en1 before others
    for svc in services:
        iface = svc.get("InterfaceName", "")
        if not iface.startswith(PHYSICAL_PREFIXES):
            continue
        m = _MAC_RE.search(svc.get("NetworkSignature", ""))
        if not m:
            continue
        mac = _normalize_mac(m.group(1))
        nid = network_id_for(mac)
        profile = get_profile(nid)
        return NetworkId(
            id=nid,
            interface=iface,
            router_ip=svc.get("Router", ""),
            router_mac=mac,
            name=str(profile.get("name")) if profile.get("name") else None,
        )
    return None


def all_profiles() -> dict[str, dict[str, Any]]:
    nets = user_config.get_value("networks")
    return {k: v for k, v in nets.items() if isinstance(v, dict)} if isinstance(nets, dict) else {}


def get_profile(network_id: str) -> dict[str, Any]:
    return all_profiles().get(network_id, {})


def save_profile(net: NetworkId, **fields: Any) -> dict[str, Any]:
    """Merge the given fields into this network's profile (None values are ignored)."""
    profile = dict(get_profile(net.id))
    for key, value in fields.items():
        if key not in PROFILE_KEYS:
            raise ValueError(f"unknown network profile field: {key}")
        if value is not None:
            profile[key] = value
    if (
        "bypass" in profile
        and profile["bypass"] not in BYPASS_CHOICES
        and not str(profile["bypass"]).startswith("vpn:")
    ):
        raise ValueError(f"bypass must be one of {', '.join(BYPASS_CHOICES)} or vpn:<Name>")
    profile.setdefault("name", net.name or f"Ağ {net.id[:6]}")
    profile["router_ip"] = net.router_ip
    user_config.set_value(f"networks.{net.id}", profile)
    return profile


def forget_profile(network_id: str) -> bool:
    if network_id not in all_profiles():
        return False
    user_config.unset_value(f"networks.{network_id}")
    return True


@dataclass
class AppliedProfile:
    network: NetworkId
    profile: dict[str, Any]
    changes: list[str]


def apply_to_start_args(args: Any, explicit: set[str], runner: Runner = _default_runner) -> AppliedProfile | None:
    """Fill `senza start` options the user did not pass explicitly from the current network's profile."""
    net = current_network(runner)
    if net is None:
        return None
    profile = get_profile(net.id)
    if not profile:
        return AppliedProfile(net, {}, [])
    changes: list[str] = []

    bypass = profile.get("bypass")
    if bypass and "bypass_firewall" not in explicit:
        args.bypass_firewall = None if bypass == "off" else bypass
        changes.append(f"bypass={bypass}")
    if "privileged" in profile and "privileged" not in explicit:
        args.privileged = bool(profile["privileged"])
        changes.append(f"privileged={'on' if args.privileged else 'off'}")
    if profile.get("preset") and "preset" not in explicit:
        args.preset = profile["preset"]
        changes.append(f"preset={args.preset}")
    if profile.get("exit_node") and "exit_node" not in explicit:
        args.exit_node = profile["exit_node"]
        changes.append(f"exit_node={args.exit_node}")
    if profile.get("warp_bootstrap") and "warp_bootstrap" not in explicit:
        args.warp_bootstrap = profile["warp_bootstrap"]
        changes.append(f"warp_bootstrap={args.warp_bootstrap}")
    if "fallback_warp" in profile and "fallback_warp" not in explicit:
        args.fallback_warp = bool(profile["fallback_warp"])
        changes.append(f"fallback_warp={'on' if args.fallback_warp else 'off'}")
    return AppliedProfile(net, profile, changes)
