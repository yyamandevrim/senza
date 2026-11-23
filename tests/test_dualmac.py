"""Focused unit tests for DualMac WAN probe, adaptive stream presets, profiles, and rollback."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

from dualmac.net_probe import NetworkReport, parse_ping_output
from dualmac.profiles import export_runtime_config, load_profile
from dualmac.stream_profile import apply_stream_preset, recommend_preset
from dualmac.sys_optimizer import SystemOptimizer


class TestDualMac(unittest.TestCase):
    def test_parse_ping_and_recommend_presets(self) -> None:
        sample = "\n".join(
            [
                "PING 1.1.1.1 (1.1.1.1): 56 data bytes",
                "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=18.2 ms",
                "64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=19.0 ms",
                "64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=20.1 ms",
                "64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=21.5 ms",
                "4 packets transmitted, 4 packets received, 0.0% packet loss",
            ]
        )
        med, p95, jitter, loss = parse_ping_output(sample)
        self.assertAlmostEqual(med, 19.55, places=1)
        self.assertEqual(loss, 0.0)
        self.assertLess(jitter, 5.0)

        high = recommend_preset(NetworkReport(host="h", rtt_median_ms=med, jitter_ms=jitter, packet_loss_pct=loss, ipv4_ok=True))
        self.assertEqual(high.name, "wan-high")

        balanced = recommend_preset(NetworkReport(host="h", rtt_median_ms=52.0, jitter_ms=14.0, packet_loss_pct=1.0, ipv4_ok=True))
        self.assertEqual(balanced.name, "wan-balanced")

        lowbw = recommend_preset(NetworkReport(host="h", rtt_median_ms=45.0, jitter_ms=10.0, packet_loss_pct=3.5, ipv4_ok=True))
        self.assertEqual(lowbw.name, "wan-lowbw")
        self.assertEqual(lowbw.resolution, "720p")
        self.assertEqual(lowbw.fps, 60)

    def test_gta6_profile_export(self) -> None:
        profile = load_profile("gta6")
        with tempfile.TemporaryDirectory() as tmp:
            out = export_runtime_config(profile, Path(tmp) / "runtime.cfg")
            text = out.read_text(encoding="utf-8")
            self.assertIn("toggle_capture_key=29", text)    # '0' key (Karabiner-safe)
            self.assertIn("toggle_vehicle_key=5", text)     # G
            self.assertIn("trackpad_mode=1", text)
            self.assertIn("on_foot.59=L2", text)            # CapsLock/LeftControl -> L2 Aim
            self.assertIn("on_foot.200=R2", text)           # Trackpad click -> R2 Shoot
            self.assertIn("vehicle.13=R2", text)            # W -> R2 gas in vehicle mode

    def test_stream_preset_defaults_backup_and_apply(self) -> None:
        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with tempfile.TemporaryDirectory() as tmp:
            backup = Path(tmp) / "backup.plist"
            preset = recommend_preset(NetworkReport(host="h", rtt_median_ms=45.0, jitter_ms=12.0, packet_loss_pct=0.5, ipv4_ok=True))
            apply_stream_preset(preset, disable_builtin_kbm=True, dry_run=False, backup_path=backup, runner=fake_runner)

        self.assertEqual(calls[0][:2], ["defaults", "export"])
        joined = [" ".join(c) for c in calls]
        self.assertTrue(any("settings.codec_remote_ps5 -string h265" in s for s in joined))
        self.assertTrue(any("settings.bitrate_remote_ps5 -int 10000" in s for s in joined))
        self.assertTrue(any("settings.mouse_touch_enabled -bool NO" in s for s in joined))

    def test_sys_optimizer_privileged_rollback(self) -> None:
        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            if cmd[:2] == ["sysctl", "-n"]:
                defaults = {
                    "net.inet.udp.recvspace": "786896",
                    "net.inet.udp.maxdgram": "9216",
                    "net.inet.tcp.delayed_ack": "3",
                }
                return subprocess.CompletedProcess(cmd, 0, defaults.get(cmd[2], "0") + "\n", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with tempfile.TemporaryDirectory() as tmp:
            state_file = Path(tmp) / "state.json"
            opt = SystemOptimizer(
                privileged=True,
                dry_run=False,
                runner=fake_runner,
                state_file=state_file,
                enable_watchdog=False,
            )
            opt.enter()
            joined_enter = " ".join(" ".join(c) for c in calls)
            self.assertIn("ifconfig awdl0 down", joined_enter)
            self.assertIn("ifconfig llw0 down", joined_enter)
            self.assertIn("sysctl -w net.inet.udp.recvspace=4194304", joined_enter)
            self.assertIn("sysctl -w net.inet.tcp.delayed_ack=0", joined_enter)
            self.assertTrue(state_file.exists())

            opt.exit()
            joined_all = " ".join(" ".join(c) for c in calls)
            self.assertIn("ifconfig awdl0 up", joined_all)
            self.assertIn("ifconfig llw0 up", joined_all)
            self.assertIn("sysctl -w net.inet.udp.recvspace=786896", joined_all)
            self.assertIn("sysctl -w net.inet.tcp.delayed_ack=3", joined_all)
            self.assertFalse(state_file.exists())

    def test_firewall_bypass_dns_and_rollback(self) -> None:
        from dualmac.firewall_bypass import FirewallBypass

        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            if cmd[:3] == ["route", "-n", "get"]:
                return subprocess.CompletedProcess(cmd, 0, "   interface: en0\n", "")
            if cmd == ["networksetup", "-listnetworkserviceorder"]:
                out = "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n"
                return subprocess.CompletedProcess(cmd, 0, out, "")
            if cmd[:2] == ["networksetup", "-getdnsservers"]:
                return subprocess.CompletedProcess(cmd, 0, "There aren't any DNS Servers set on Wi-Fi.\n", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with tempfile.TemporaryDirectory() as tmp:
            state_file = Path(tmp) / "bypass_state.json"
            fb = FirewallBypass(mode="dns", dry_run=False, runner=fake_runner, state_file=state_file)
            fb.enter()
            joined_enter = " ".join(" ".join(c) for c in calls)
            self.assertIn("networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1", joined_enter)
            self.assertIn("dscacheutil -flushcache", joined_enter)
            self.assertTrue(state_file.exists())

            fb.exit()
            joined_all = " ".join(" ".join(c) for c in calls)
            self.assertIn("networksetup -setdnsservers Wi-Fi empty", joined_all)
            self.assertFalse(state_file.exists())


if __name__ == "__main__":
    unittest.main()
