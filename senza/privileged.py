"""Single place for every root operation Senza performs.

Preferred path: the installed `senza-priv` helper (root-owned, allow-listed verbs, one NOPASSWD sudoers rule
for the installing user) -> zero password / Touch ID prompts. Fallback: one-off `sudo sh -c` (terminal) or
`osascript ... with administrator privileges` (GUI).
"""

from __future__ import annotations

import os
import pwd
import shlex
import stat
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path

Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]

HELPER_PATH = Path(os.environ.get("SENZA_PRIV_HELPER") or "/usr/local/libexec/senza-priv")
SUDOERS_PATH = Path("/etc/sudoers.d/senza")
HELPER_SOURCE = Path(__file__).resolve().parent / "resources" / "senza-priv"


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def shell_cmd(script: str, gui_sudo: bool) -> list[str]:
    """One-off privileged shell (prompts): Touch ID / password dialog under GUI, terminal sudo otherwise."""
    if gui_sudo:
        escaped = script.replace("\\", "\\\\").replace('"', '\\"')
        return ["osascript", "-e", f'do shell script "{escaped}" with administrator privileges']
    return ["sudo", "sh", "-c", script]


def helper_cmd(*args: str) -> list[str]:
    return ["sudo", "-n", str(HELPER_PATH), *args]


def _helper_file_is_trusted(path: Path) -> bool:
    """Root-owned, not group/world writable, and so is its parent dir (otherwise sudo rule = privilege escalation)."""
    try:
        for p in (path, path.parent):
            st = p.stat()
            if st.st_uid != 0 or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                return False
        return stat.S_ISREG(path.stat().st_mode)
    except OSError:
        return False


_ready_cache: dict[str, bool] = {}


def helper_ready(runner: Runner = _default_runner, use_cache: bool = True) -> bool:
    """True when the helper is installed, trusted, and runnable via `sudo -n` without a prompt."""
    key = str(HELPER_PATH)
    if use_cache and key in _ready_cache:
        return _ready_cache[key]
    ok = _helper_file_is_trusted(HELPER_PATH)
    if ok:
        res = runner(helper_cmd("version"))
        ok = res.returncode == 0 and res.stdout.startswith("senza-priv")
    _ready_cache[key] = ok
    return ok


def reset_helper_cache() -> None:
    _ready_cache.clear()


def helper_status(runner: Runner = _default_runner) -> dict[str, object]:
    installed = HELPER_PATH.exists()
    return {
        "installed": installed,
        "trusted": _helper_file_is_trusted(HELPER_PATH) if installed else False,
        "sudoers_rule": SUDOERS_PATH.exists(),
        "ready": helper_ready(runner, use_cache=False) if installed else False,
        "path": str(HELPER_PATH),
    }


def _current_user() -> str:
    return pwd.getpwuid(os.getuid()).pw_name


def install_helper(gui_sudo: bool = False, runner: Runner = _default_runner, user: str | None = None) -> list[str]:
    """Install helper + sudoers rule with ONE privileged prompt; validates the rule with `visudo -c` first."""
    user = user or _current_user()
    if not user.replace(".", "").replace("_", "").replace("-", "").isalnum():
        return [f"Refusing to write sudoers rule for unusual username {user!r}"]

    tmpdir = Path(tempfile.mkdtemp(prefix="senza-helper-"))
    staged_helper = tmpdir / "senza-priv"
    staged_helper.write_bytes(HELPER_SOURCE.read_bytes())
    staged_rule = tmpdir / "sudoers"
    # Exact path, no wildcard on the command itself; arguments are validated by the helper.
    staged_rule.write_text(f"{user} ALL=(root) NOPASSWD: {HELPER_PATH} *\n", encoding="utf-8")

    q = shlex.quote
    script = " && ".join(
        [
            f"/usr/sbin/visudo -cf {q(str(staged_rule))} >/dev/null",
            f"/bin/mkdir -p {q(str(HELPER_PATH.parent))}",
            f"/usr/sbin/chown root:wheel {q(str(HELPER_PATH.parent))}",
            f"/bin/chmod 0755 {q(str(HELPER_PATH.parent))}",
            f"/usr/bin/install -o root -g wheel -m 0755 {q(str(staged_helper))} {q(str(HELPER_PATH))}",
            f"/usr/bin/install -o root -g wheel -m 0440 {q(str(staged_rule))} {q(str(SUDOERS_PATH))}",
        ]
    )
    res = runner(shell_cmd(script, gui_sudo))
    for f in (staged_helper, staged_rule):
        f.unlink(missing_ok=True)
    tmpdir.rmdir()
    reset_helper_cache()

    if res.returncode != 0:
        return [f"Warning: helper install failed ({(res.stderr or res.stdout).strip() or 'cancelled'})"]
    if helper_ready(runner, use_cache=False):
        return [f"Installed passwordless helper {HELPER_PATH} (sudoers rule: {SUDOERS_PATH})"]
    return [f"Warning: helper installed at {HELPER_PATH} but `sudo -n` still prompts — check {SUDOERS_PATH}"]


def uninstall_helper(gui_sudo: bool = False, runner: Runner = _default_runner) -> list[str]:
    q = shlex.quote
    script = f"/bin/rm -f {q(str(SUDOERS_PATH))} {q(str(HELPER_PATH))}"
    res = runner(shell_cmd(script, gui_sudo))
    reset_helper_cache()
    if res.returncode == 0:
        return [f"Removed {HELPER_PATH} and {SUDOERS_PATH}"]
    return [f"Warning: helper uninstall failed ({(res.stderr or res.stdout).strip() or 'cancelled'})"]
