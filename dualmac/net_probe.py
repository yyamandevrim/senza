"""WAN network diagnostics and macOS Wi-Fi/AWDL inspection."""

from __future__ import annotations

import re
import statistics
import subprocess
from dataclasses import dataclass, field
from typing import Callable


CommandRunner = Callable[[list[str], float], subprocess.CompletedProcess[str]]

BACKGROUND_BANDWIDTH_PROCS = (
    "cloudd",
    "bird",
    "backupd",
    "Dropbox",
    "OneDrive",
    "GoogleDriveFS",
    "Transmission",
    "qbittorrent",
)


@dataclass
class NetworkReport:
    host: str
    rtt_median_ms: float | None = None
    rtt_p95_ms: float | None = None
    jitter_ms: float | None = None
    packet_loss_pct: float = 100.0
    ipv4_ok: bool = False
    mtu_1500_ok: bool | None = None
    default_interface: str = "unknown"
    is_wifi: bool = False
    awdl_active: bool = False
    noisy_processes: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def _default_runner(cmd: list[str], timeout: float = 15.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)


def parse_ping_output(stdout: str) -> tuple[float | None, float | None, float | None, float]:
    """Parse macOS ping output into (median_ms, p95_ms, jitter_ms, packet_loss_pct)."""
    times = [float(m) for m in re.findall(r"time=([0-9]+(?:\.[0-9]+)?)\s*ms", stdout)]
    loss_match = re.search(r"([0-9]+(?:\.[0-9]+)?)%\s+packet loss", stdout)
    loss_pct = float(loss_match.group(1)) if loss_match else (0.0 if times else 100.0)

    if not times:
        return None, None, None, loss_pct

    times_sorted = sorted(times)
    median = statistics.median(times_sorted)
    p95_idx = min(len(times_sorted) - 1, max(0, int(round(0.95 * (len(times_sorted) - 1)))))
    p95 = times_sorted[p95_idx]
    jitter = max(0.0, p95 - median)
    return round(median, 2), round(p95, 2), round(jitter, 2), round(loss_pct, 2)


def probe_network(
    host: str = "1.1.1.1",
    count: int = 15,
    runner: CommandRunner = _default_runner,
) -> NetworkReport:
    report = NetworkReport(host=host)

    # 1. Latency, jitter, packet loss (IPv4 explicitly since PS Remote Play WAN is IPv4)
    try:
        res = runner(["ping", "-c", str(count), "-i", "0.2", "-W", "1000", host], 15.0)
        med, p95, jitter, loss = parse_ping_output(res.stdout)
        report.rtt_median_ms = med
        report.rtt_p95_ms = p95
        report.jitter_ms = jitter
        report.packet_loss_pct = loss
        report.ipv4_ok = med is not None and loss < 100.0
    except (subprocess.TimeoutExpired, OSError):
        report.warnings.append(f"Ping probe to {host} timed out or failed.")

    # 2. MTU fragmentation probe (1472 payload + 28 IP/ICMP = 1500)
    if report.ipv4_ok:
        try:
            mtu_res = runner(["ping", "-D", "-s", "1472", "-c", "1", "-W", "1000", host], 5.0)
            report.mtu_1500_ok = mtu_res.returncode == 0
            if not report.mtu_1500_ok:
                report.warnings.append("MTU < 1500 detected (PPPoE/VPN/hotspot); keep bitrate moderate.")
        except (subprocess.TimeoutExpired, OSError):
            report.mtu_1500_ok = None

    # 3. Default network interface & Wi-Fi check
    try:
        route_res = runner(["route", "-n", "get", "default"], 5.0)
        m = re.search(r"interface:\s+(\S+)", route_res.stdout)
        if m:
            report.default_interface = m.group(1)
        ports_res = runner(["networksetup", "-listallhardwareports"], 5.0)
        wifi_match = re.search(
            r"Hardware Port:\s*Wi-Fi\s*\nDevice:\s*(\S+)", ports_res.stdout, re.IGNORECASE
        )
        if wifi_match and wifi_match.group(1) == report.default_interface:
            report.is_wifi = True
    except (subprocess.TimeoutExpired, OSError):
        pass

    # 4. AWDL (AirDrop/Handoff Wi-Fi channel hopping) check
    try:
        awdl_res = runner(["ifconfig", "awdl0"], 5.0)
        if awdl_res.returncode == 0 and "<UP," in awdl_res.stdout and "status: active" in awdl_res.stdout:
            report.awdl_active = True
            if report.is_wifi:
                report.warnings.append(
                    "awdl0 (AirDrop/Handoff) is active on Wi-Fi — causes 30-100ms lag spikes. "
                    "Use `dualmac start --privileged` to pause awdl0 during play."
                )
    except (subprocess.TimeoutExpired, OSError):
        pass

    # 5. Background bandwidth consumers check (read-only warning, never kills)
    try:
        ps_res = runner(["ps", "-A", "-o", "comm="], 5.0)
        running_names = {line.strip().rsplit("/", 1)[-1] for line in ps_res.stdout.splitlines() if line.strip()}
        found = [p for p in BACKGROUND_BANDWIDTH_PROCS if p in running_names]
        report.noisy_processes = found
    except (subprocess.TimeoutExpired, OSError):
        pass

    if not report.ipv4_ok:
        report.warnings.append("IPv4 connectivity check failed — PS5 Remote Play over PSN requires IPv4.")
    elif report.packet_loss_pct >= 2.0:
        report.warnings.append(
            f"High packet loss ({report.packet_loss_pct}%) — switching to wan-lowbw (720p60) recommended."
        )
    elif report.jitter_ms is not None and report.jitter_ms >= 20.0:
        report.warnings.append(
            f"High jitter ({report.jitter_ms} ms) — prefer Ethernet or pause awdl0 (--privileged)."
        )

    return report
