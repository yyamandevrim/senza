"""macOS runtime process & network optimizer with guaranteed rollback."""

from __future__ import annotations

import atexit
import os
import shlex
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

from . import privileged
from .state import atomic_write_json, read_json_dict, remove_file

STATE_DIR = Path.home() / ".local" / "share" / "senza"
STATE_FILE = STATE_DIR / "runtime_state.json"
P2P_LEASE_FILE = STATE_DIR / "p2p_watchdog.lease"
P2P_WATCHDOG_INTERVAL_S = 2

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


_privileged_shell_cmd = privileged.shell_cmd


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


def _ack_file(lease_file: Path) -> Path:
    """Created by Senza at start; deleted by the root watchdog once rollback has finished."""
    return lease_file.with_name(lease_file.name + ".ack")


def build_root_p2p_watchdog(
    ifaces: list[str],
    saved_sysctls: dict[str, str],
    parent_pid: int,
    lease_file: Path,
    interval_s: int = P2P_WATCHDOG_INTERVAL_S,
) -> str:
    """Shell snippet (run once as root) that detaches a tiny root watchdog.

    While `parent_pid` is alive AND `lease_file` exists it re-downs awdl0/llw0 whenever macOS
    (sharingd/bluetoothd) silently re-enables them. When the session ends (lease removed) or the
    Senza process dies (crash, kill -9), it restores interfaces + sysctls itself and exits.
    This needs no cached sudo ticket, so it works for both terminal sudo and the GUI Touch ID path.
    """
    lease_q = shlex.quote(str(lease_file))
    ack_q = shlex.quote(str(_ack_file(lease_file)))
    keep_down = " ; ".join(
        f"if ifconfig {i} 2>/dev/null | grep -q UP, ; then ifconfig {i} down ; fi" for i in ifaces
    )
    restore_parts = [f"ifconfig {i} up" for i in ifaces]
    restore_parts += [f"sysctl -w {k}={v}" for k, v in saved_sysctls.items()]
    restore = " ; ".join(restore_parts) if restore_parts else "true"
    loop = (
        f"while kill -0 {int(parent_pid)} 2>/dev/null && [ -f {lease_q} ] ; do "
        f"{keep_down or 'true'} ; sleep {int(interval_s)} ; done ; "
        f"{restore} >/dev/null 2>&1 ; rm -f {lease_q} {ack_q}"
    )
    # Fully detach stdio so `osascript ... do shell script` returns immediately.
    return f"nohup /bin/sh -c {shlex.quote(loop)} >/dev/null 2>&1 </dev/null &"


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
        lease_file: Path = P2P_LEASE_FILE,
        use_helper: bool | None = None,
    ) -> None:
        self.privileged = privileged
        self.gui_sudo = gui_sudo
        self.dry_run = dry_run
        self.runner = runner
        self.state_file = state_file
        self.enable_watchdog = enable_watchdog
        self.lease_file = lease_file
        self._use_helper_opt = use_helper

        self._caffeinate_proc: subprocess.Popen[str] | None = None
        self._disabled_ifaces: list[str] = []
        self._saved_sysctls: dict[str, str] = {}
        self._active = False
        self._prev_sigint: Any = None
        self._prev_sigterm: Any = None
        self._root_watchdog = False

    def _write_state(self) -> None:
        if self.dry_run:
            return
        atomic_write_json(
            self.state_file,
            {
                "awdl_disabled": "awdl0" in self._disabled_ifaces,
                "disabled_ifaces": self._disabled_ifaces,
                "saved_sysctls": self._saved_sysctls,
                "root_watchdog": self._root_watchdog,
                "lease_file": str(self.lease_file) if self._root_watchdog else None,
            },
        )

    def _clear_state(self) -> None:
        if self.dry_run:
            return
        remove_file(self.state_file)

    def _helper(self) -> bool:
        """Passwordless helper only works with its fixed lease path under ~/.local/share/senza."""
        if self._use_helper_opt is not None:
            return self._use_helper_opt
        return self.lease_file == P2P_LEASE_FILE and privileged.helper_ready(self.runner)

    def _wait_root_watchdog_rollback(self, timeout_s: float = 4.0) -> bool:
        """After removing the lease, wait for the root watchdog to finish rollback (it deletes the ack file)."""
        ack = _ack_file(self.lease_file)
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if not ack.exists():
                return True
            time.sleep(0.2)
        remove_file(ack)
        return False

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
            use_helper = self._helper()
            use_root_watchdog = (self.enable_watchdog or use_helper) and not self.dry_run
            if use_root_watchdog:
                self.lease_file.parent.mkdir(parents=True, exist_ok=True)
                self.lease_file.write_text(str(os.getpid()), encoding="utf-8")
                _ack_file(self.lease_file).write_text(str(os.getpid()), encoding="utf-8")
            if use_helper:
                cmd = privileged.helper_cmd("session-boost", str(os.getpid()), *ifaces)
            else:
                if use_root_watchdog:
                    script += " ; " + build_root_p2p_watchdog(ifaces, saved, os.getpid(), self.lease_file)
                cmd = _privileged_shell_cmd(script, self.gui_sudo)

            if self.dry_run:
                notes.append(f"[dry-run] {' '.join(cmd)}")
            else:
                res = self.runner(cmd)
                if res.returncode == 0:
                    self._disabled_ifaces = list(ifaces)
                    self._saved_sysctls = saved
                    self._root_watchdog = use_root_watchdog
                    self._write_state()
                    notes.append(f"Paused {', '.join(ifaces)} (Wi-Fi off-channel jitter elimination)")
                    notes.append(
                        "Boosted kernel UDP/TCP buffers (udp.recvspace=4MB, udp.maxdgram=64KB, tcp.delayed_ack=0)"
                    )
                    if use_root_watchdog:
                        notes.append(
                            f"Root AWDL watchdog active (re-pauses {', '.join(ifaces)} every "
                            f"{P2P_WATCHDOG_INTERVAL_S}s, self-restores on exit or crash)"
                        )
                else:
                    if use_root_watchdog:
                        remove_file(self.lease_file)
                        remove_file(_ack_file(self.lease_file))
                    notes.append(f"Warning: privileged network boost failed ({res.stderr.strip()})")

        if not self.dry_run:
            atexit.register(self.exit)
            self._prev_sigint = signal.getsignal(signal.SIGINT)
            self._prev_sigterm = signal.getsignal(signal.SIGTERM)
            signal.signal(signal.SIGINT, self._handle_signal)
            signal.signal(signal.SIGTERM, self._handle_signal)

        return notes

    def boost_process(self, pid: int, label: str = "RemotePlay") -> list[str]:
        """Raise scheduling priority / P-core QoS of the launched Remote Play / chiaki-ng process."""
        notes: list[str] = []
        policy_cmd = ["taskpolicy", "-B", "-p", str(pid)]

        if self.dry_run:
            notes.append(f"[dry-run] {' '.join(policy_cmd)}")
            if self.privileged and not self.gui_sudo:
                notes.append(f"[dry-run] sudo renice -n -10 -p {pid}")
            return notes

        pol_res = self.runner(policy_cmd)
        if pol_res.returncode == 0:
            notes.append(f"Boosted {label} (pid {pid}) to foreground Performance-core QoS (taskpolicy -B)")

        # Negative nice values always require root on macOS; only apply when terminal sudo is already cached
        # (skip under --gui-sudo to avoid popping up a second Touch ID / password dialog).
        if self.privileged and not self.gui_sudo:
            renice_cmd = ["sudo", "renice", "-n", "-10", "-p", str(pid)]
            res = self.runner(renice_cmd)
            if res.returncode == 0:
                notes.append(f"Boosted {label} (pid {pid}) CPU priority to nice -10")
            else:
                notes.append(f"Info: renice skipped ({res.stderr.strip() or 'requires root'})")
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

        if self._root_watchdog:
            # Root watchdog owns rollback: dropping the lease makes it restore ifaces + sysctls
            # without a second password / Touch ID prompt.
            remove_file(self.lease_file)
            restored = self.dry_run or self._wait_root_watchdog_rollback()
            if restored:
                if self._disabled_ifaces:
                    notes.append(f"Restored {', '.join(self._disabled_ifaces)} (AirDrop/Handoff re-enabled)")
                if self._saved_sysctls:
                    notes.append("Restored original macOS kernel UDP/TCP sysctl values")
                self._disabled_ifaces = []
                self._saved_sysctls = {}
            else:
                notes.append("Watchdog rollback not confirmed in 4s — falling back to direct restore")
            self._root_watchdog = False

        rollback_parts: list[str] = []
        for iface in self._disabled_ifaces:
            rollback_parts.append(f"ifconfig {iface} up")
        for key, orig_val in self._saved_sysctls.items():
            rollback_parts.append(f"sysctl -w {key}={orig_val}")

        if rollback_parts:
            script = " ; ".join(rollback_parts)
            if self._helper():
                kv = [f"{k}={v}" for k, v in self._saved_sysctls.items()]
                cmd = privileged.helper_cmd("restore", *self._disabled_ifaces, "--", *kv)
            else:
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
        data = read_json_dict(state_file)
        if not data:
            ifaces_to_up = ["awdl0", "llw0"]
        else:
            ifaces_to_up = list(data.get("disabled_ifaces", []))
            if data.get("awdl_disabled") and "awdl0" not in ifaces_to_up:
                ifaces_to_up.append("awdl0")
            sysctls_to_restore = dict(data.get("saved_sysctls", {}))
            # Stop any orphaned root watchdog first so it doesn't re-down interfaces after we restore them.
            if data.get("lease_file"):
                lease = Path(str(data["lease_file"]))
                remove_file(lease)
                remove_file(_ack_file(lease))

    for iface in WIFI_P2P_INTERFACES:
        if iface not in ifaces_to_up:
            chk = runner(["ifconfig", iface])
            if chk.returncode == 0 and "<UP," not in chk.stdout:
                ifaces_to_up.append(iface)

    parts = [f"ifconfig {i} up" for i in ifaces_to_up]
    parts.extend(f"sysctl -w {k}={v}" for k, v in sysctls_to_restore.items())

    if parts:
        if privileged.helper_ready(runner):
            kv = [f"{k}={v}" for k, v in sysctls_to_restore.items()]
            cmd = privileged.helper_cmd("restore", *[i for i in ifaces_to_up if i in WIFI_P2P_INTERFACES], "--", *kv)
        else:
            cmd = _privileged_shell_cmd(" ; ".join(parts), gui_sudo)
        res = runner(cmd)
        if res.returncode == 0:
            if ifaces_to_up:
                notes.append(f"Restored {', '.join(ifaces_to_up)} to UP")
            if sysctls_to_restore:
                notes.append("Restored original macOS kernel UDP/TCP sysctl values")
        else:
            notes.append(f"Warning: could not restore network state ({res.stderr.strip()})")

    remove_file(state_file)
    return notes
