"""Profile loading, validation, and runtime config export for Senza native DualSense bridges."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .state import atomic_write_text

# macOS HIToolbox virtual keycodes + synthetic mouse codes matching mapper_core.h
KEYCODE_MAP: dict[str, int] = {
    "A": 0,
    "S": 1,
    "D": 2,
    "F": 3,
    "H": 4,
    "G": 5,
    "Z": 6,
    "X": 7,
    "C": 8,
    "V": 9,
    "B": 11,
    "Q": 12,
    "W": 13,
    "E": 14,
    "R": 15,
    "Y": 16,
    "T": 17,
    "1": 18,
    "2": 19,
    "3": 20,
    "4": 21,
    "6": 22,
    "5": 23,
    "Equals": 24,
    "9": 25,
    "7": 26,
    "Minus": 27,
    "8": 28,
    "0": 29,
    "RightBracket": 30,
    "O": 31,
    "U": 32,
    "LeftBracket": 33,
    "I": 34,
    "P": 35,
    "Return": 36,
    "Enter": 36,
    "L": 37,
    "J": 38,
    "K": 40,
    "Semicolon": 41,
    "Backslash": 42,
    "N": 45,
    "M": 46,
    "Tab": 48,
    "Space": 49,
    "Backtick": 50,
    "Backspace": 51,
    "Escape": 53,
    "LeftShift": 56,
    "Shift": 56,
    "CapsLock": 57,
    "LeftOption": 58,
    "Option": 58,
    "LeftControl": 59,
    "Control": 59,
    "RightShift": 60,
    "RightOption": 61,
    "RightControl": 62,
    "F5": 96,
    "F6": 97,
    "F7": 98,
    "F3": 99,
    "F8": 100,
    "F9": 101,
    "F11": 103,
    "F10": 109,
    "F12": 111,
    "F4": 118,
    "F2": 120,
    "F1": 122,
    "Left": 123,
    "Right": 124,
    "Down": 125,
    "Up": 126,
    # Synthetic mouse button codes
    "LMB": 200,
    "RMB": 201,
    "MMB": 202,
    "Mouse4": 203,
    "Mouse5": 204,
}

VALID_TARGETS: set[str] = {
    "CROSS",
    "CIRCLE",
    "SQUARE",
    "TRIANGLE",
    "SHARE",
    "PS",
    "OPTIONS",
    "L1",
    "R1",
    "L2",
    "R2",
    "L3",
    "R3",
    "DPAD_UP",
    "DPAD_DOWN",
    "DPAD_LEFT",
    "DPAD_RIGHT",
    "MIC",
    "TOUCHPAD",
}

REPO_ROOT = Path(__file__).resolve().parent.parent
PROFILES_DIR = REPO_ROOT / "profiles"


def resolve_profile_path(profile_name_or_path: str) -> Path:
    candidate = Path(profile_name_or_path)
    if candidate.is_file():
        return candidate
    by_name = PROFILES_DIR / f"{profile_name_or_path}.json"
    if by_name.is_file():
        return by_name
    raise FileNotFoundError(f"Profile not found: {profile_name_or_path} (looked in {PROFILES_DIR})")


def _key_to_code(name: str) -> int:
    if name not in KEYCODE_MAP:
        raise ValueError(f"Unknown key name in profile: '{name}'")
    return KEYCODE_MAP[name]


def load_profile(profile_name_or_path: str) -> dict[str, Any]:
    path = resolve_profile_path(profile_name_or_path)
    data = json.loads(path.read_text(encoding="utf-8"))
    validate_profile(data)
    return data


def validate_profile(data: dict[str, Any]) -> None:
    for section in ("hotkeys", "mouse", "movement", "on_foot", "vehicle"):
        if section not in data or not isinstance(data[section], dict):
            raise ValueError(f"Profile missing required section: '{section}'")

    _key_to_code(data["hotkeys"]["toggle_capture"])
    _key_to_code(data["hotkeys"]["toggle_vehicle_mode"])

    mv = data["movement"]
    for k in ("up", "down", "left", "right", "walk_modifier"):
        _key_to_code(mv[k])

    for mode in ("on_foot", "vehicle", "aircraft"):
        if mode not in data:
            continue
        if not isinstance(data[mode], dict):
            raise ValueError(f"Profile '{mode}' section must be an object")
        for key_name, target in data[mode].items():
            _key_to_code(key_name)
            if target not in VALID_TARGETS:
                raise ValueError(f"Invalid DualSense target '{target}' in '{mode}.{key_name}'")

    mouse = data["mouse"]
    if not (0.0 <= float(mouse.get("deadzone", 0.15)) <= 0.45):
        raise ValueError("mouse.deadzone must be between 0.0 and 0.45")
    if float(mouse.get("sensitivity", 1.0)) <= 0.0:
        raise ValueError("mouse.sensitivity must be > 0")

    smart = data.get("smart")
    if smart is not None:
        if not isinstance(smart, dict):
            raise ValueError("Profile 'smart' section must be an object")
        for k in (
            "toggle_smart",
            "toggle_aircraft",
            "rstick_hold",
            "hotwire_assist",
            "circle_assist",
            "rapid_tap",
            "cruise_toggle",
            "smart_vehicle",
            "sens_down",
            "sens_up",
            "mic_mute",
        ):
            if k in smart and smart[k]:
                _key_to_code(smart[k])


def export_runtime_config(profile: dict[str, Any], out_path: Path) -> Path:
    validate_profile(profile)
    hk = profile["hotkeys"]
    mv = profile["movement"]
    ms = profile["mouse"]
    sm = profile.get("smart") or {}

    lines: list[str] = [
        f"# Auto-generated runtime config for profile: {profile.get('name', 'custom')}",
        f"toggle_capture_key={_key_to_code(hk['toggle_capture'])}",
        f"toggle_vehicle_key={_key_to_code(hk['toggle_vehicle_mode'])}",
        f"toggle_aircraft_key={_key_to_code(sm.get('toggle_aircraft', 'O'))}",
        f"toggle_smart_key={_key_to_code(sm.get('toggle_smart', 'T'))}",
        f"rstick_hold_key={_key_to_code(sm.get('rstick_hold', 'Y'))}",
        f"hotwire_assist_key={_key_to_code(sm.get('hotwire_assist', 'U'))}",
        f"circle_assist_key={_key_to_code(sm.get('circle_assist', 'I'))}",
        f"rapid_tap_key={_key_to_code(sm.get('rapid_tap', 'L'))}",
        f"cruise_toggle_key={_key_to_code(sm.get('cruise_toggle', 'RightBracket'))}",
        f"smart_vehicle_key={_key_to_code(sm.get('smart_vehicle', 'F'))}",
        f"sens_down_key={_key_to_code(sm.get('sens_down', 'Minus'))}",
        f"sens_up_key={_key_to_code(sm.get('sens_up', 'Equals'))}",
        f"mic_mute_key={_key_to_code(sm.get('mic_mute', 'LeftBracket'))}",
        f"smart_mode_default={1 if sm.get('enabled_by_default', True) else 0}",
        f"smart_haptics={1 if sm.get('trackpad_haptics', True) else 0}",
        f"move_up_key={_key_to_code(mv['up'])}",
        f"move_down_key={_key_to_code(mv['down'])}",
        f"move_left_key={_key_to_code(mv['left'])}",
        f"move_right_key={_key_to_code(mv['right'])}",
        f"walk_mod_key={_key_to_code(mv['walk_modifier'])}",
        f"walk_scale={float(mv.get('walk_scale', 0.45)):.3f}",
        f"sensitivity={float(ms.get('sensitivity', 1.15)):.4f}",
        f"ads_sensitivity_scale={float(ms.get('ads_sensitivity_scale', 0.55)):.4f}",
        f"sniper_sensitivity_scale={float(ms.get('sniper_sensitivity_scale', 0.45)):.4f}",
        f"deadzone={float(ms.get('deadzone', 0.15)):.4f}",
        f"curve_exponent={float(ms.get('curve_exponent', 0.80)):.4f}",
        f"smoothing={float(ms.get('smoothing', 0.35)):.4f}",
        f"decay_half_life_ms={float(ms.get('decay_half_life_ms', 18.0)):.2f}",
        f"max_velocity_px_per_sec={float(ms.get('max_velocity_px_per_sec', 2200.0)):.2f}",
        f"invert_y={1 if ms.get('invert_y', False) else 0}",
        f"trackpad_mode={1 if ms.get('trackpad_mode', True) else 0}",
        f"trackpad_accel={float(ms.get('trackpad_accel', 1.45)):.4f}",
    ]

    for key_name, target in profile["on_foot"].items():
        lines.append(f"on_foot.{_key_to_code(key_name)}={target}")
    for key_name, target in profile["vehicle"].items():
        lines.append(f"vehicle.{_key_to_code(key_name)}={target}")
    for key_name, target in (profile.get("aircraft") or {}).items():
        lines.append(f"aircraft.{_key_to_code(key_name)}={target}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(out_path, "\n".join(lines) + "\n")
    return out_path
