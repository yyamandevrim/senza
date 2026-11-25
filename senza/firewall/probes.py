"""Network probes: PSN TLS reachability, UDP/STUN, Tailscale controlplane/DERP, tunnel egress."""

from __future__ import annotations

import re
import socket
import ssl
import urllib.request
from dataclasses import dataclass, field

from ..config import configured_exit_node
from . import netsvc as _netsvc
from . import tailscale as _tailscale
from . import warp as _warp
from .common import TAILSCALE_DERP_PROBE_HOSTS, Runner, _default_runner


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
    rep.warp_available = _warp.find_warp_cli() is not None
    ts_cli = _tailscale.find_tailscale_cli(runner)
    rep.tailscale_available = ts_cli is not None
    if ts_cli:
        if not target_exit:
            target_exit = _tailscale._tailscale_discover_exit_node(ts_cli, runner)
            rep.tailscale_exit_node = target_exit
        ts_info = _tailscale.inspect_tailscale_exit_node(ts_cli, target=target_exit, runner=runner)
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
    rep.macos_vpns = _netsvc.list_macos_vpns(runner)

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
            "FortiGate/DPI blocking controlplane.tailscale.com (auto WARP-bootstrap -> Tailscale exit-node ready)"
        )
    elif not rep.psn_sys_tls_ok and rep.psn_cf_tls_ok and not rep.udp_high_port_ok:
        rep.diagnosis = (
            "DNS/CDN PSN block + Outbound UDP firewall (use --bypass-firewall tailscale or `senza tunnel on`)"
        )
    elif not rep.psn_sys_tls_ok and rep.psn_cf_tls_ok:
        rep.diagnosis = "DNS/CDN PSN block (fixed immediately by --bypass-firewall dns or tailscale)"
    elif not rep.psn_sys_tls_ok and not rep.psn_cf_tls_ok:
        rep.diagnosis = "Strict PSN HTTPS/DPI block (needs full tunnel: --bypass-firewall tailscale or warp)"
    elif not rep.udp_high_port_ok:
        rep.diagnosis = "Outbound UDP gaming ports blocked (needs full tunnel: --bypass-firewall tailscale or warp)"
    else:
        rep.diagnosis = "No PSN/UDP firewall block detected"

    return rep
