"""Per-session PSN/firewall bypass (Clean DNS, WARP, Tailscale exit node, macOS VPN) with rollback."""

from __future__ import annotations

import atexit
import re
import time
from pathlib import Path
from typing import Any

from ..config import configured_exit_node, configured_exit_nodes
from ..state import atomic_write_json, read_json_dict, remove_file
from . import netsvc as _netsvc
from . import probes as _probes
from . import tailscale as _tailscale
from . import warp as _warp
from .common import (
    BYPASS_STATE_FILE,
    CLEAN_DNS_SERVERS,
    NO_EXIT_NODE_HINT,
    SYSTEM_TUNNEL_STATE_FILE,
    Runner,
    _default_runner,
)


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
        self.selected_exit_node: str | None = None

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
        service = _netsvc.detect_active_network_service(self.runner)
        if not service:
            notes.append("Warning: could not detect active macOS network service for DNS bypass")
            return notes

        prev_dns = _netsvc.get_dns_servers(service, self.runner)
        if prev_dns == list(CLEAN_DNS_SERVERS):
            notes.append(f"Clean DNS ({', '.join(CLEAN_DNS_SERVERS)}) already active on '{service}'")
            return notes

        cmd = _netsvc._dns_cmd(service, list(CLEAN_DNS_SERVERS), self.gui_sudo, self.runner)
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
        warp = _warp.find_warp_cli()
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
                notes.append(
                    f"Warning: could not set WARP mode to 'warp' ({mode_res.stderr.strip() or mode_res.stdout.strip()})"
                )

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
        warp = _warp.find_warp_cli()
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
                data = _tailscale._tailscale_status_json(ts, self.runner)
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

        return _tailscale._tailscale_status_json(ts, self.runner), notes

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
        ts = _tailscale.find_tailscale_cli(self.runner)
        if not ts:
            notes.append("Tailscale CLI not found (`brew install --cask tailscale-app`).")
            return notes

        target_node = configured_exit_node(self.exit_node) or _tailscale._tailscale_discover_exit_node(ts, self.runner)
        if not target_node:
            notes.append(f"Warning: {NO_EXIT_NODE_HINT}.")
            if self.fallback_warp and not self.dry_run:
                notes.append("Fallback enabled — activating Cloudflare WARP MASQUE (TCP 443) instead")
                notes.extend(self._connect_warp())
            return notes

        if self.dry_run:
            data = _tailscale._tailscale_status_json(ts, self.runner)
            state = str(data.get("BackendState") or "NotRunning") if data else "NotRunning"
            if state != "Running":
                need_boot = self.warp_bootstrap == "always"
                if self.warp_bootstrap == "auto":
                    cp_ok, _ = _probes.probe_tailscale_controlplane(timeout=2.0)
                    need_boot = not cp_ok
                if need_boot:
                    warp = _warp.find_warp_cli() or "warp-cli"
                    notes.append(f"[dry-run] FortiGate WARP bootstrap: {warp} connect -> {ts} up -> {warp} disconnect")
                else:
                    notes.append(f"[dry-run] {ts} up  (current Tailscale state: {state})")
            notes.append(f"[dry-run] {ts} set --exit-node={target_node} --exit-node-allow-lan-access=true")
            notes.append(f"[dry-run] {ts} ping -c 1 --timeout=3s {target_node}")
            return notes

        data = _tailscale._tailscale_status_json(ts, self.runner)
        if data is None and Path("/Applications/Tailscale.app").exists():
            self.runner(["open", "-g", "-a", "Tailscale"])
            for _ in range(16):
                time.sleep(0.5)
                data = _tailscale._tailscale_status_json(ts, self.runner)
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
                cp_ok, cp_detail = _probes.probe_tailscale_controlplane(timeout=2.5)
                if not cp_ok:
                    use_bootstrap = True
                    notes.append(
                        f"controlplane.tailscale.com blocked ({cp_detail}) — engaging FortiGate WARP bootstrap"
                    )

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
                    data = _tailscale._tailscale_status_json(ts, self.runner)
                    cur_state = str(data.get("BackendState") or "") if data else ""
                    if cur_state == "Running":
                        break
                    if cur_state == "NeedsLogin":
                        notes.append("Warning: Tailscale requires sign-in — open Tailscale.app and log in first.")
                        return notes
                    time.sleep(0.5)

                if (
                    (not data or str(data.get("BackendState") or "") != "Running")
                    and self.warp_bootstrap == "auto"
                    and _warp.find_warp_cli()
                ):
                    notes.append("Direct `tailscale up` stalled (possible FortiGate DPI) — retrying via WARP bootstrap")
                    data, boot_notes = self._warp_bootstrap_tailscale_up(ts)
                    notes.extend(boot_notes)

            if not data or str(data.get("BackendState") or "") != "Running":
                notes.append("Warning: Tailscale did not reach Running state (check Tailscale.app).")
                if self.fallback_warp:
                    notes.append("Fallback enabled — switching to Cloudflare WARP MASQUE (TCP 443) tunnel")
                    notes.extend(self._connect_warp())
                return notes

        self._prev_tailscale_exit_node = _tailscale._tailscale_active_exit_node(data)
        candidates = [] if self.exit_node else configured_exit_nodes()
        if len(candidates) > 1:
            chosen, ranked = _tailscale.select_exit_node(ts, candidates, data, self.runner)
            if chosen and chosen != target_node:
                timing = ", ".join(f"{n} {f'{r:.0f} ms' if r is not None else 'n/a'}" for n, r in ranked)
                notes.append(f"Picked exit node {chosen} (lowest RTT: {timing})")
                target_node = chosen
        self.selected_exit_node = target_node
        peer = _tailscale._tailscale_find_peer(data, target_node)

        # Right after `tailscale up`, the netmap peer table can take a couple seconds to populate.
        if peer is None and (self._tailscale_started_by_us or not data.get("Peer")):
            for _ in range(8):
                time.sleep(0.5)
                refreshed = _tailscale._tailscale_status_json(ts, self.runner)
                if refreshed:
                    data = refreshed
                    peer = _tailscale._tailscale_find_peer(data, target_node)
                    if peer is not None:
                        break

        if peer is None:
            avail = _tailscale._tailscale_list_exit_nodes(data)
            msg = (
                f"Warning: Tailscale exit node {target_node} is not in your tailnet yet (waiting for share/ACL access)."
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
        already_using_target = bool(prev_exit and (prev_exit == target_node.strip().lower() or prev_exit in peer_ips))

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
                chk = _tailscale._tailscale_status_json(ts, self.runner)
                ex_st = chk.get("ExitNodeStatus") if chk else None
                if isinstance(ex_st, dict) and ex_st.get("Online"):
                    break
                time.sleep(0.5)

        ping_res = self.runner([ts, "ping", "-c", "1", "--timeout=3s", target_node])
        path_info = self._parse_tailscale_ping(ping_res.stdout) if ping_res.returncode == 0 else None
        egress_ok, egress_info = _probes.probe_egress_via_tunnel(timeout=4.0)

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
            elif _warp.find_warp_cli():
                notes.extend(self._connect_warp())
            else:
                ts = _tailscale.find_tailscale_cli(self.runner)
                ts_node = _tailscale._tailscale_discover_exit_node(ts, self.runner) if ts else None
                if ts_node:
                    notes.extend(self._connect_tailscale())
                elif not self.dry_run and not _probes._stun_check("stun.l.google.com", 19302, timeout=1.5):
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
            servers = list(self._prev_dns) if self._prev_dns else ["empty"]
            dns_restore = " ".join(servers)
            res = self.runner(_netsvc._dns_cmd(self._dns_service, servers, self.gui_sudo, self.runner))
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
        if (
            data.get("warp_connected_by_us")
            or data.get("tailscale_exit_set_by_us")
            or data.get("tailscale_started_by_us")
        ):
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
        prev_dns = [str(x) for x in (data.get("prev_dns") or [])]
        servers = prev_dns or ["empty"]
        dns_restore = " ".join(servers)
        res = runner(_netsvc._dns_cmd(str(dns_service), servers, gui_sudo, runner))
        if res.returncode == 0:
            notes.append(f"Restored original DNS ({dns_restore}) on '{dns_service}'")
        else:
            notes.append(f"Warning: failed to restore DNS on '{dns_service}' ({res.stderr.strip()})")

    remove_file(state_file)
    return notes
