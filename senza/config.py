"""User configuration (~/.config/senza/config.json) shared by CLI, Senza.app, Raycast and the LaunchAgent.

Nothing user-specific (tailnet IPs, SSIDs, hostnames) lives in the repository; it lives here.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .state import atomic_write_json, read_json_dict

CONFIG_ENV = "SENZA_CONFIG"
EXIT_NODE_ENV = "SENZA_EXIT_NODE"

# Friendly CLI aliases -> dotted config paths.
KEY_ALIASES: dict[str, str] = {
    "exit-node": "tailscale.exit_node",
    "exit_node": "tailscale.exit_node",
    "exit-nodes": "tailscale.exit_nodes",
    "probe-host": "network.probe_host",
}


def config_path() -> Path:
    override = (os.environ.get(CONFIG_ENV) or "").strip()
    if override:
        return Path(override).expanduser()
    xdg = (os.environ.get("XDG_CONFIG_HOME") or "").strip()
    base = Path(xdg).expanduser() if xdg else Path.home() / ".config"
    return base / "senza" / "config.json"


def load_config(path: Path | None = None) -> dict[str, Any]:
    return read_json_dict(path or config_path())


def save_config(cfg: dict[str, Any], path: Path | None = None) -> Path:
    target = path or config_path()
    atomic_write_json(target, cfg)
    return target


def normalize_key(key: str) -> str:
    key = key.strip()
    return KEY_ALIASES.get(key, key)


def get_value(key: str, cfg: dict[str, Any] | None = None) -> Any:
    node: Any = load_config() if cfg is None else cfg
    for part in normalize_key(key).split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def set_value(key: str, value: Any, path: Path | None = None) -> dict[str, Any]:
    cfg = load_config(path)
    parts = normalize_key(key).split(".")
    node = cfg
    for part in parts[:-1]:
        child = node.get(part)
        if not isinstance(child, dict):
            child = {}
            node[part] = child
        node = child
    node[parts[-1]] = value
    save_config(cfg, path)
    return cfg


def unset_value(key: str, path: Path | None = None) -> dict[str, Any]:
    cfg = load_config(path)
    parts = normalize_key(key).split(".")
    node: Any = cfg
    for part in parts[:-1]:
        node = node.get(part) if isinstance(node, dict) else None
        if node is None:
            return cfg
    if isinstance(node, dict) and parts[-1] in node:
        del node[parts[-1]]
        save_config(cfg, path)
    return cfg


def configured_exit_node(explicit: str | None = None) -> str | None:
    """Exit node from explicit arg > $SENZA_EXIT_NODE > config file. None when nothing configured."""
    for candidate in (explicit, os.environ.get(EXIT_NODE_ENV), get_value("tailscale.exit_node")):
        if isinstance(candidate, str) and candidate.strip():
            return candidate.strip()
    return None


def configured_exit_nodes(explicit: str | None = None) -> list[str]:
    """Ordered, de-duplicated candidate exit nodes (primary first, then `tailscale.exit_nodes`)."""
    out: list[str] = []
    primary = configured_exit_node(explicit)
    if primary:
        out.append(primary)
    extra = get_value("tailscale.exit_nodes")
    if isinstance(extra, list):
        for item in extra:
            if isinstance(item, str) and item.strip() and item.strip() not in out:
                out.append(item.strip())
    return out


def parse_cli_value(raw: str) -> Any:
    """`senza config set` value parsing: true/false, ints, floats, comma lists; else string."""
    low = raw.strip().lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    if "," in raw:
        return [p.strip() for p in raw.split(",") if p.strip()]
    return raw.strip()
