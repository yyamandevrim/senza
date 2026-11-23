"""Adaptive chiaki-ng stream presets and cfprefsd-safe macOS defaults management."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .net_probe import NetworkReport

CHIAKI_DOMAIN = "com.chiaki.Chiaki"
STATE_DIR = Path.home() / ".local" / "share" / "dualmac"
PLIST_BACKUP_PATH = STATE_DIR / "com.chiaki.Chiaki.backup.plist"

Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


@dataclass(frozen=True)
class StreamPreset:
    name: str
    resolution: str      # "720p" or "1080p"
    fps: int             # 60
    bitrate_kbps: int
    codec: str           # "h265"
    audio_buffer_size: int
    hw_decoder: str = "auto"
    render_backend: str = "vulkan"


PRESETS: dict[str, StreamPreset] = {
    "wan-high": StreamPreset(
        name="wan-high",
        resolution="1080p",
        fps=60,
        bitrate_kbps=15000,
        codec="h265",
        audio_buffer_size=9600,
    ),
    "wan-balanced": StreamPreset(
        name="wan-balanced",
        resolution="1080p",
        fps=60,
        bitrate_kbps=10000,
        codec="h265",
        audio_buffer_size=14400,
    ),
    "wan-lowbw": StreamPreset(
        name="wan-lowbw",
        resolution="720p",
        fps=60,
        bitrate_kbps=6500,
        codec="h265",
        audio_buffer_size=19200,
    ),
    "lan-max": StreamPreset(
        name="lan-max",
        resolution="1080p",
        fps=60,
        bitrate_kbps=30000,
        codec="h265",
        audio_buffer_size=4800,
    ),
}


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def recommend_preset(report: NetworkReport) -> StreamPreset:
    if not report.ipv4_ok or report.rtt_median_ms is None or report.jitter_ms is None:
        return PRESETS["wan-lowbw"]

    if report.packet_loss_pct < 0.5 and report.jitter_ms < 8.0 and report.rtt_median_ms < 35.0:
        return PRESETS["wan-high"]
    if report.packet_loss_pct < 2.0 and report.jitter_ms < 20.0 and report.rtt_median_ms < 70.0:
        return PRESETS["wan-balanced"]
    return PRESETS["wan-lowbw"]


def build_defaults_commands(preset: StreamPreset, disable_builtin_kbm: bool = True) -> list[list[str]]:
    """Build macOS `defaults write` commands matching chiaki-ng QSettings NativeFormat keys."""
    writes: list[tuple[str, str, str]] = [
        ("settings.resolution_remote_ps5", "-string", preset.resolution),
        ("settings.fps_remote_ps5", "-int", str(preset.fps)),
        ("settings.bitrate_remote_ps5", "-int", str(preset.bitrate_kbps)),
        ("settings.codec_remote_ps5", "-string", preset.codec),
        ("settings.resolution_local_ps5", "-string", preset.resolution),
        ("settings.fps_local_ps5", "-int", str(preset.fps)),
        ("settings.bitrate_local_ps5", "-int", str(preset.bitrate_kbps)),
        ("settings.codec_local_ps5", "-string", preset.codec),
        ("settings.audio_buffer_size", "-int", str(preset.audio_buffer_size)),
        ("settings.hw_decoder", "-string", preset.hw_decoder),
        ("settings.render_backend", "-string", preset.render_backend),
        ("NSAppSleepDisabled", "-bool", "YES"),
    ]
    if disable_builtin_kbm:
        # Prevent chiaki-ng built-in keyboard/mouse-touchpad from fighting libdualmac_chiaki.dylib
        writes.append(("settings.keyboard_enabled", "-bool", "NO"))
        writes.append(("settings.mouse_touch_enabled", "-bool", "NO"))

    return [["defaults", "write", CHIAKI_DOMAIN, key, typ, val] for key, typ, val in writes]


def backup_chiaki_plist(
    backup_path: Path = PLIST_BACKUP_PATH,
    runner: Runner = _default_runner,
) -> bool:
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    if backup_path.exists():
        return True  # Preserve original pre-DualMac backup
    res = runner(["defaults", "export", CHIAKI_DOMAIN, str(backup_path)])
    return res.returncode == 0


def apply_stream_preset(
    preset: StreamPreset,
    disable_builtin_kbm: bool = True,
    dry_run: bool = False,
    backup_path: Path = PLIST_BACKUP_PATH,
    runner: Runner = _default_runner,
) -> list[list[str]]:
    cmds = build_defaults_commands(preset, disable_builtin_kbm=disable_builtin_kbm)
    if dry_run:
        return cmds

    backup_chiaki_plist(backup_path=backup_path, runner=runner)
    for cmd in cmds:
        res = runner(cmd)
        if res.returncode != 0:
            raise RuntimeError(f"Failed to apply chiaki-ng setting {' '.join(cmd)}: {res.stderr.strip()}")
    return cmds


def restore_chiaki_plist(
    backup_path: Path = PLIST_BACKUP_PATH,
    runner: Runner = _default_runner,
) -> bool:
    if not backup_path.exists():
        return False
    res = runner(["defaults", "import", CHIAKI_DOMAIN, str(backup_path)])
    return res.returncode == 0
