"""Firewall & PSN bypass helpers (Clean DNS 1.1.1.1, Cloudflare WARP, Tailscale exit-node, macOS VPN)."""

from __future__ import annotations

import atexit
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .config import configured_exit_node
from .state import atomic_write_json, read_json_dict, remove_file

STATE_DIR = Path.home() / ".local" / "share" / "senza"
BYPASS_STATE_FILE = STATE_DIR / "bypass_state.json"
SYSTEM_TUNNEL_STATE_FILE = STATE_DIR / "system_tunnel.json"
TUNNEL_WATCHDOG_LOG = STATE_DIR / "tunnel_watchdog.log"

LAUNCH_AGENT_LABEL = "com.senza.fortigate-tailscale"
LAUNCH_AGENT_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"

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


def _privileged_shell_cmd(script: str, gui_sudo: bool) -> list[str]:
    if gui_sudo:
        escaped = script.replace("\\", "\\\\").replace('"', '\\"')
        return [
            "osascript",
            "-e",
            f'do shell script "{escaped}" with administrator privileges',
        ]
    return ["sudo", "sh", "-c", script]


def find_warp_cli() -> str | None:
    found = shutil.which("warp-cli")
    if found:
        return found
    app_cli = Path("/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli")
    if app_cli.is_file():
        return str(app_cli)
    return None


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
            f"Tailscale stopped (will auto-start & use {target} on Launch)" if target else f"Tailscale stopped · {NO_EXIT_NODE_HINT}"
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


@dataclass
class FirewallProbeReport:
    psn_sys_tls_ok: bool = False
    psn_cf_tls_ok: bool = False
    udp_high_port_ok: bool = False
    udp_3478_ok: bool = False
    warp_available: bool = False
    tailscale_available: bool = False
    tailscale_running: bool = False
    tailscale_state: str = "not_installed"
    tailscale_exit_node: str | None = None
    tailscale_exit_node_ready: bool = False
    tailscale_exit_node_status: str = ""
    tailscale_available_exit_nodes: list[str] = field(default_factory=list)
    tailscale_controlplane_ok: bool = False
    tailscale_derp_ok: bool = False
    tailscale_derp_nodes: list[str] = field(default_factory=list)
    fortigate_warp_bootstrap_needed: bool = False
    macos_vpns: list[str] = field(default_factory=list)
    diagnosis: str = "unknown"


def probe_tailscale_controlplane(timeout: float = 3.0) -> tuple[bool, str]:
    """Verify real HTTPS access to controlplane.tailscale.com (detects FortiGate DNS/SNI/DPI blocks)."""
    url = "https://controlplane.tailscale.com/key?v=109"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Senza-Probe/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(512).decode("utf-8", "replace")
            if resp.status == 200 and ("publicKey" in body or "legacyPublicKey" in body):
                return True, "ok (HTTP 200)"
            return False, f"unexpected response (status={resp.status}, possible firewall block page)"
    except Exception as exc:
        return False, f"blocked ({type(exc).__name__}: {exc})"


def probe_tailscale_derp(timeout: float = 2.5) -> tuple[bool, list[str]]:
    """Check whether Tailscale DERP TLS/TCP-443 relays are reachable (bypasses FortiGate UDP/WireGuard DPI)."""
    reachable: list[str] = []
    for host in TAILSCALE_DERP_PROBE_HOSTS:
        try:
            req = urllib.request.Request(f"https://{host}/", headers={"User-Agent": "Senza-Probe/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    reachable.append(host.split(".", 1)[0])
        except Exception:
            continue
    return bool(reachable), reachable


def probe_egress_via_tunnel(timeout: float = 4.0) -> tuple[bool, str]:
    """Verify real HTTPS egress through the active tunnel and extract the external IP if available."""
    try:
        req = urllib.request.Request("https://1.1.1.1/cdn-cgi/trace", headers={"User-Agent": "Senza-Probe/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(1024).decode("utf-8", "replace")
            if resp.status == 200:
                m = re.search(r"^ip=(\S+)$", body, re.MULTILINE)
                loc = re.search(r"^loc=(\S+)$", body, re.MULTILINE)
                if m:
                    loc_tag = f" ({loc.group(1)})" if loc else ""
                    return True, f"egress IP {m.group(1)}{loc_tag}"
                return True, "HTTPS egress verified"
    except Exception:
        pass

    # Fallback check directly to PSN TLS if 1.1.1.1 trace is unreachable
    if _tls_check_ip("m.np.playstation.com", "m.np.playstation.com", timeout=timeout):
        return True, "PSN TLS reachable"
    return False, "egress check failed (firewall may be blocking tunnel traffic)"


def _tls_check_ip(ip: str, hostname: str, timeout: float = 2.5) -> bool:
    try:
        sock = socket.create_connection((ip, 443), timeout=timeout)
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(sock, server_hostname=hostname):
            return True
    except OSError:
        return False


def _stun_check(host: str, port: int, timeout: float = 1.8) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        pkt = b"\x00\x01\x00\x00\x21\x12\xa4\x42\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c"
        sock.sendto(pkt, (host, port))
        data, _ = sock.recvfrom(512)
        return len(data) >= 20
    except OSError:
        return False
    finally:
        sock.close()


def _resolve_via_server(hostname: str, dns_server: str | None, runner: Runner) -> str | None:
    cmd = ["dig", "+short", "+time=2", "+tries=1"]
    if dns_server:
        cmd.append(f"@{dns_server}")
    cmd.append(hostname)
    res = runner(cmd)
    if res.returncode != 0:
        return None
    for line in res.stdout.splitlines():
        cand = line.strip()
        if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", cand):
            return cand
    return None


def probe_psn_firewall(
    runner: Runner = _default_runner,
    exit_node: str | None = None,
) -> FirewallProbeReport:
    """Detect whether the current network blocks PSN, outbound UDP, or Tailscale controlplane/DERP (FortiGate)."""
    target_exit = configured_exit_node(exit_node)
    rep = FirewallProbeReport(tailscale_exit_node=target_exit)
    rep.warp_available = find_warp_cli() is not None
    ts_cli = find_tailscale_cli(runner)
    rep.tailscale_available = ts_cli is not None
    if ts_cli:
        if not target_exit:
            target_exit = _tailscale_discover_exit_node(ts_cli, runner)
            rep.tailscale_exit_node = target_exit
        ts_info = inspect_tailscale_exit_node(ts_cli, target=target_exit, runner=runner)
        rep.tailscale_state = str(ts_info["backend_state"])
        rep.tailscale_running = rep.tailscale_state == "Running"
        rep.tailscale_exit_node_ready = bool(ts_info["ready"])
        rep.tailscale_exit_node_status = str(ts_info["status_text"])
        rep.tailscale_available_exit_nodes = list(ts_info["available_exit_nodes"])
        cp_ok, _ = probe_tailscale_controlplane(timeout=2.5)
        rep.tailscale_controlplane_ok = cp_ok
        derp_ok, derp_nodes = probe_tailscale_derp(timeout=2.0)
        rep.tailscale_derp_ok = derp_ok
        rep.tailscale_derp_nodes = derp_nodes
        rep.fortigate_warp_bootstrap_needed = not cp_ok
    rep.macos_vpns = list_macos_vpns(runner)

    psn_host = "m.np.playstation.com"
    sys_ip = _resolve_via_server(psn_host, None, runner)
    cf_ip = _resolve_via_server(psn_host, "1.1.1.1", runner)

    if sys_ip:
        rep.psn_sys_tls_ok = _tls_check_ip(sys_ip, psn_host)
    if cf_ip:
        rep.psn_cf_tls_ok = rep.psn_sys_tls_ok if cf_ip == sys_ip else _tls_check_ip(cf_ip, psn_host)

    rep.udp_high_port_ok = _stun_check("stun.l.google.com", 19302)
    rep.udp_3478_ok = _stun_check("stun.cloudflare.com", 3478)

    if rep.tailscale_available and not rep.tailscale_controlplane_ok:
        rep.diagnosis = (
            "FortiGate/DPI blocking controlplane.tailscale.com "
            "(auto WARP-bootstrap -> Tailscale exit-node ready)"
        )
    elif not rep.psn_sys_tls_ok and rep.psn_cf_tls_ok and not rep.udp_high_port_ok:
        rep.diagnosis = "DNS/CDN PSN block + Outbound UDP firewall (use --bypass-firewall tailscale or `senza tunnel on`)"
    elif not rep.psn_sys_tls_ok and rep.psn_cf_tls_ok:
        rep.diagnosis = "DNS/CDN PSN block (fixed immediately by --bypass-firewall dns or tailscale)"
    elif not rep.psn_sys_tls_ok and not rep.psn_cf_tls_ok:
        rep.diagnosis = "Strict PSN HTTPS/DPI block (needs full tunnel: --bypass-firewall tailscale or warp)"
    elif not rep.udp_high_port_ok:
        rep.diagnosis = "Outbound UDP gaming ports blocked (needs full tunnel: --bypass-firewall tailscale or warp)"
    else:
        rep.diagnosis = "No PSN/UDP firewall block detected"

    return rep


class FirewallBypass:
    """Applies PSN/Firewall bypass (Clean DNS + optional WARP/Tailscale exit-node/macOS VPN) with guaranteed rollback."""

    def __init__(
        self,
        mode: str = "auto",
        exit_node: str | None = None,
        gui_sudo: bool = False,
        dry_run: bool = False,
        runner: Runner = _default_runner,
        state_file: Path = BYPASS_STATE_FILE,
        warp_bootstrap: str = "auto",
        fallback_warp: bool = False,
        persistent: bool = False,
        system_state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
    ) -> None:
        self.mode = mode.strip()
        self.exit_node = exit_node.strip() if exit_node and exit_node.strip() else None
        self.gui_sudo = gui_sudo
        self.dry_run = dry_run
        self.runner = runner
        self.state_file = state_file
        self.warp_bootstrap = warp_bootstrap.strip().lower() if warp_bootstrap else "auto"
        self.fallback_warp = fallback_warp
        self.persistent = persistent
        self.system_state_file = system_state_file

        self._active = False
        self._dns_service: str | None = None
        self._prev_dns: list[str] | None = None
        self._warp_connected_by_us = False
        self._warp_cli: str | None = None
        self._tailscale_started_by_us = False
        self._tailscale_exit_set_by_us = False
        self._tailscale_exit_active = False
        self._prev_tailscale_exit_node: str | None = None
        self._tailscale_cli: str | None = None
        self._vpn_started_by_us: str | None = None

    def _write_state(self) -> None:
        if self.dry_run:
            return
        payload = {
            "dns_service": self._dns_service,
            "prev_dns": self._prev_dns,
            "warp_connected_by_us": self._warp_connected_by_us,
            "warp_cli": self._warp_cli,
            "tailscale_started_by_us": self._tailscale_started_by_us,
            "tailscale_exit_set_by_us": self._tailscale_exit_set_by_us,
            "prev_tailscale_exit_node": self._prev_tailscale_exit_node,
            "tailscale_cli": self._tailscale_cli,
            "vpn_started_by_us": self._vpn_started_by_us,
        }
        atomic_write_json(self.state_file, payload)

    def _clear_state(self) -> None:
        if self.dry_run:
            return
        remove_file(self.state_file)

    def _system_tunnel_owns_routing(self) -> bool:
        """True when this is a per-session bypass and the persistent system-wide tunnel is managed.

        The system tunnel (and its LaunchAgent) owns Tailscale exit-node + WARP routing, so a
        Remote Play session ending must not tear those down underneath it.
        """
        return _session_defers_to_system_tunnel(self.state_file, self.system_state_file)

    def _apply_clean_dns(self) -> list[str]:
        notes: list[str] = []
        service = detect_active_network_service(self.runner)
        if not service:
            notes.append("Warning: could not detect active macOS network service for DNS bypass")
            return notes

        prev_dns = get_dns_servers(service, self.runner)
        if prev_dns == list(CLEAN_DNS_SERVERS):
            notes.append(f"Clean DNS ({', '.join(CLEAN_DNS_SERVERS)}) already active on '{service}'")
            return notes

        dns_args = " ".join(CLEAN_DNS_SERVERS)
        svc_q = shlex.quote(service)
        script = (
            f"networksetup -setdnsservers {svc_q} {dns_args} && "
            f"dscacheutil -flushcache && "
            f"(killall -HUP mDNSResponder 2>/dev/null || true)"
        )
        cmd = _privileged_shell_cmd(script, self.gui_sudo)
        if self.dry_run:
            notes.append(f"[dry-run] {' '.join(cmd)}")
            return notes

        res = self.runner(cmd)
        if res.returncode == 0:
            self._dns_service = service
            self._prev_dns = prev_dns
            self._write_state()
            notes.append(f"Bypass DNS active on '{service}': {' / '.join(CLEAN_DNS_SERVERS)} (cache flushed)")
        else:
            notes.append(f"Warning: could not set Clean DNS on '{service}' ({res.stderr.strip()})")
        return notes

    def _connect_warp(self) -> list[str]:
        notes: list[str] = []
        warp = find_warp_cli()
        if not warp:
            notes.append(
                "Cloudflare WARP not installed — install with `brew install --cask cloudflare-warp` "
                "for full UDP/DPI firewall bypass."
            )
            return notes

        if self.dry_run:
            notes.append(f"[dry-run] {warp} mode warp && {warp} connect")
            return notes

        status_res = self.runner([warp, "status"])
        if "Registration Missing" in status_res.stdout or "Missing" in status_res.stderr:
            self.runner([warp, "--accept-tos", "registration", "new"])

        # Ensure full WARP VPN tunnel mode (fresh installs often default to DnsOverHttps-only,
        # which leaves PS5 UDP traffic on the blocked Wi-Fi interface and causes error 8801330d).
        settings_res = self.runner([warp, "settings"])
        is_full_warp_mode = bool(re.search(r"Mode:\s*Warp\b", settings_res.stdout))
        if not is_full_warp_mode:
            mode_res = self.runner([warp, "mode", "warp"])
            if mode_res.returncode == 0:
                notes.append("Switched Cloudflare WARP from DNS-only to full WARP tunnel mode")
            else:
                notes.append(f"Warning: could not set WARP mode to 'warp' ({mode_res.stderr.strip() or mode_res.stdout.strip()})")

        already_connected = (
            is_full_warp_mode
            and "Connected" in status_res.stdout
            and "Connecting" not in status_res.stdout
            and "Disconnected" not in status_res.stdout
        )
        if already_connected:
            notes.append("Cloudflare WARP full tunnel already connected")
            return notes

        conn_res = self.runner([warp, "connect"])
        if conn_res.returncode != 0:
            notes.append(f"Warning: warp-cli connect failed ({conn_res.stderr.strip() or conn_res.stdout.strip()})")
            return notes

        connected = False
        for _ in range(30):
            time.sleep(0.5)
            st = self.runner([warp, "status"])
            if "Status update: Connected" in st.stdout or (
                "Connected" in st.stdout and "Connecting" not in st.stdout and "Disconnected" not in st.stdout
            ):
                connected = True
                break

        self._warp_connected_by_us = True
        self._warp_cli = warp
        self._write_state()
        if connected:
            notes.append("Cloudflare WARP full tunnel CONNECTED (PSN + UDP firewall bypassed)")
        else:
            notes.append("Warning: Cloudflare WARP still finalizing connection after 15s (check `warp-cli status`)")
        return notes

    def _is_warp_connected(self, warp_cli: str) -> bool:
        st = self.runner([warp_cli, "status"])
        return "Status update: Connected" in st.stdout or (
            "Connected" in st.stdout and "Connecting" not in st.stdout and "Disconnected" not in st.stdout
        )

    def _warp_bootstrap_tailscale_up(self, ts: str) -> tuple[dict[str, Any] | None, list[str]]:
        """FortiGate bypass: briefly turn WARP ON -> `tailscale up` (controlplane/netmap) -> WARP OFF."""
        notes: list[str] = []
        warp = find_warp_cli()
        if not warp:
            notes.append(
                "Warning: controlplane.tailscale.com appears blocked by FortiGate/DPI, and Cloudflare WARP "
                "is not installed for bootstrap (`brew install --cask cloudflare-warp`)."
            )
            return None, notes

        warp_was_connected = self._is_warp_connected(warp)
        temp_warp_connected = False

        try:
            if not warp_was_connected:
                status_res = self.runner([warp, "status"])
                if "Registration Missing" in status_res.stdout or "Missing" in status_res.stderr:
                    self.runner([warp, "--accept-tos", "registration", "new"])

                settings_res = self.runner([warp, "settings"])
                if not re.search(r"Mode:\s*Warp\b", settings_res.stdout):
                    self.runner([warp, "mode", "warp"])

                conn_res = self.runner([warp, "connect"])
                if conn_res.returncode != 0:
                    notes.append(
                        f"Warning: WARP bootstrap connect failed ({conn_res.stderr.strip() or conn_res.stdout.strip()})"
                    )
                    return None, notes

                connected = False
                for _ in range(30):
                    time.sleep(0.5)
                    if self._is_warp_connected(warp):
                        connected = True
                        break

                if not connected:
                    notes.append("Warning: WARP bootstrap did not reach Connected state within 15s")
                    self.runner([warp, "disconnect"])
                    return None, notes

                temp_warp_connected = True
                notes.append("FortiGate bootstrap: Cloudflare WARP MASQUE connected temporarily")

            up_res = self.runner([ts, "up"])
            if up_res.returncode != 0:
                notes.append(
                    f"Warning: `tailscale up` via WARP failed ({up_res.stderr.strip() or up_res.stdout.strip()})"
                )
                return None, notes

            self._tailscale_started_by_us = True
            self._tailscale_cli = ts
            self._write_state()

            data: dict[str, Any] | None = None
            for _ in range(24):
                data = _tailscale_status_json(ts, self.runner)
                cur_state = str(data.get("BackendState") or "") if data else ""
                if cur_state == "Running" and (data and data.get("Peer")):
                    break
                if cur_state == "NeedsLogin":
                    notes.append("Warning: Tailscale requires sign-in — open Tailscale.app and log in first.")
                    return data, notes
                time.sleep(0.5)

            if data and str(data.get("BackendState") or "") == "Running":
                notes.append("FortiGate bootstrap: Tailscale controlplane handshake & netmap sync succeeded")
            else:
                notes.append("Warning: Tailscale did not reach Running state during WARP bootstrap")
        finally:
            if temp_warp_connected:
                self.runner([warp, "disconnect"])
                for _ in range(12):
                    time.sleep(0.5)
                    if not self._is_warp_connected(warp):
                        break
                notes.append("FortiGate bootstrap: Cloudflare WARP disconnected (handing default route to Tailscale)")

        return _tailscale_status_json(ts, self.runner), notes

    @staticmethod
    def _parse_tailscale_ping(stdout: str) -> str | None:
        for raw_line in stdout.splitlines():
            line = raw_line.strip()
            if not line.startswith("pong from "):
                continue
            derp_match = re.search(r"via\s+(DERP\([^)]+\))\s+in\s+(\S+)", line)
            if derp_match:
                return f"{derp_match.group(1)} TCP-443 relay · {derp_match.group(2)}"
            direct_match = re.search(r"via\s+(\S+)\s+in\s+(\S+)", line)
            if direct_match:
                return f"Direct UDP ({direct_match.group(1)}) · {direct_match.group(2)}"
            return line
        return None

    def _connect_tailscale(self) -> list[str]:
        notes: list[str] = []
        ts = find_tailscale_cli(self.runner)
        if not ts:
            notes.append("Tailscale CLI not found (`brew install --cask tailscale-app`).")
            return notes

        target_node = configured_exit_node(self.exit_node) or _tailscale_discover_exit_node(ts, self.runner)
        if not target_node:
            notes.append(f"Warning: {NO_EXIT_NODE_HINT}.")
            if self.fallback_warp and not self.dry_run:
                notes.append("Fallback enabled — activating Cloudflare WARP MASQUE (TCP 443) instead")
                notes.extend(self._connect_warp())
            return notes

        if self.dry_run:
            data = _tailscale_status_json(ts, self.runner)
            state = str(data.get("BackendState") or "NotRunning") if data else "NotRunning"
            if state != "Running":
                need_boot = self.warp_bootstrap == "always"
                if self.warp_bootstrap == "auto":
                    cp_ok, _ = probe_tailscale_controlplane(timeout=2.0)
                    need_boot = not cp_ok
                if need_boot:
                    warp = find_warp_cli() or "warp-cli"
                    notes.append(
                        f"[dry-run] FortiGate WARP bootstrap: {warp} connect -> {ts} up -> {warp} disconnect"
                    )
                else:
                    notes.append(f"[dry-run] {ts} up  (current Tailscale state: {state})")
            notes.append(f"[dry-run] {ts} set --exit-node={target_node} --exit-node-allow-lan-access=true")
            notes.append(f"[dry-run] {ts} ping -c 1 --timeout=3s {target_node}")
            return notes

        data = _tailscale_status_json(ts, self.runner)
        if data is None and Path("/Applications/Tailscale.app").exists():
            self.runner(["open", "-g", "-a", "Tailscale"])
            for _ in range(16):
                time.sleep(0.5)
                data = _tailscale_status_json(ts, self.runner)
                if data is not None:
                    break

        if data is None:
            notes.append(
                "Warning: could not reach Tailscale macOS backend — open Tailscale.app once to initialize its Network Extension."
            )
            return notes

        state = str(data.get("BackendState") or "Unknown")
        if state == "NeedsLogin":
            notes.append("Warning: Tailscale requires sign-in — open Tailscale.app and log in first.")
            return notes

        if state != "Running":
            use_bootstrap = self.warp_bootstrap == "always"
            if self.warp_bootstrap == "auto":
                cp_ok, cp_detail = probe_tailscale_controlplane(timeout=2.5)
                if not cp_ok:
                    use_bootstrap = True
                    notes.append(f"controlplane.tailscale.com blocked ({cp_detail}) — engaging FortiGate WARP bootstrap")

            if use_bootstrap:
                data, boot_notes = self._warp_bootstrap_tailscale_up(ts)
                notes.extend(boot_notes)
            else:
                if state == "Stopped":
                    up_res = self.runner([ts, "up"])
                    if up_res.returncode != 0:
                        notes.append(
                            f"Warning: `tailscale up` failed ({up_res.stderr.strip() or up_res.stdout.strip()})"
                        )
                        return notes
                    self._tailscale_started_by_us = True
                    self._tailscale_cli = ts
                    self._write_state()
                    notes.append("Started Tailscale network (was Stopped)")

                for _ in range(12):
                    data = _tailscale_status_json(ts, self.runner)
                    cur_state = str(data.get("BackendState") or "") if data else ""
                    if cur_state == "Running":
                        break
                    if cur_state == "NeedsLogin":
                        notes.append("Warning: Tailscale requires sign-in — open Tailscale.app and log in first.")
                        return notes
                    time.sleep(0.5)

                if (not data or str(data.get("BackendState") or "") != "Running") and self.warp_bootstrap == "auto" and find_warp_cli():
                    notes.append("Direct `tailscale up` stalled (possible FortiGate DPI) — retrying via WARP bootstrap")
                    data, boot_notes = self._warp_bootstrap_tailscale_up(ts)
                    notes.extend(boot_notes)

            if not data or str(data.get("BackendState") or "") != "Running":
                notes.append("Warning: Tailscale did not reach Running state (check Tailscale.app).")
                if self.fallback_warp:
                    notes.append("Fallback enabled — switching to Cloudflare WARP MASQUE (TCP 443) tunnel")
                    notes.extend(self._connect_warp())
                return notes

        self._prev_tailscale_exit_node = _tailscale_active_exit_node(data)
        peer = _tailscale_find_peer(data, target_node)

        # Right after `tailscale up`, the netmap peer table can take a couple seconds to populate.
        if peer is None and (self._tailscale_started_by_us or not data.get("Peer")):
            for _ in range(8):
                time.sleep(0.5)
                refreshed = _tailscale_status_json(ts, self.runner)
                if refreshed:
                    data = refreshed
                    peer = _tailscale_find_peer(data, target_node)
                    if peer is not None:
                        break

        if peer is None:
            avail = _tailscale_list_exit_nodes(data)
            msg = (
                f"Warning: Tailscale exit node {target_node} is not in your tailnet yet "
                "(waiting for share/ACL access)."
            )
            if avail:
                msg += f" Available exit nodes: {', '.join(avail)}"
            notes.append(msg)
            if self.fallback_warp:
                notes.append("Fallback enabled — activating Cloudflare WARP MASQUE (TCP 443) until exit node arrives")
                notes.extend(self._connect_warp())
            return notes

        peer_name = str(peer.get("HostName") or str(peer.get("DNSName") or "").rstrip(".") or target_node)
        if not peer.get("ExitNodeOption"):
            notes.append(
                f"Warning: {target_node} ({peer_name}) is visible in tailnet, "
                "but Exit Node permission is not enabled on it yet."
            )
            if self.fallback_warp:
                notes.extend(self._connect_warp())
            return notes
        if not peer.get("Online"):
            notes.append(f"Warning: Tailscale exit node {target_node} ({peer_name}) is currently OFFLINE.")
            if self.fallback_warp:
                notes.extend(self._connect_warp())
            return notes

        peer_ips = {str(ip).strip().lower() for ip in (peer.get("TailscaleIPs") or [])}
        prev_exit = (self._prev_tailscale_exit_node or "").strip().lower()
        already_using_target = bool(
            prev_exit and (prev_exit == target_node.strip().lower() or prev_exit in peer_ips)
        )

        if not already_using_target:
            cmd = [ts, "set", f"--exit-node={target_node}", "--exit-node-allow-lan-access=true"]
            res = self.runner(cmd)
            if res.returncode != 0:
                notes.append(f"Warning: Tailscale exit-node failed ({res.stderr.strip() or res.stdout.strip()})")
                return notes

            self._tailscale_exit_set_by_us = True
            self._tailscale_cli = ts
            self._write_state()

            for _ in range(12):
                chk = _tailscale_status_json(ts, self.runner)
                ex_st = chk.get("ExitNodeStatus") if chk else None
                if isinstance(ex_st, dict) and ex_st.get("Online"):
                    break
                time.sleep(0.5)

        ping_res = self.runner([ts, "ping", "-c", "1", "--timeout=3s", target_node])
        path_info = self._parse_tailscale_ping(ping_res.stdout) if ping_res.returncode == 0 else None
        egress_ok, egress_info = probe_egress_via_tunnel(timeout=4.0)

        prefix = "Tailscale Exit Node already active" if already_using_target else "Tailscale Exit Node ACTIVE"
        parts = [f"{prefix}: {target_node} ({peer_name})"]
        if path_info:
            parts.append(path_info)
        if egress_ok:
            parts.append(egress_info)
        notes.append(" · ".join(parts))

        if egress_ok:
            self._tailscale_exit_active = True
        else:
            notes.append(
                "Warning: Exit node connected, but live HTTPS egress check failed "
                "(FortiGate may be blocking both WireGuard UDP and this DERP relay)."
            )
            if self.fallback_warp:
                if self._tailscale_exit_set_by_us:
                    self.runner([ts, "set", f"--exit-node={self._prev_tailscale_exit_node or ''}"])
                    self._tailscale_exit_set_by_us = False
                notes.append("Fallback enabled — switching to Cloudflare WARP MASQUE (HTTP/2 TCP-443)")
                notes.extend(self._connect_warp())
            else:
                self._tailscale_exit_active = True
        return notes

    def _connect_macos_vpn(self, vpn_name: str) -> list[str]:
        notes: list[str] = []
        if self.dry_run:
            notes.append(f'[dry-run] scutil --nc start "{vpn_name}"')
            return notes

        st = self.runner(["scutil", "--nc", "status", vpn_name])
        if st.returncode == 0 and st.stdout.splitlines()[:1] == ["Connected"]:
            notes.append(f"macOS VPN '{vpn_name}' already connected")
            return notes

        res = self.runner(["scutil", "--nc", "start", vpn_name])
        if res.returncode != 0:
            notes.append(f"Warning: failed to start macOS VPN '{vpn_name}' ({res.stderr.strip()})")
            return notes

        connected = False
        for _ in range(20):
            time.sleep(0.5)
            chk = self.runner(["scutil", "--nc", "status", vpn_name])
            if chk.stdout.splitlines()[:1] == ["Connected"]:
                connected = True
                break

        self._vpn_started_by_us = vpn_name
        self._write_state()
        if connected:
            notes.append(f"macOS VPN '{vpn_name}' CONNECTED (PSN + UDP firewall bypassed)")
        else:
            notes.append(f"Warning: macOS VPN '{vpn_name}' did not reach Connected state within 10s")
        return notes

    def enter(self) -> list[str]:
        notes: list[str] = []
        self._active = True

        mode = self.mode.lower()
        if mode not in ("auto", "dns", "warp", "tailscale") and not mode.startswith("vpn:"):
            raise ValueError(
                f"Invalid --bypass-firewall mode '{self.mode}'. Use: auto, dns, warp, tailscale, or vpn:<ServiceName>"
            )

        # In pure Tailscale Exit-Node mode, Tailscale handles all DNS + TCP/UDP routing through its utun
        # tunnel and uses built-in bootstrap DoH — no sudo networksetup DNS modification needed.
        if mode != "tailscale":
            notes.extend(self._apply_clean_dns())

        if mode == "dns":
            pass
        elif mode == "warp":
            notes.extend(self._connect_warp())
        elif mode == "tailscale":
            notes.extend(self._connect_tailscale())
        elif mode.startswith("vpn:"):
            vpn_name = self.mode.split(":", 1)[1].strip()
            if not vpn_name:
                raise ValueError("Missing VPN service name after 'vpn:' (e.g. --bypass-firewall vpn:MyVPN)")
            notes.extend(self._connect_macos_vpn(vpn_name))
        elif mode == "auto":
            if self.exit_node:
                notes.extend(self._connect_tailscale())
            elif find_warp_cli():
                notes.extend(self._connect_warp())
            else:
                ts = find_tailscale_cli(self.runner)
                ts_node = _tailscale_discover_exit_node(ts, self.runner) if ts else None
                if ts_node:
                    notes.extend(self._connect_tailscale())
                elif not self.dry_run:
                    if not _stun_check("stun.l.google.com", 19302, timeout=1.5):
                        notes.append(
                            "Notice: Clean DNS (1.1.1.1) applied, but this firewall ALSO blocks outbound UDP. "
                            "For full PS Remote Play tunnel bypass, install Cloudflare WARP (`brew install --cask cloudflare-warp`) "
                            "or enable a Tailscale Exit Node (`senza config set exit-node <ip>` then `--bypass-firewall tailscale`)."
                        )

        if not self.dry_run and not self.persistent:
            atexit.register(self.exit)
        return notes

    def exit(self) -> list[str]:
        notes: list[str] = []
        if not self._active:
            return notes
        self._active = False

        if self._system_tunnel_owns_routing() and (
            self._warp_connected_by_us or self._tailscale_exit_set_by_us or self._tailscale_started_by_us
        ):
            notes.append("Kept Tailscale/WARP routing up (owned by system-wide tunnel `senza tunnel on`)")
            self._warp_connected_by_us = False
            self._tailscale_exit_set_by_us = False
            self._tailscale_started_by_us = False
            self._prev_tailscale_exit_node = None

        if self._warp_connected_by_us and self._warp_cli:
            res = self.runner([self._warp_cli, "disconnect"])
            if res.returncode == 0:
                notes.append("Disconnected Cloudflare WARP")
            else:
                notes.append(f"Warning: failed to disconnect WARP ({res.stderr.strip()})")
            self._warp_connected_by_us = False

        if self._tailscale_exit_set_by_us and self._tailscale_cli:
            prev_node = self._prev_tailscale_exit_node or ""
            res = self.runner([self._tailscale_cli, "set", f"--exit-node={prev_node}"])
            if res.returncode == 0:
                if prev_node:
                    notes.append(f"Restored previous Tailscale exit-node ({prev_node})")
                else:
                    notes.append("Cleared Tailscale exit-node routing")
            else:
                notes.append(f"Warning: failed to restore Tailscale exit-node ({res.stderr.strip()})")
            self._tailscale_exit_set_by_us = False
            self._prev_tailscale_exit_node = None

        if self._tailscale_started_by_us and self._tailscale_cli:
            res = self.runner([self._tailscale_cli, "down"])
            if res.returncode == 0:
                notes.append("Stopped Tailscale (restored previous Stopped state)")
            else:
                notes.append(f"Warning: failed to stop Tailscale ({res.stderr.strip()})")
            self._tailscale_started_by_us = False

        if self._vpn_started_by_us:
            res = self.runner(["scutil", "--nc", "stop", self._vpn_started_by_us])
            if res.returncode == 0:
                notes.append(f"Disconnected macOS VPN '{self._vpn_started_by_us}'")
            else:
                notes.append(f"Warning: failed to stop VPN '{self._vpn_started_by_us}' ({res.stderr.strip()})")
            self._vpn_started_by_us = None

        if self._dns_service is not None:
            svc_q = shlex.quote(self._dns_service)
            dns_restore = " ".join(self._prev_dns) if self._prev_dns else "empty"
            script = (
                f"networksetup -setdnsservers {svc_q} {dns_restore} && "
                f"dscacheutil -flushcache && "
                f"(killall -HUP mDNSResponder 2>/dev/null || true)"
            )
            res = self.runner(_privileged_shell_cmd(script, self.gui_sudo))
            if res.returncode == 0:
                notes.append(f"Restored original DNS ({dns_restore}) on '{self._dns_service}'")
            else:
                notes.append(f"Warning: failed to restore DNS on '{self._dns_service}' ({res.stderr.strip()})")
            self._dns_service = None
            self._prev_dns = None

        self._clear_state()
        return notes

    def __enter__(self) -> FirewallBypass:
        self.enter()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.exit()


def _session_defers_to_system_tunnel(state_file: Path, system_state_file: Path) -> bool:
    try:
        is_session = state_file.resolve() != system_state_file.resolve()
    except OSError:
        is_session = state_file != system_state_file
    return is_session and system_state_file.exists()


def restore_firewall_bypass(
    gui_sudo: bool = False,
    runner: Runner = _default_runner,
    state_file: Path = BYPASS_STATE_FILE,
    system_state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
) -> list[str]:
    """Recover DNS / WARP / Tailscale / VPN state after an unexpected crash or kill -9."""
    notes: list[str] = []
    if not state_file.exists():
        return notes

    data = read_json_dict(state_file)
    if _session_defers_to_system_tunnel(state_file, system_state_file):
        if data.get("warp_connected_by_us") or data.get("tailscale_exit_set_by_us") or data.get("tailscale_started_by_us"):
            notes.append("Kept Tailscale/WARP routing up (owned by system-wide tunnel `senza tunnel on`)")
        for key in ("warp_connected_by_us", "tailscale_exit_set_by_us", "tailscale_started_by_us"):
            data[key] = False

    if data.get("warp_connected_by_us") and data.get("warp_cli"):
        res = runner([str(data["warp_cli"]), "disconnect"])
        if res.returncode == 0:
            notes.append("Disconnected Cloudflare WARP")

    if data.get("tailscale_exit_set_by_us") and data.get("tailscale_cli"):
        prev_node = str(data.get("prev_tailscale_exit_node") or "")
        res = runner([str(data["tailscale_cli"]), "set", f"--exit-node={prev_node}"])
        if res.returncode == 0:
            if prev_node:
                notes.append(f"Restored previous Tailscale exit-node ({prev_node})")
            else:
                notes.append("Cleared Tailscale exit-node routing")

    if data.get("tailscale_started_by_us") and data.get("tailscale_cli"):
        res = runner([str(data["tailscale_cli"]), "down"])
        if res.returncode == 0:
            notes.append("Stopped Tailscale (restored previous Stopped state)")

    if data.get("vpn_started_by_us"):
        vpn_name = str(data["vpn_started_by_us"])
        res = runner(["scutil", "--nc", "stop", vpn_name])
        if res.returncode == 0:
            notes.append(f"Disconnected macOS VPN '{vpn_name}'")

    dns_service = data.get("dns_service")
    if dns_service:
        prev_dns = data.get("prev_dns") or []
        dns_restore = " ".join(str(x) for x in prev_dns) if prev_dns else "empty"
        svc_q = shlex.quote(str(dns_service))
        script = (
            f"networksetup -setdnsservers {svc_q} {dns_restore} && "
            f"dscacheutil -flushcache && "
            f"(killall -HUP mDNSResponder 2>/dev/null || true)"
        )
        res = runner(_privileged_shell_cmd(script, gui_sudo))
        if res.returncode == 0:
            notes.append(f"Restored original DNS ({dns_restore}) on '{dns_service}'")
        else:
            notes.append(f"Warning: failed to restore DNS on '{dns_service}' ({res.stderr.strip()})")

    remove_file(state_file)
    return notes


def _resolve_senza_cli_path() -> str:
    local_bin = Path.home() / ".local" / "bin" / "senza"
    if local_bin.exists():
        return str(local_bin)
    found = shutil.which("senza")
    if found:
        return found
    repo_bin = Path(__file__).resolve().parent.parent / "bin" / "senza"
    return str(repo_bin)


def _read_json_file(path: Path) -> dict[str, Any]:
    return read_json_dict(path)


def _warp_is_connected(runner: Runner = _default_runner) -> bool:
    warp = find_warp_cli()
    if not warp:
        return False
    st = runner([warp, "status"])
    return "Status update: Connected" in st.stdout or (
        "Connected" in st.stdout and "Connecting" not in st.stdout and "Disconnected" not in st.stdout
    )


def system_tunnel_status(
    exit_node: str | None = None,
    runner: Runner = _default_runner,
    state_file: Path = SYSTEM_TUNNEL_STATE_FILE,
    plist_path: Path = LAUNCH_AGENT_PATH,
    probe_network_checks: bool = False,
) -> dict[str, Any]:
    """Inspect current system-wide FortiGate/Tailscale bypass tunnel & LaunchAgent status."""
    saved = _read_json_file(state_file)
    target = resolve_exit_node(exit_node, runner, saved=str(saved.get("target_exit_node") or ""))

    ts_cli = find_tailscale_cli(runner)
    ts_info = inspect_tailscale_exit_node(ts_cli, target=target, runner=runner) if ts_cli else {
        "backend_state": "NotInstalled",
        "ready": False,
        "active_exit_node": None,
        "available_exit_nodes": [],
        "status_text": "Tailscale CLI not installed",
    }
    warp_connected = _warp_is_connected(runner)

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
        cp_ok, cp_detail = probe_tailscale_controlplane(timeout=2.5)
        derp_ok, derp_nodes = probe_tailscale_derp(timeout=2.0)
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
    target = resolve_exit_node(exit_node, runner, saved=str(prev_saved.get("target_exit_node") or ""))
    if not target:
        return [f"Warning: {NO_EXIT_NODE_HINT}."]

    fb = FirewallBypass(
        mode="tailscale",
        exit_node=target,
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
    if fb._tailscale_exit_active and not fb._warp_connected_by_us and _warp_is_connected(runner):
        warp = find_warp_cli()
        if warp:
            res = runner([warp, "disconnect"])
            if res.returncode == 0:
                notes.append("Disconnected previous WARP fallback (Tailscale exit-node is now primary)")

    active_backend = (
        "tailscale"
        if fb._tailscale_exit_active
        else ("warp" if fb._warp_connected_by_us else "none")
    )

    merged = {
        "persistent": True,
        "target_exit_node": target,
        "active_backend": active_backend,
        "warp_bootstrap": warp_bootstrap,
        "fallback_warp": fallback_warp,
        "dns_service": fb._dns_service or prev_saved.get("dns_service"),
        "prev_dns": fb._prev_dns if fb._dns_service else prev_saved.get("prev_dns"),
        "warp_connected_by_us": bool(fb._warp_connected_by_us or (active_backend == "warp" and prev_saved.get("warp_connected_by_us"))),
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
        notes = restore_firewall_bypass(gui_sudo=False, runner=runner, state_file=state_file)
        if not notes:
            notes.append("System tunnel state cleared (already inactive)")
        return notes

    notes: list[str] = []
    ts_cli = find_tailscale_cli(runner)
    if ts_cli:
        data = _tailscale_status_json(ts_cli, runner)
        if data and _tailscale_active_exit_node(data):
            res = runner([ts_cli, "set", "--exit-node="])
            if res.returncode == 0:
                notes.append("Cleared Tailscale exit-node routing")

    if _warp_is_connected(runner):
        warp = find_warp_cli()
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
    target = resolve_exit_node(exit_node, runner, saved=str(saved.get("target_exit_node") or ""))
    if not target:
        return [f"Warning: {NO_EXIT_NODE_HINT}."]

    ts_cli = find_tailscale_cli(runner)
    if ts_cli:
        data = _tailscale_status_json(ts_cli, runner)
        if data and str(data.get("BackendState") or "") == "Running":
            active = _tailscale_active_exit_node(data)
            ex_st = data.get("ExitNodeStatus")
            ex_online = isinstance(ex_st, dict) and bool(ex_st.get("Online"))
            peer = _tailscale_find_peer(data, target)
            peer_ips = {str(ip).strip().lower() for ip in (peer.get("TailscaleIPs") or [])} if peer else set()
            if active and ex_online and (active.lower() == target.lower() or active.lower() in peer_ips):
                return [f"OK: Tailscale exit node {target} already online & healthy"]

    return system_tunnel_up(
        exit_node=target,
        warp_bootstrap=warp_bootstrap,
        fallback_warp=fallback_warp,
        dry_run=False,
        runner=runner,
        state_file=state_file,
    )


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
