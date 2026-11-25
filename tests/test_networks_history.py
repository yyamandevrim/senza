"""Per-network profiles (router fingerprint) and connection history."""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from senza import history, networks
from senza.net_probe import NetworkReport
from senza.stream_profile import recommend_preset

LIST_OUT = """  subKey [0] = State:/Network/Service/AAAA-1111/IPv4
  subKey [1] = State:/Network/Service/BBBB-2222/IPv4
"""
SHOW = {
    "AAAA-1111": """<dictionary> {
  InterfaceName : en0
  NetworkSignature : IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=8:5b:e:38:60:54
  Router : 192.168.1.1
}""",
    "BBBB-2222": """<dictionary> {
  InterfaceName : utun8
  Router : 100.90.0.1
}""",
}


def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    script = cmd[-1] if cmd else ""
    if "list State:" in script:
        return subprocess.CompletedProcess(cmd, 0, LIST_OUT, "")
    for sid, body in SHOW.items():
        if f"show State:/Network/Service/{sid}/IPv4" in script:
            return subprocess.CompletedProcess(cmd, 0, body, "")
    return subprocess.CompletedProcess(cmd, 0, "", "")


class TestNetworks(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self._env = mock.patch.dict(os.environ, {"SENZA_CONFIG": str(Path(self._tmp.name) / "config.json")})
        self._env.start()

    def tearDown(self) -> None:
        self._env.stop()
        self._tmp.cleanup()

    def test_fingerprint_uses_physical_router_mac_not_vpn(self) -> None:
        net = networks.current_network(fake_runner)
        assert net is not None
        self.assertEqual(net.interface, "en0")
        self.assertEqual(net.router_mac, "08:5b:0e:38:60:54")
        self.assertEqual(net.id, networks.network_id_for("08:5B:0E:38:60:54"))
        self.assertIsNone(net.name)

    def test_no_physical_network(self) -> None:
        def only_vpn(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            if "list State:" in cmd[-1]:
                return subprocess.CompletedProcess(cmd, 0, "  subKey [0] = State:/Network/Service/BBBB-2222/IPv4\n", "")
            return fake_runner(cmd)

        self.assertIsNone(networks.current_network(only_vpn))

    def test_save_apply_and_explicit_flags_win(self) -> None:
        net = networks.current_network(fake_runner)
        assert net is not None
        networks.save_profile(net, name="Ofis", bypass="tailscale", privileged=True, preset="wan-balanced")
        self.assertEqual(networks.current_network(fake_runner).name, "Ofis")  # type: ignore[union-attr]

        args = argparse.Namespace(
            bypass_firewall=None,
            privileged=False,
            preset="auto",
            exit_node=None,
            warp_bootstrap="auto",
            fallback_warp=False,
        )
        applied = networks.apply_to_start_args(args, explicit={"preset"}, runner=fake_runner)
        assert applied is not None
        self.assertEqual(args.bypass_firewall, "tailscale")
        self.assertTrue(args.privileged)
        self.assertEqual(args.preset, "auto")  # user typed --preset, profile must not override it
        self.assertIn("bypass=tailscale", applied.changes)

    def test_bypass_off_clears_and_validation(self) -> None:
        net = networks.current_network(fake_runner)
        assert net is not None
        networks.save_profile(net, bypass="off")
        args = argparse.Namespace(bypass_firewall="auto", privileged=False, preset="auto", exit_node=None)
        networks.apply_to_start_args(args, explicit=set(), runner=fake_runner)
        self.assertIsNone(args.bypass_firewall)
        with self.assertRaises(ValueError):
            networks.save_profile(net, bypass="nonsense")
        self.assertTrue(networks.forget_profile(net.id))
        self.assertFalse(networks.forget_profile(net.id))

    def test_cli_explicit_dest_detection(self) -> None:
        from senza.cli import _explicit_dests, build_parser

        parser = build_parser()
        explicit = _explicit_dests(parser, ["start", "--privileged", "--preset=wan-high", "--client", "sony"])
        self.assertEqual(explicit, {"privileged", "preset", "client"})


class TestHistory(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.db = Path(self._tmp.name) / "h.sqlite3"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _report(self, rtt: float, jitter: float, loss: float) -> NetworkReport:
        return NetworkReport(host="1.1.1.1", rtt_median_ms=rtt, jitter_ms=jitter, packet_loss_pct=loss, ipv4_ok=True)

    def test_stats_and_sessions(self) -> None:
        for rtt, jit in [(20, 2), (22, 3), (25, 4), (60, 20), (21, 2)]:
            history.record_probe(self._report(rtt, jit, 0.0), "net1", "doctor", path=self.db)
        history.record_probe(self._report(90, 30, 5.0), "other", "doctor", path=self.db)
        sid = history.start_session("net1", "sony", "kbm", None, path=self.db)
        with mock.patch("senza.history.time.time", return_value=time.time() + 1800):
            history.end_session(sid, 0, path=self.db)

        st = history.network_stats("net1", path=self.db)
        self.assertEqual(st.probes, 5)
        self.assertEqual(st.rtt_median_ms, 22.0)
        self.assertEqual(st.sessions, 1)
        self.assertAlmostEqual(st.play_minutes, 30.0, delta=0.5)
        self.assertEqual(set(history.known_networks(path=self.db)), {"net1", "other"})
        self.assertEqual(len(history.recent_probes("net1", path=self.db)), 5)

    def test_conservative_preset_uses_worse_of_history_and_now(self) -> None:
        for _ in range(6):
            history.record_probe(self._report(55, 15, 1.0), "jittery", "doctor", path=self.db)
        lucky = self._report(18, 1.5, 0.0)
        self.assertEqual(recommend_preset(lucky).name, "wan-high")
        blended = history.conservative_report(lucky, history.network_stats("jittery", path=self.db))
        self.assertNotEqual(recommend_preset(blended).name, "wan-high")

    def test_history_never_raises(self) -> None:
        bad = Path(self._tmp.name) / "dir-not-db"
        bad.mkdir()
        history.record_probe(self._report(20, 2, 0), "x", "doctor", path=bad)  # sqlite error swallowed
        self.assertIsNone(history.start_session("x", "sony", "kbm", None, path=bad))


if __name__ == "__main__":
    unittest.main()
