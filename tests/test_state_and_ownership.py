"""Tests for crash-safe state, the root AWDL watchdog script, and session-vs-system-tunnel ownership."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

os.environ["SENZA_CONFIG"] = str(Path(tempfile.mkdtemp(prefix="senza-test-cfg-")) / "config.json")
os.environ.pop("SENZA_EXIT_NODE", None)

from senza.state import atomic_write_json, read_json_dict  # noqa: E402
from senza.sys_optimizer import SystemOptimizer, build_root_p2p_watchdog  # noqa: E402


def _ok(cmd: list[str], out: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(cmd, 0, out, "")


class TestAtomicState(unittest.TestCase):
    def test_atomic_write_roundtrip_and_no_temp_leftovers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sub" / "state.json"
            atomic_write_json(path, {"a": 1})
            atomic_write_json(path, {"a": 2})
            self.assertEqual(read_json_dict(path), {"a": 2})
            self.assertEqual([p.name for p in path.parent.iterdir()], ["state.json"])

    def test_failed_write_keeps_previous_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            atomic_write_json(path, {"keep": True})
            with self.assertRaises(TypeError):
                atomic_write_json(path, {"bad": object()})
            self.assertEqual(read_json_dict(path), {"keep": True})
            self.assertEqual(len(list(Path(tmp).iterdir())), 1)

    def test_read_json_dict_tolerates_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            path.write_text('{"trunc', encoding="utf-8")
            self.assertEqual(read_json_dict(path), {})
            path.write_text("[1, 2]", encoding="utf-8")
            self.assertEqual(read_json_dict(path), {})
            self.assertEqual(read_json_dict(Path(tmp) / "missing.json"), {})


class TestRootP2PWatchdog(unittest.TestCase):
    """Runs the generated root watchdog for real (unprivileged) against fake ifconfig/sysctl binaries."""

    def _make_fake_tools(self, bindir: Path, log: Path, iface_state: Path) -> None:
        ifconfig = bindir / "ifconfig"
        ifconfig.write_text(
            "#!/bin/sh\n"
            f'echo "ifconfig $*" >> "{log}"\n'
            'if [ "$#" -eq 1 ]; then\n'
            f'  if [ -f "{iface_state}.$1.down" ]; then echo "$1: flags=8802<BROADCAST,SIMPLEX>"; '
            'else echo "$1: flags=8843<UP,BROADCAST,RUNNING>"; fi\n'
            "fi\n"
            f'if [ "$2" = "down" ]; then touch "{iface_state}.$1.down"; fi\n'
            f'if [ "$2" = "up" ]; then rm -f "{iface_state}.$1.down"; fi\n',
            encoding="utf-8",
        )
        sysctl = bindir / "sysctl"
        sysctl.write_text(f'#!/bin/sh\necho "sysctl $*" >> "{log}"\n', encoding="utf-8")
        for tool in (ifconfig, sysctl):
            tool.chmod(tool.stat().st_mode | stat.S_IEXEC)

    def test_watchdog_keeps_iface_down_then_restores_when_lease_removed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bindir = root / "bin"
            bindir.mkdir()
            log = root / "calls.log"
            iface_state = root / "iface"
            self._make_fake_tools(bindir, log, iface_state)
            lease = root / "p2p watchdog.lease"
            ack = root / "p2p watchdog.lease.ack"
            lease.write_text("x")
            ack.write_text("x")

            script = build_root_p2p_watchdog(
                ["awdl0"], {"net.inet.udp.recvspace": "786896"}, os.getpid(), lease, interval_s=1
            )
            env = {**os.environ, "PATH": f"{bindir}:/usr/bin:/bin"}
            subprocess.run(["/bin/sh", "-c", script], env=env, check=True, timeout=5)

            # macOS "re-enables" awdl0 behind our back -> watchdog must re-down it.
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline and not Path(f"{iface_state}.awdl0.down").exists():
                time.sleep(0.1)
            self.assertTrue(Path(f"{iface_state}.awdl0.down").exists(), "watchdog did not re-pause awdl0")

            lease.unlink()
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline and ack.exists():
                time.sleep(0.1)
            self.assertFalse(ack.exists(), "watchdog did not acknowledge rollback")
            calls = log.read_text()
            self.assertIn("ifconfig awdl0 up", calls)
            self.assertIn("sysctl -w net.inet.udp.recvspace=786896", calls)

    def test_watchdog_restores_when_parent_dies(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bindir = root / "bin"
            bindir.mkdir()
            log = root / "calls.log"
            self._make_fake_tools(bindir, log, root / "iface")
            lease = root / "w.lease"
            ack = root / "w.lease.ack"
            lease.write_text("x")
            ack.write_text("x")

            parent = subprocess.Popen(["sleep", "30"])
            try:
                script = build_root_p2p_watchdog(["awdl0"], {}, parent.pid, lease, interval_s=1)
                env = {**os.environ, "PATH": f"{bindir}:/usr/bin:/bin"}
                subprocess.run(["/bin/sh", "-c", script], env=env, check=True, timeout=5)
            finally:
                parent.kill()
                parent.wait()

            deadline = time.monotonic() + 4
            while time.monotonic() < deadline and ack.exists():
                time.sleep(0.1)
            self.assertFalse(lease.exists())
            self.assertFalse(ack.exists())
            self.assertIn("ifconfig awdl0 up", log.read_text())

    def test_gui_sudo_path_starts_root_watchdog_in_single_prompt(self) -> None:
        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            if cmd[:2] == ["sysctl", "-n"]:
                return _ok(cmd, "9216\n")
            return _ok(cmd)

        with tempfile.TemporaryDirectory() as tmp:
            lease = Path(tmp) / "w.lease"
            opt = SystemOptimizer(
                privileged=True,
                gui_sudo=True,
                runner=fake_runner,
                state_file=Path(tmp) / "state.json",
                lease_file=lease,
            )
            with mock.patch("senza.sys_optimizer.subprocess.Popen"), mock.patch("senza.sys_optimizer.atexit.register"), \
                    mock.patch("senza.sys_optimizer.signal.signal"):
                notes = opt.enter()
            osa = [c for c in calls if c and c[0] == "osascript"]
            self.assertEqual(len(osa), 1, "exactly one Touch ID / password prompt on enter")
            self.assertIn("nohup /bin/sh -c", osa[0][2])
            self.assertIn("ifconfig awdl0 down", osa[0][2])
            self.assertTrue(any("Root AWDL watchdog active" in n for n in notes))
            self.assertTrue(json.loads((Path(tmp) / "state.json").read_text())["root_watchdog"])

            # Simulate the root watchdog finishing rollback as soon as the lease is dropped.
            Path(str(lease) + ".ack").unlink()
            calls.clear()
            exit_notes = opt.exit()
            self.assertFalse([c for c in calls if c and c[0] in ("osascript", "sudo")], "no second prompt on exit")
            self.assertFalse(lease.exists())
            self.assertTrue(any("Restored awdl0" in n or "Restored" in n for n in exit_notes))


class TestSessionVsSystemTunnelOwnership(unittest.TestCase):
    def test_session_exit_keeps_routing_owned_by_system_tunnel(self) -> None:
        from senza.firewall_bypass import FirewallBypass

        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            return _ok(cmd)

        with tempfile.TemporaryDirectory() as tmp:
            session_state = Path(tmp) / "bypass_state.json"
            system_state = Path(tmp) / "system_tunnel.json"
            atomic_write_json(system_state, {"persistent": True, "target_exit_node": "100.64.0.9"})

            fb = FirewallBypass(
                mode="tailscale",
                runner=fake_runner,
                state_file=session_state,
                system_state_file=system_state,
            )
            fb._active = True
            fb._tailscale_cli = "/usr/local/bin/tailscale"
            fb._tailscale_exit_set_by_us = True
            fb._warp_cli = "/usr/local/bin/warp-cli"
            fb._warp_connected_by_us = True
            notes = fb.exit()

            self.assertFalse([c for c in calls if "set" in c or "disconnect" in c or "down" in c])
            self.assertTrue(any("owned by system-wide tunnel" in n for n in notes))

    def test_session_exit_tears_down_when_no_system_tunnel(self) -> None:
        from senza.firewall_bypass import FirewallBypass

        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            return _ok(cmd)

        with tempfile.TemporaryDirectory() as tmp:
            fb = FirewallBypass(
                mode="tailscale",
                runner=fake_runner,
                state_file=Path(tmp) / "bypass_state.json",
                system_state_file=Path(tmp) / "system_tunnel.json",
            )
            fb._active = True
            fb._tailscale_cli = "/usr/local/bin/tailscale"
            fb._tailscale_exit_set_by_us = True
            fb.exit()
            self.assertIn(["/usr/local/bin/tailscale", "set", "--exit-node="], calls)

    def test_crash_restore_defers_to_system_tunnel(self) -> None:
        from senza.firewall_bypass import restore_firewall_bypass

        calls: list[list[str]] = []

        def fake_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            return _ok(cmd)

        with tempfile.TemporaryDirectory() as tmp:
            session_state = Path(tmp) / "bypass_state.json"
            system_state = Path(tmp) / "system_tunnel.json"
            atomic_write_json(system_state, {"persistent": True})
            atomic_write_json(
                session_state,
                {"tailscale_exit_set_by_us": True, "tailscale_cli": "ts", "warp_connected_by_us": True, "warp_cli": "w"},
            )
            notes = restore_firewall_bypass(runner=fake_runner, state_file=session_state, system_state_file=system_state)
            self.assertEqual(calls, [])
            self.assertFalse(session_state.exists())
            self.assertTrue(any("owned by system-wide tunnel" in n for n in notes))


class TestUserConfig(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self._old = os.environ.get("SENZA_CONFIG")
        os.environ["SENZA_CONFIG"] = str(Path(self._tmp.name) / "cfg" / "config.json")

    def tearDown(self) -> None:
        if self._old is not None:
            os.environ["SENZA_CONFIG"] = self._old
        self._tmp.cleanup()

    def test_no_exit_node_by_default(self) -> None:
        from senza.config import configured_exit_node

        self.assertIsNone(configured_exit_node())

    def test_set_get_unset_and_precedence(self) -> None:
        from senza import config

        config.set_value("exit-node", "100.64.0.10")
        config.set_value("exit-nodes", ["100.64.0.11", "100.64.0.10"])
        self.assertEqual(config.get_value("tailscale.exit_node"), "100.64.0.10")
        self.assertEqual(config.configured_exit_node(), "100.64.0.10")
        self.assertEqual(config.configured_exit_node("explicit-host"), "explicit-host")
        self.assertEqual(config.configured_exit_nodes(), ["100.64.0.10", "100.64.0.11"])
        with mock.patch.dict(os.environ, {"SENZA_EXIT_NODE": "100.64.0.99"}):
            self.assertEqual(config.configured_exit_node(), "100.64.0.99")
        config.unset_value("exit-node")
        self.assertIsNone(config.configured_exit_node())

    def test_cli_config_roundtrip(self) -> None:
        from senza.cli import main

        self.assertEqual(main(["config", "set", "exit-node", "100.64.0.42"]), 0)
        self.assertEqual(json.loads(Path(os.environ["SENZA_CONFIG"]).read_text())["tailscale"]["exit_node"], "100.64.0.42")
        self.assertEqual(main(["config", "unset", "exit-node"]), 0)
        self.assertEqual(main(["config", "get", "exit-node"]), 1)

    def test_launch_agent_reads_config_when_no_explicit_node(self) -> None:
        import plistlib

        from senza.firewall_bypass import install_tunnel_launch_agent

        plist = Path(self._tmp.name) / "agent.plist"
        with mock.patch("senza.firewall.launchd.TUNNEL_WATCHDOG_LOG", Path(self._tmp.name) / "log"):
            install_tunnel_launch_agent(runner=_ok, plist_path=plist, cli_path="/x/senza")
        args = plistlib.loads(plist.read_bytes())["ProgramArguments"]
        self.assertEqual(args, ["/x/senza", "tunnel", "ensure"])

    def test_tailscale_mode_without_exit_node_warns(self) -> None:
        from senza.firewall_bypass import FirewallBypass

        def runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            if cmd[-2:] == ["status", "--json"]:
                return _ok(cmd, json.dumps({"BackendState": "Running", "Peer": {}}))
            return _ok(cmd)

        with mock.patch("senza.firewall.tailscale._tailscale_cli_candidates", return_value=["/ts"]):
            fb = FirewallBypass(mode="tailscale", runner=runner, state_file=Path(self._tmp.name) / "s.json")
            notes = fb.enter()
        self.assertTrue(any("No Tailscale exit node configured" in n for n in notes))


if __name__ == "__main__":
    unittest.main()
