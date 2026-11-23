"""Prepares local ad-hoc signed chiaki-ng or official Sony RemotePlay bundle and launches with KBM/Trackpad bridge."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_CHIAKI_DYLIB = REPO_ROOT / "build" / "libdualmac_chiaki.dylib"
BUILD_SONY_DYLIB = REPO_ROOT / "build" / "libdualmac_sony.dylib"
STATE_DIR = Path.home() / ".local" / "share" / "dualmac"

PATCHED_APP = STATE_DIR / "chiaki-ng-patched.app"
CHIAKI_STAMP_FILE = STATE_DIR / "chiaki-ng-source.stamp"

PATCHED_SONY_APP = STATE_DIR / "RemotePlay-patched.app"
SONY_STAMP_FILE = STATE_DIR / "remoteplay-source.stamp"

CHIAKI_SEARCH_PATHS = (
    Path("/Applications/chiaki-ng.app"),
    Path.home() / "Applications" / "chiaki-ng.app",
    Path("/Applications/Chiaki.app"),
)

SONY_SEARCH_PATHS = (
    Path("/Applications/RemotePlay.app"),
    Path.home() / "Applications" / "RemotePlay.app",
)


def find_chiaki_app(explicit_path: str | None = None) -> Path | None:
    if explicit_path:
        p = Path(explicit_path).expanduser()
        return p if p.exists() else None
    for candidate in CHIAKI_SEARCH_PATHS:
        if candidate.exists():
            return candidate
    return None


def find_sony_app(explicit_path: str | None = None) -> Path | None:
    if explicit_path:
        p = Path(explicit_path).expanduser()
        return p if p.exists() else None
    for candidate in SONY_SEARCH_PATHS:
        if candidate.exists():
            return candidate
    return None


def find_app_binary(app_bundle: Path, client: str = "chiaki") -> Path:
    macos_dir = app_bundle / "Contents" / "MacOS"
    names = ("RemotePlay",) if client == "sony" else ("chiaki", "chiaki-ng", "Chiaki")
    for name in names:
        cand = macos_dir / name
        if cand.is_file():
            return cand
    raise FileNotFoundError(f"Could not find {client} executable inside {macos_dir}")


def ensure_dylib_built(client: str = "chiaki", force: bool = False) -> Path:
    target = BUILD_SONY_DYLIB if client == "sony" else BUILD_CHIAKI_DYLIB
    if target.is_file() and not force:
        return target
    res = subprocess.run(["make", "build"], cwd=str(REPO_ROOT), check=False)
    if res.returncode != 0 or not target.is_file():
        raise RuntimeError(f"Failed to compile {target} via `make build`.")
    return target


def _bundle_signature_stamp(app_bundle: Path, client: str) -> str:
    binary = find_app_binary(app_bundle, client=client)
    st = binary.stat()
    return f"{app_bundle.resolve()}:{st.st_size}:{int(st.st_mtime)}"


def prepare_patched_app(source_app: Path, client: str = "chiaki", force: bool = False) -> Path:
    """Clone target .app locally and ad-hoc sign without Hardened Runtime so DYLD_INSERT_LIBRARIES works."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    patched = PATCHED_SONY_APP if client == "sony" else PATCHED_APP
    stamp_file = SONY_STAMP_FILE if client == "sony" else CHIAKI_STAMP_FILE
    stamp = _bundle_signature_stamp(source_app, client=client)

    if not force and patched.exists() and stamp_file.exists():
        if stamp_file.read_text(encoding="utf-8").strip() == stamp:
            return patched

    if patched.exists():
        shutil.rmtree(patched)

    cp_res = subprocess.run(["ditto", str(source_app), str(patched)], capture_output=True, text=True)
    if cp_res.returncode != 0:
        raise RuntimeError(f"Failed to copy {source_app}: {cp_res.stderr.strip()}")

    subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(patched)], capture_output=True, check=False)

    sign_res = subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-", str(patched)],
        capture_output=True,
        text=True,
    )
    if sign_res.returncode != 0:
        raise RuntimeError(f"Ad-hoc codesign failed for {patched}: {sign_res.stderr.strip()}")

    stamp_file.write_text(stamp + "\n", encoding="utf-8")
    return patched


def build_launch_env(
    dylib_path: Path,
    runtime_cfg_path: Path,
    profile_json_path: Path | None = None,
    ping_host: str | None = None,
) -> dict[str, str]:
    env = os.environ.copy()
    existing_dyld = env.get("DYLD_INSERT_LIBRARIES", "")
    env["DYLD_INSERT_LIBRARIES"] = (
        f"{dylib_path}:{existing_dyld}" if existing_dyld else str(dylib_path)
    )
    env["DUALMAC_PROFILE_CFG"] = str(runtime_cfg_path)
    if profile_json_path is not None:
        env["DUALMAC_PROFILE_JSON"] = str(profile_json_path)
    if ping_host:
        env["DUALMAC_PING_HOST"] = ping_host
    env["SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
    return env


def launch_client(
    app_bundle: Path,
    dylib_path: Path | None,
    runtime_cfg_path: Path | None,
    client: str = "chiaki",
    inject_kbm: bool = True,
    profile_json_path: Path | None = None,
    ping_host: str | None = None,
) -> subprocess.Popen[bytes]:
    binary = find_app_binary(app_bundle, client=client)
    if inject_kbm and dylib_path is not None and runtime_cfg_path is not None:
        env = build_launch_env(
            dylib_path,
            runtime_cfg_path,
            profile_json_path=profile_json_path,
            ping_host=ping_host,
        )
    else:
        env = os.environ.copy()
    if client == "sony":
        subprocess.run(
            ["defaults", "write", "com.playstation.RemotePlay", "NSAppSleepDisabled", "-bool", "YES"],
            capture_output=True,
            check=False,
        )
    return subprocess.Popen([str(binary)], env=env)
