"""Exercise the real senza-priv helper script (root check + fixed PATH stripped, fake system tools on PATH)."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from senza import privileged

HELPER_SRC = Path(__file__).resolve().parent.parent / "senza" / "resources" / "senza-priv"

FAKE_TOOLS = {
    "ifconfig": 'echo "ifconfig $*" >> "$LOG"\n'
    'if [ "$#" -eq 1 ]; then [ -f "$STATE/$1.down" ] && echo "$1: flags=8802<BROADCAST>" || echo "$1: flags=8843<UP,BROADCAST>"; fi\n'
    '[ "${2:-}" = down ] && touch "$STATE/$1.down"\n[ "${2:-}" = up ] && rm -f "$STATE/$1.down"\nexit 0\n',
    "sysctl": 'echo "sysctl $*" >> "$LOG"\n[ "$1" = "-n" ] && echo 9216\nexit 0\n',
    "dscl": 'echo "NFSHomeDirectory: $FAKE_HOME"\n',
    "networksetup": 'echo "networksetup $*" >> "$LOG"\n'
    'if [ "$1" = "-listallnetworkservices" ]; then printf "An asterisk...\\nWi-Fi\\n*Thunderbolt Bridge\\n"; fi\n',
    "dscacheutil": 'echo "dscacheutil $*" >> "$LOG"\n',
    "killall": "exit 0\n",
}


class TestPrivilegedHelperScript(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.bindir = root / "bin"
        self.bindir.mkdir()
        self.state = root / "state"
        self.state.mkdir()
        self.home = root / "home"
        (self.home / ".local" / "share" / "senza").mkdir(parents=True)
        self.log = root / "calls.log"
        self.log.touch()
        for name, body in FAKE_TOOLS.items():
            tool = self.bindir / name
            tool.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            tool.chmod(tool.stat().st_mode | stat.S_IEXEC)
        text = HELPER_SRC.read_text(encoding="utf-8")
        text = text.replace('[ "$(id -u)" -eq 0 ] || die "must run as root"\n', "")
        text = text.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin\n", "")
        self.helper = root / "senza-priv"
        self.helper.write_text(text, encoding="utf-8")
        self.env = {
            "PATH": f"{self.bindir}:/usr/bin:/bin",
            "LOG": str(self.log),
            "STATE": str(self.state),
            "FAKE_HOME": str(self.home),
            "SUDO_USER": "tester",
        }

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_helper(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["/bin/sh", str(self.helper), *args], env=self.env, capture_output=True, text=True, timeout=10)

    def test_script_syntax_and_version(self) -> None:
        self.assertEqual(subprocess.run(["/bin/sh", "-n", str(HELPER_SRC)]).returncode, 0)
        res = self.run_helper("version")
        self.assertEqual(res.returncode, 0)
        self.assertTrue(res.stdout.startswith("senza-priv"))

    def test_rejects_anything_outside_allow_list(self) -> None:
        bad = [
            ("p2p-down", "en0"),
            ("p2p-down", "awdl0;rm -rf /"),
            ("restore", "--", "kern.securelevel=0"),
            ("restore", "--", "net.inet.udp.recvspace=1;id"),
            ("dns-set", "Wi-Fi", "1.1.1.1;id"),
            ("dns-set", "NoSuchService", "1.1.1.1"),
            ("session-boost", "12x", "awdl0"),
            ("session-boost", "1", "en0"),
            ("bogus",),
            (),
        ]
        for args in bad:
            with self.subTest(args=args):
                res = self.run_helper(*args)
                self.assertEqual(res.returncode, 64, res.stdout + res.stderr)
        self.assertNotIn("ifconfig en0", self.log.read_text())
        self.assertNotIn("kern.securelevel", self.log.read_text())

    def test_dns_set_passes_service_as_single_argv(self) -> None:
        res = self.run_helper("dns-set", "Thunderbolt Bridge", "1.1.1.1", "2606:4700::1111")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("networksetup -setdnsservers Thunderbolt Bridge 1.1.1.1 2606:4700::1111", self.log.read_text())

    def test_session_boost_watchdog_lifecycle(self) -> None:
        lease = self.home / ".local" / "share" / "senza" / "p2p_watchdog.lease"
        ack = Path(str(lease) + ".ack")
        lease.write_text("x")
        ack.write_text("x")
        res = self.run_helper("session-boost", str(os.getpid()), "awdl0")
        self.assertEqual(res.returncode, 0, res.stderr)
        log = self.log.read_text()
        self.assertIn("ifconfig awdl0 down", log)
        self.assertIn("sysctl -w net.inet.udp.recvspace=4194304", log)

        # macOS re-enables awdl0 -> watchdog re-pauses it.
        (self.state / "awdl0.down").unlink()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not (self.state / "awdl0.down").exists():
            time.sleep(0.1)
        self.assertTrue((self.state / "awdl0.down").exists())

        lease.unlink()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and ack.exists():
            time.sleep(0.1)
        self.assertFalse(ack.exists())
        log = self.log.read_text()
        self.assertIn("ifconfig awdl0 up", log)
        self.assertIn("sysctl -w net.inet.udp.recvspace=9216", log)

    def test_session_boost_requires_lease(self) -> None:
        self.assertEqual(self.run_helper("session-boost", str(os.getpid()), "awdl0").returncode, 64)


class TestPrivilegedPython(unittest.TestCase):
    def test_untrusted_helper_is_never_used(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "senza-priv"
            fake.write_text("#!/bin/sh\necho senza-priv 1\n")
            calls: list[list[str]] = []

            def runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
                calls.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, "senza-priv 1\n", "")

            with mock.patch.object(privileged, "HELPER_PATH", fake):
                privileged.reset_helper_cache()
                self.assertFalse(privileged.helper_ready(runner))  # user-owned file -> untrusted
            self.assertEqual(calls, [])
            privileged.reset_helper_cache()

    def test_optimizer_uses_helper_verbs_without_prompts(self) -> None:
        from senza.sys_optimizer import SystemOptimizer

        calls: list[list[str]] = []

        def runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            if cmd[:2] == ["sysctl", "-n"]:
                return subprocess.CompletedProcess(cmd, 0, "9216\n", "")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with tempfile.TemporaryDirectory() as tmp:
            lease = Path(tmp) / "p2p_watchdog.lease"
            opt = SystemOptimizer(
                privileged=True, gui_sudo=True, runner=runner, state_file=Path(tmp) / "s.json",
                lease_file=lease, use_helper=True,
            )
            with mock.patch("senza.sys_optimizer.subprocess.Popen"), mock.patch("senza.sys_optimizer.atexit.register"), \
                    mock.patch("senza.sys_optimizer.signal.signal"):
                opt.enter()
            boost = [c for c in calls if c[:2] == ["sudo", "-n"]]
            self.assertEqual(len(boost), 1)
            self.assertEqual(boost[0][3:5], ["session-boost", str(os.getpid())])
            self.assertFalse([c for c in calls if c and c[0] == "osascript"])
            Path(str(lease) + ".ack").unlink()
            opt.exit()
            self.assertFalse([c for c in calls if c and c[0] == "osascript"])

    def test_install_validates_sudoers_before_installing(self) -> None:
        calls: list[list[str]] = []

        def runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 1, "", "User cancelled")

        notes = privileged.install_helper(gui_sudo=True, runner=runner, user="tester")
        self.assertEqual(len(calls), 1)
        script = calls[0][2]
        self.assertLess(script.index("visudo -cf"), script.index("install -o root"))
        self.assertIn("-m 0440", script)
        self.assertTrue(notes[0].startswith("Warning"))
        self.assertEqual(privileged.install_helper(runner=runner, user="bad user;")[0][:8], "Refusing")


if __name__ == "__main__":
    unittest.main()
