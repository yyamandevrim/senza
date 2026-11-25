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


if __name__ == "__main__":
    unittest.main()
