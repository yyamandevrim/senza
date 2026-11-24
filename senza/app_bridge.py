"""Prepares local ad-hoc signed chiaki-ng or official Sony RemotePlay bundle and launches with KBM/Trackpad bridge."""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import plistlib
import shutil
import subprocess
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_CHIAKI_DYLIB = REPO_ROOT / "build" / "libsenza_chiaki.dylib"
BUILD_SONY_DYLIB = REPO_ROOT / "build" / "libsenza_sony.dylib"
ICON_PNG_PATH = REPO_ROOT / "assets" / "icon.png"
STATE_DIR = Path.home() / ".local" / "share" / "senza"

PATCHED_APP = STATE_DIR / "chiaki-ng-patched.app"
CHIAKI_STAMP_FILE = STATE_DIR / "chiaki-ng-source.stamp"

PATCHED_SONY_APP = STATE_DIR / "RemotePlay-patched.app"
SONY_STAMP_FILE = STATE_DIR / "remoteplay-source.stamp"
CACHED_ICNS_PATH = STATE_DIR / "Senza.icns"

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


def _ensure_senza_icns() -> Path | None:
    """Build and cache Senza.icns from assets/icon.png using built-in sips + iconutil."""
    if not ICON_PNG_PATH.is_file():
        return None
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if CACHED_ICNS_PATH.is_file() and CACHED_ICNS_PATH.stat().st_mtime >= ICON_PNG_PATH.stat().st_mtime:
        return CACHED_ICNS_PATH

    iconset_dir = STATE_DIR / "Senza.iconset"
    if iconset_dir.exists():
        shutil.rmtree(iconset_dir)
    iconset_dir.mkdir(parents=True, exist_ok=True)
    try:
        for sz in (16, 32, 128, 256, 512):
            subprocess.run(
                ["sips", "-z", str(sz), str(sz), str(ICON_PNG_PATH), "--out", str(iconset_dir / f"icon_{sz}x{sz}.png")],
                capture_output=True,
                check=False,
            )
            sz2 = sz * 2
            out2 = iconset_dir / f"icon_{sz}x{sz}@2x.png"
            if sz2 <= 512:
                subprocess.run(
                    ["sips", "-z", str(sz2), str(sz2), str(ICON_PNG_PATH), "--out", str(out2)],
                    capture_output=True,
                    check=False,
                )
            else:
                shutil.copy2(ICON_PNG_PATH, out2)
        res = subprocess.run(
            ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(CACHED_ICNS_PATH)],
            capture_output=True,
            check=False,
        )
        return CACHED_ICNS_PATH if res.returncode == 0 and CACHED_ICNS_PATH.is_file() else None
    finally:
        if iconset_dir.exists():
            shutil.rmtree(iconset_dir, ignore_errors=True)


def _brand_patched_bundle(patched: Path) -> None:
    """Apply Senza's Apple Pro icon and display name to the local ad-hoc patched bundle."""
    icns = _ensure_senza_icns()
    resources = patched / "Contents" / "Resources"
    info_plist = patched / "Contents" / "Info.plist"
    if not info_plist.is_file():
        return
    try:
        with info_plist.open("rb") as f:
            plist = plistlib.load(f)
        if icns is not None and resources.is_dir():
            shutil.copy2(icns, resources / "Senza.icns")
            plist["CFBundleIconFile"] = "Senza.icns"
            plist.pop("CFBundleIconName", None)
        plist["CFBundleDisplayName"] = "Senza"
        with info_plist.open("wb") as f:
            plistlib.dump(plist, f)
    except Exception:
        pass


def _bundle_signature_stamp(app_bundle: Path, client: str) -> str:
    binary = find_app_binary(app_bundle, client=client)
    st = binary.stat()
    icon_mtime = int(ICON_PNG_PATH.stat().st_mtime) if ICON_PNG_PATH.is_file() else 0
    return f"{app_bundle.resolve()}:{st.st_size}:{int(st.st_mtime)}:icon={icon_mtime}"


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
    _brand_patched_bundle(patched)

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
    env["SENZA_PROFILE_CFG"] = str(runtime_cfg_path)
    if profile_json_path is not None:
        env["SENZA_PROFILE_JSON"] = str(profile_json_path)
    if ping_host:
        env["SENZA_PING_HOST"] = ping_host
    if ICON_PNG_PATH.is_file():
        env["SENZA_ICON_PATH"] = str(ICON_PNG_PATH)
    env["SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
    return env


def _activate_running_app_async(proc: subprocess.Popen[bytes], app_bundle: Path) -> None:
    """Bring the newly spawned app to the foreground once LaunchServices registers its window (zero permissions)."""
    if os.environ.get("SENZA_GUI_MANAGED") == "1":
        # Senza.app handles native Cooperative Activation (yieldActivation) directly.
        return

    def _worker() -> None:
        try:
            objc_path = ctypes.util.find_library("objc")
            if not objc_path:
                return
            objc = ctypes.cdll.LoadLibrary(objc_path)
            ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
            objc.objc_getClass.restype = ctypes.c_void_p
            objc.sel_registerName.restype = ctypes.c_void_p

            msg_ptr_int = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int)(
                ("objc_msgSend", objc)
            )
            msg_bool = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)(
                ("objc_msgSend", objc)
            )
            msg_activate = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong)(
                ("objc_msgSend", objc)
            )

            cls = objc.objc_getClass(b"NSRunningApplication")
            sel_by_pid = objc.sel_registerName(b"runningApplicationWithProcessIdentifier:")
            sel_finished = objc.sel_registerName(b"isFinishedLaunching")
            sel_active = objc.sel_registerName(b"isActive")
            sel_activate = objc.sel_registerName(b"activateWithOptions:")

            # Wait up to 8s for NSApplication to finish launching and register with LaunchServices.
            app_ptr = None
            for _ in range(80):
                if proc.poll() is not None:
                    return
                app_ptr = msg_ptr_int(cls, sel_by_pid, proc.pid)
                if app_ptr and msg_bool(app_ptr, sel_finished):
                    break
                time.sleep(0.1)

            if not app_ptr or proc.poll() is not None:
                return

            # NSApplicationActivateAllWindows (1) | NSApplicationActivateIgnoringOtherApps (2)
            msg_activate(app_ptr, sel_activate, 3)
            time.sleep(0.15)
            # On macOS 14+, LaunchServices `open <bundle>` grants reliable foreground focus from Terminal/Raycast
            # and safely activates the existing process once `isFinishedLaunching` is true.
            if proc.poll() is None and not msg_bool(app_ptr, sel_active):
                subprocess.run(["/usr/bin/open", str(app_bundle)], capture_output=True, check=False)
        except Exception:
            pass

    threading.Thread(target=_worker, name="senza-frontmost", daemon=True).start()


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
    proc = subprocess.Popen([str(binary)], env=env)
    _activate_running_app_async(proc, app_bundle)
    return proc
