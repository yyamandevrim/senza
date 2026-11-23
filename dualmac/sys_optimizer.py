"""macOS runtime process & network optimizer with guaranteed rollback."""

from __future__ import annotations

import atexit
import json
import signal
import subprocess
import threading
from pathlib import Path
from typing import Any, Callable

STATE_DIR = Path.home() / ".local" / "share" / "dualmac"
STATE_FILE = STATE_DIR / "runtime_state.json"

Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]

# Kernel network tunables that directly benefit official Sony RemotePlay.app and chiaki-ng
# (prevents UDP burst drops that cause Sony's adaptive stream to slash resolution/bitrate).
SYSCTL_BOOSTS: dict[str, str] = {
    "net.inet.udp.recvspace": "4194304",
    "net.inet.udp.maxdgram": "65535",
    "net.inet.tcp.delayed_ack": "0",
}

WIFI_P2P_INTERFACES: tuple[str, ...] = ("awdl0", "llw0")


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


def _read_sysctl(key: str, runner: Runner) -> str | None:
    res = runner(["sysctl", "-n", key])
    if res.returncode == 0:
        val = res.stdout.strip()
        return val if val else None
    return None


def _iface_exists(iface: str, runner: Runner) -> bool:
    res = runner(["ifconfig", iface])
    return res.returncode == 0


def _iface_is_up(iface: str, runner: Runner) -> bool:
    res = runner(["ifconfig", iface])
    return res.returncode == 0 and "<UP," in res.stdout


class SystemOptimizer:
    """Applies macOS streaming & network optimizations and restores everything on exit/crash."""

    def __init__(
        self,
        privileged: bool = False,
        gui_sudo: bool = False,
        dry_run: bool = False,
        runner: Runner = _default_runner,
        state_file: Path = STATE_FILE,
        enable_watchdog: bool = True,
    ) -> None:
        self.privileged = privileged
        self.gui_sudo = gui_sudo
        self.dry_run = dry_run
        self.runner = runner
        self.state_file = state_file
        self.enable_watchdog = enable_watchdog

        self._caffeinate_proc: subprocess.Popen[str] | None = None
        self._disabled_ifaces: list[str] = []
        self._saved_sysctls: dict[str, str] = {}
        self._active = False
        self._prev_sigint: Any = None
        self._prev_sigterm: Any = None
        self._watchdog_stop = threading.Event()
        self._watchdog_thread: threading.Thread | None = None

    def _write_state(self) -> None:
        if self.dry_run:
            return
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "awdl_disabled": "awdl0" in self._disabled_ifaces,
            "disabled_ifaces": self._disabled_ifaces,
            "saved_sysctls": self._saved_sysctls,
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

    def _start_p2p_watchdog(self) -> None:
        """Keep macOS background daemons (sharingd/bluetoothd) from silently re-enabling awdl0/llw0."""
        if not self.enable_watchdog or self.dry_run or self.gui_sudo or not self._disabled_ifaces:
            return
        self._watchdog_stop.clear()

        def _loop() -> None:
            while not self._watchdog_stop.wait(4.0):
                to_suppress = [i for i in self._disabled_ifaces if _iface_is_up(i, self.runner)]
                if to_suppress:
                    script = " ; ".join(f"ifconfig {i} down" for i in to_suppress)
                    # Non-interactive sudo -n so watchdog never blocks waiting for a password
                    self.runner(["sudo", "-n", "sh", "-c", script])

        self._watchdog_thread = threading.Thread(target=_loop, name="psr-p2p-watchdog", daemon=True)
        self._watchdog_thread.start()

    def _stop_p2p_watchdog(self) -> None:
        self._watchdog_stop.set()
        if self._watchdog_thread is not None:
            self._watchdog_thread.join(timeout=1.5)
            self._watchdog_thread = None

    def enter(self) -> list[str]:
        """Apply pre-launch macOS & network optimizations. Returns human-readable action notes."""
        notes: list[str] = []
        self._active = True

        # 1. Prevent display/system/idle sleep & thermal throttling
        if self.dry_run:
            notes.append("[dry-run] caffeinate -dims")
        else:
            self._caffeinate_proc = subprocess.Popen(
                ["caffeinate", "-dims"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            notes.append("Started caffeinate -dims (sleep & App Nap prevention)")

        # 2. Privileged Wi-Fi P2P suppression + kernel UDP/TCP low-latency boosts
        if self.privileged:
            ifaces = [i for i in WIFI_P2P_INTERFACES if _iface_exists(i, self.runner)]
            if not ifaces:
                ifaces = ["awdl0"]

            saved: dict[str, str] = {}
            sysctl_parts: list[str] = []
            for key, target_val in SYSCTL_BOOSTS.items():
                orig = _read_sysctl(key, self.runner)
                if orig is not None:
                    saved[key] = orig
                sysctl_parts.append(f"sysctl -w {key}={target_val}")

            iface_parts = [f"ifconfig {i} down" for i in ifaces]
            script = " && ".join([*iface_parts, *sysctl_parts])
            cmd = _privileged_shell_cmd(script, self.gui_sudo)

            if self.dry_run:
                notes.append(f"[dry-run] {' '.join(cmd)}")
            else:
                res = self.runner(cmd)
                if res.returncode == 0:
                    self._disabled_ifaces = list(ifaces)
                    self._saved_sysctls = saved
                    self._write_state()
                    notes.append(f"Paused {', '.join(ifaces)} (Wi-Fi off-channel jitter elimination)")
                    notes.append(
                        "Boosted kernel UDP/TCP buffers (udp.recvspace=4MB, udp.maxdgram=64KB, tcp.delayed_ack=0)"
                    )
                    self._start_p2p_watchdog()
                else:
                    notes.append(f"Warning: privileged network boost failed ({res.stderr.strip()})")

        if not self.dry_run:
            atexit.register(self.exit)
            self._prev_sigint = signal.getsignal(signal.SIGINT)
            self._prev_sigterm = signal.getsignal(signal.SIGTERM)
            signal.signal(signal.SIGINT, self._handle_signal)
            signal.signal(signal.SIGTERM, self._handle_signal)

        return notes

    def boost_process(self, pid: int, label: str = "RemotePlay") -> list[str]:
        """Raise scheduling priority of the launched Remote Play / chiaki-ng process."""
        notes: list[str] = []
        nice_val = "-10" if self.privileged else "-5"
        if self.privileged and not self.gui_sudo:
            cmd = ["sudo", "renice", "-n", nice_val, "-p", str(pid)]
        else:
            cmd = ["renice", "-n", "-5", "-p", str(pid)]

        if self.dry_run:
            notes.append(f"[dry-run] {' '.join(cmd)}")
            return notes

        res = self.runner(cmd)
        if res.returncode == 0:
            notes.append(f"Boosted {label} (pid {pid}) priority to nice {nice_val}")
        else:
            notes.append(f"Info: renice skipped ({res.stderr.strip() or 'requires --privileged'})")
        return notes

    def _handle_signal(self, signum: int, frame: Any) -> None:
        self.exit()
        prev = self._prev_sigint if signum == signal.SIGINT else self._prev_sigterm
        if callable(prev):
            prev(signum, frame)
        raise SystemExit(128 + signum)

    def exit(self) -> list[str]:
        """Idempotent rollback of every runtime optimization."""
        notes: list[str] = []
        if not self._active:
            return notes
        self._active = False

        self._stop_p2p_watchdog()

        if self._caffeinate_proc is not None:
            try:
                self._caffeinate_proc.terminate()
                self._caffeinate_proc.wait(timeout=2.0)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    self._caffeinate_proc.kill()
                except OSError:
                    pass
            self._caffeinate_proc = None
            notes.append("Stopped caffeinate")

        rollback_parts: list[str] = []
        for iface in self._disabled_ifaces:
            rollback_parts.append(f"ifconfig {iface} up")
        for key, orig_val in self._saved_sysctls.items():
            rollback_parts.append(f"sysctl -w {key}={orig_val}")

        if rollback_parts:
            script = " ; ".join(rollback_parts)
            cmd = _privileged_shell_cmd(script, self.gui_sudo)
            res = self.runner(cmd)
            if res.returncode == 0:
                if self._disabled_ifaces:
                    notes.append(f"Restored {', '.join(self._disabled_ifaces)} (AirDrop/Handoff re-enabled)")
                if self._saved_sysctls:
                    notes.append("Restored original macOS kernel UDP/TCP sysctl values")
                self._disabled_ifaces = []
                self._saved_sysctls = {}
            else:
                notes.append(f"Warning: failed to restore network settings ({res.stderr.strip()})")

        self._clear_state()
        return notes

    def __enter__(self) -> SystemOptimizer:
        self.enter()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.exit()


def restore_from_crash(
    gui_sudo: bool = False,
    runner: Runner = _default_runner,
    state_file: Path = STATE_FILE,
) -> list[str]:
    """Recover awdl0/llw0 and sysctl network state after an unexpected crash or kill -9."""
    notes: list[str] = []
    ifaces_to_up: list[str] = []
    sysctls_to_restore: dict[str, str] = {}

    if state_file.exists():
        try:
            data = json.loads(state_file.read_text(encoding="utf-8"))
            ifaces_to_up = list(data.get("disabled_ifaces", []))
            if data.get("awdl_disabled") and "awdl0" not in ifaces_to_up:
                ifaces_to_up.append("awdl0")
            sysctls_to_restore = dict(data.get("saved_sysctls", {}))
        except (OSError, ValueError):
            ifaces_to_up = ["awdl0", "llw0"]

    for iface in WIFI_P2P_INTERFACES:
        if iface not in ifaces_to_up:
            chk = runner(["ifconfig", iface])
            if chk.returncode == 0 and "<UP," not in chk.stdout:
                ifaces_to_up.append(iface)

    parts = [f"ifconfig {i} up" for i in ifaces_to_up]
    parts.extend(f"sysctl -w {k}={v}" for k, v in sysctls_to_restore.items())

    if parts:
        res = runner(_privileged_shell_cmd(" ; ".join(parts), gui_sudo))
        if res.returncode == 0:
            if ifaces_to_up:
                notes.append(f"Restored {', '.join(ifaces_to_up)} to UP")
            if sysctls_to_restore:
                notes.append("Restored original macOS kernel UDP/TCP sysctl values")
        else:
            notes.append(f"Warning: could not restore network state ({res.stderr.strip()})")

    if state_file.exists():
        try:
            state_file.unlink()
        except OSError:
            pass
    return notes
