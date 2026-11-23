"""Firewall & PSN bypass helpers (Clean DNS 1.1.1.1, Cloudflare WARP, Tailscale exit-node, macOS VPN)."""

from __future__ import annotations

import atexit
import json
import re
import shlex
import shutil
import socket
import ssl
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

STATE_DIR = Path.home() / ".local" / "share" / "dualmac"
BYPASS_STATE_FILE = STATE_DIR / "bypass_state.json"

CLEAN_DNS_SERVERS: tuple[str, ...] = ("1.1.1.1", "1.0.0.1")

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


def find_tailscale_cli() -> str | None:
    found = shutil.which("tailscale")
    if found:
        return found
    app_cli = Path("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    if app_cli.is_file():
        return str(app_cli)
    return None


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


@dataclass
class FirewallProbeReport:
    psn_sys_tls_ok: bool = False
    psn_cf_tls_ok: bool = False
    udp_high_port_ok: bool = False
    udp_3478_ok: bool = False
    warp_available: bool = False
    tailscale_available: bool = False
    tailscale_running: bool = False
    macos_vpns: list[str] = field(default_factory=list)
    diagnosis: str = "unknown"


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


def probe_psn_firewall(runner: Runner = _default_runner) -> FirewallProbeReport:
    """Detect whether the current network blocks PSN via DNS/TLS or blocks outbound UDP gaming ports."""
    rep = FirewallProbeReport()
    rep.warp_available = find_warp_cli() is not None
    ts_cli = find_tailscale_cli()
    rep.tailscale_available = ts_cli is not None
    if ts_cli:
        ts_res = runner([ts_cli, "status", "--json"])
        rep.tailscale_running = ts_res.returncode == 0
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

    if not rep.psn_sys_tls_ok and rep.psn_cf_tls_ok and not rep.udp_high_port_ok:
        rep.diagnosis = "DNS/CDN PSN block + Outbound UDP firewall (needs --bypass-firewall + WARP/Tailscale/VPN)"
    elif not rep.psn_sys_tls_ok and rep.psn_cf_tls_ok:
        rep.diagnosis = "DNS/CDN PSN block (fixed immediately by --bypass-firewall dns)"
    elif not rep.psn_sys_tls_ok and not rep.psn_cf_tls_ok:
        rep.diagnosis = "Strict PSN HTTPS/DPI block (needs full tunnel: --bypass-firewall warp or tailscale)"
    elif not rep.udp_high_port_ok:
        rep.diagnosis = "Outbound UDP gaming ports blocked (needs full tunnel: --bypass-firewall warp or tailscale)"
    else:
        rep.diagnosis = "No PSN/UDP firewall block detected"

    return rep


def _tailscale_discover_exit_node(ts_cli: str, runner: Runner) -> str | None:
    res = runner([ts_cli, "status", "--json"])
    if res.returncode != 0:
        return None
    try:
        data = json.loads(res.stdout)
    except ValueError:
        return None
    peers = data.get("Peer") or {}
    for peer in peers.values():
        if peer.get("ExitNodeOption") and peer.get("Online"):
            ips = peer.get("TailscaleIPs") or []
            if ips:
                return str(ips[0])
            dns_name = peer.get("DNSName")
            if dns_name:
                return str(dns_name).rstrip(".")
    return None


class FirewallBypass:
    """Applies PSN/Firewall bypass (Clean DNS + optional WARP/Tailscale/macOS VPN) with guaranteed rollback."""

    def __init__(
        self,
        mode: str = "auto",
        exit_node: str | None = None,
        gui_sudo: bool = False,
        dry_run: bool = False,
        runner: Runner = _default_runner,
        state_file: Path = BYPASS_STATE_FILE,
    ) -> None:
        self.mode = mode.strip()
        self.exit_node = exit_node
        self.gui_sudo = gui_sudo
        self.dry_run = dry_run
        self.runner = runner
        self.state_file = state_file

        self._active = False
        self._dns_service: str | None = None
        self._prev_dns: list[str] | None = None
        self._warp_connected_by_us = False
        self._warp_cli: str | None = None
        self._tailscale_exit_set_by_us = False
        self._tailscale_cli: str | None = None
        self._vpn_started_by_us: str | None = None

    def _write_state(self) -> None:
        if self.dry_run:
            return
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "dns_service": self._dns_service,
            "prev_dns": self._prev_dns,
            "warp_connected_by_us": self._warp_connected_by_us,
            "warp_cli": self._warp_cli,
            "tailscale_exit_set_by_us": self._tailscale_exit_set_by_us,
            "tailscale_cli": self._tailscale_cli,
            "vpn_started_by_us": self._vpn_started_by_us,
        }
        self.state_file.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def _clear_state(self) -> None:
        if self.dry_run:
            return
        try:
            if self.state_file.exists():
                self.state_file.unlink()
        except OSError:
            pass

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

    def _connect_tailscale(self) -> list[str]:
        notes: list[str] = []
        ts = find_tailscale_cli()
        if not ts:
            notes.append("Tailscale CLI not found (`brew install --cask tailscale-app`).")
            return notes

        target_node = self.exit_node or _tailscale_discover_exit_node(ts, self.runner)
        if not target_node:
            notes.append(
                "Tailscale has no active online Exit Node — open Tailscale app and log in, "
                "or specify `--exit-node <node-ip-or-name>` (works over TCP 443 even if all UDP is blocked)."
            )
            return notes

        cmd = [ts, "set", f"--exit-node={target_node}", "--exit-node-allow-lan-access=true"]
        if self.dry_run:
            notes.append(f"[dry-run] {' '.join(cmd)}")
            return notes

        res = self.runner(cmd)
        if res.returncode == 0:
            self._tailscale_exit_set_by_us = True
            self._tailscale_cli = ts
            self._write_state()
            notes.append(f"Tailscale Exit Node active ({target_node}) — TCP 443 DERP bypasses strict UDP firewalls")
        else:
            notes.append(f"Warning: Tailscale exit-node failed ({res.stderr.strip() or res.stdout.strip()})")
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

        # Always apply Clean DNS first (fixes poisoned ISP/campus PSN DNS immediately)
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
                ts = find_tailscale_cli()
                ts_node = _tailscale_discover_exit_node(ts, self.runner) if ts else None
                if ts_node:
                    notes.extend(self._connect_tailscale())
                elif not self.dry_run:
                    if not _stun_check("stun.l.google.com", 19302, timeout=1.5):
                        notes.append(
                            "Notice: Clean DNS (1.1.1.1) applied, but this firewall ALSO blocks outbound UDP. "
                            "For full PS Remote Play tunnel bypass, install Cloudflare WARP (`brew install --cask cloudflare-warp`) "
                            "or enable a Tailscale Exit Node (`--bypass-firewall tailscale --exit-node <node>`)."
                        )

        if not self.dry_run:
            atexit.register(self.exit)
        return notes

    def exit(self) -> list[str]:
        notes: list[str] = []
        if not self._active:
            return notes
        self._active = False

        if self._warp_connected_by_us and self._warp_cli:
            res = self.runner([self._warp_cli, "disconnect"])
            if res.returncode == 0:
                notes.append("Disconnected Cloudflare WARP")
            else:
                notes.append(f"Warning: failed to disconnect WARP ({res.stderr.strip()})")
            self._warp_connected_by_us = False

        if self._tailscale_exit_set_by_us and self._tailscale_cli:
            res = self.runner([self._tailscale_cli, "set", "--exit-node="])
            if res.returncode == 0:
                notes.append("Cleared Tailscale exit-node routing")
            else:
                notes.append(f"Warning: failed to clear Tailscale exit-node ({res.stderr.strip()})")
            self._tailscale_exit_set_by_us = False

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


def restore_firewall_bypass(
    gui_sudo: bool = False,
    runner: Runner = _default_runner,
    state_file: Path = BYPASS_STATE_FILE,
) -> list[str]:
    """Recover DNS / WARP / Tailscale / VPN state after an unexpected crash or kill -9."""
    notes: list[str] = []
    if not state_file.exists():
        return notes

    try:
        data = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}

    if data.get("warp_connected_by_us") and data.get("warp_cli"):
        res = runner([str(data["warp_cli"]), "disconnect"])
        if res.returncode == 0:
            notes.append("Disconnected Cloudflare WARP")

    if data.get("tailscale_exit_set_by_us") and data.get("tailscale_cli"):
        res = runner([str(data["tailscale_cli"]), "set", "--exit-node="])
        if res.returncode == 0:
            notes.append("Cleared Tailscale exit-node routing")

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

    try:
        state_file.unlink()
    except OSError:
        pass
    return notes
