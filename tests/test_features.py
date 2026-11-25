"""Smaller features: tunnel notifications, exit-node selection, profiles, bundle freshness, onboarding."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from senza.state import atomic_write_json


def ok(cmd: list[str], out: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(cmd, 0, out, "")


class TestTunnelNotifications(unittest.TestCase):
    def test_backend_change_messages(self) -> None:
        from senza.firewall.system_tunnel import _backend_change_message as msg

        self.assertIsNone(msg(None, "tailscale", "100.64.0.1"))  # first run: no banner
        self.assertIsNone(msg("tailscale", "tailscale", "100.64.0.1"))
        self.assertIn("WARP", msg("tailscale", "warp", "100.64.0.1") or "")
        self.assertIn("100.64.0.1", msg("warp", "tailscale", "100.64.0.1") or "")
        self.assertIn("down", msg("warp", "none", "x") or "")

    def test_ensure_posts_notification_on_switch(self) -> None:
        from senza.firewall import system_tunnel

        calls: list[list[str]] = []

        def runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            return ok(cmd)

        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "tunnel.json"
            atomic_write_json(state, {"active_backend": "tailscale", "target_exit_node": "100.64.0.1"})

            def fake_up(**kw: object) -> list[str]:
                atomic_write_json(state, {"active_backend": "warp", "target_exit_node": "100.64.0.1"})
                return ["fell back"]

            with (
                mock.patch.object(system_tunnel, "system_tunnel_up", side_effect=fake_up),
                mock.patch("senza.firewall.tailscale.find_tailscale_cli", return_value=None),
                mock.patch.dict(os.environ, {"SENZA_NO_NOTIFY": "0"}),
            ):
                notes = system_tunnel.system_tunnel_ensure(exit_node="100.64.0.1", runner=runner, state_file=state)
        osa = [c for c in calls if c[0] == "osascript"]
        self.assertEqual(len(osa), 1)
        self.assertIn("Cloudflare WARP", osa[0][2])
        self.assertTrue(any(n.startswith("Notified:") for n in notes))

    def test_notify_escapes_and_can_be_disabled(self) -> None:
        from senza.notify import notify

        calls: list[list[str]] = []
        with mock.patch.dict(os.environ, {"SENZA_NO_NOTIFY": "0"}):
            notify('Say "hi"', "a\\b", runner=lambda c: (calls.append(c), ok(c))[1])
        self.assertIn('\\"hi\\"', calls[0][2])
        with mock.patch.dict(os.environ, {"SENZA_NO_NOTIFY": "1"}):
            self.assertFalse(notify("t", "b", runner=lambda c: ok(c)))


class TestBundleFreshness(unittest.TestCase):
    def test_status_tracks_client_updates(self) -> None:
        from senza import app_bridge

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / "RemotePlay.app"
            binary = src / "Contents" / "MacOS" / "RemotePlay"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"v1")
            patched = root / "RemotePlay-patched.app"
            stamp = root / "stamp"
            with (
                mock.patch.multiple(app_bridge, PATCHED_SONY_APP=patched, SONY_STAMP_FILE=stamp),
                mock.patch.object(app_bridge, "find_app_binary", return_value=binary),
            ):
                self.assertEqual(app_bridge.bundle_status(None, "sony"), "missing")
                self.assertEqual(app_bridge.bundle_status(src, "sony"), "stale")  # never patched
                patched.mkdir()
                stamp.write_text(app_bridge._bundle_signature_stamp(src, "sony"))
                self.assertEqual(app_bridge.bundle_status(src, "sony"), "ready")
                binary.write_bytes(b"v2-after-app-store-update")
                self.assertEqual(app_bridge.bundle_status(src, "sony"), "stale")

    def test_repatch_agent_watches_client_bundles(self) -> None:
        import plistlib

        from senza.firewall import launchd

        with tempfile.TemporaryDirectory() as tmp:
            plist = Path(tmp) / "agent.plist"
            with mock.patch.object(launchd, "TUNNEL_WATCHDOG_LOG", Path(tmp) / "x.log"):
                launchd.install_repatch_agent(runner=ok, plist_path=plist, cli_path="/x/senza")
            data = plistlib.loads(plist.read_bytes())
            self.assertEqual(data["ProgramArguments"], ["/x/senza", "setup", "--if-needed"])
            self.assertIn("/Applications/RemotePlay.app/Contents/Info.plist", data["WatchPaths"])
            launchd.uninstall_repatch_agent(runner=ok, plist_path=plist)
            self.assertFalse(plist.exists())


class TestOnboard(unittest.TestCase):
    def test_summary_only_blocks_on_required(self) -> None:
        from senza.onboard import Check, summary

        res = summary([Check("a", "A", True, True), Check("b", "B", False, False, fix="x")])
        self.assertTrue(res["ready"])
        res = summary([Check("a", "A", False, True, fix="senza setup"), Check("b", "B", True, False)])
        self.assertFalse(res["ready"])
        self.assertEqual(res["missing_required"], ["a"])
        self.assertEqual(res["checks"][0]["fix"], "senza setup")

    def test_cli_json_shape(self) -> None:
        import contextlib
        import io
        import json

        from senza.cli import main

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            main(["onboard", "--json"])
        data = json.loads(buf.getvalue())
        self.assertIn("ready", data)
        self.assertTrue({"clt", "bridges", "client", "bundle", "cli", "helper"} <= {c["id"] for c in data["checks"]})


class TestExitNodeSelection(unittest.TestCase):
    DATA = {
        "Peer": {
            "a": {"TailscaleIPs": ["100.64.0.1"], "ExitNodeOption": True, "Online": True, "HostName": "home"},
            "b": {"TailscaleIPs": ["100.64.0.2"], "ExitNodeOption": True, "Online": True, "HostName": "office"},
            "c": {"TailscaleIPs": ["100.64.0.3"], "ExitNodeOption": True, "Online": False, "HostName": "off"},
            "d": {"TailscaleIPs": ["100.64.0.4"], "ExitNodeOption": False, "Online": True, "HostName": "noexit"},
        }
    }

    def _runner(self, rtts: dict[str, float | None]):  # type: ignore[no-untyped-def]
        def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            node = cmd[-1]
            rtt = rtts.get(node)
            if rtt is None:
                return subprocess.CompletedProcess(cmd, 1, "", "timeout")
            return ok(cmd, f"pong from x ({node}) via DERP(fra) in {rtt}ms\n")

        return run

    def test_faster_node_wins_only_beyond_margin(self) -> None:
        from senza.firewall.tailscale import select_exit_node

        cands = ["100.64.0.1", "100.64.0.2", "100.64.0.3", "100.64.0.4"]
        chosen, ranked = select_exit_node("ts", cands, self.DATA, self._runner({"100.64.0.1": 40, "100.64.0.2": 12}))
        self.assertEqual(chosen, "100.64.0.2")
        self.assertEqual({n for n, _ in ranked}, {"100.64.0.1", "100.64.0.2"})  # offline / non-exit skipped
        chosen, _ = select_exit_node("ts", cands, self.DATA, self._runner({"100.64.0.1": 18, "100.64.0.2": 12}))
        self.assertEqual(chosen, "100.64.0.1")  # within 10 ms: keep the primary
        chosen, _ = select_exit_node("ts", cands, self.DATA, self._runner({}))
        self.assertEqual(chosen, "100.64.0.1")  # nothing answers: primary
        chosen, _ = select_exit_node("ts", ["100.64.0.3"], self.DATA, self._runner({}))
        self.assertEqual(chosen, "100.64.0.3")  # no usable node: return primary for a clear error later


if __name__ == "__main__":
    unittest.main()
