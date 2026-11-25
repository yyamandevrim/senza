"""Connection history: every WAN probe and Remote Play session, per network (sqlite, stdlib only)."""

from __future__ import annotations

import sqlite3
import statistics
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HISTORY_DB = Path.home() / ".local" / "share" / "senza" / "history.sqlite3"
RETENTION_DAYS = 120

SCHEMA = """
CREATE TABLE IF NOT EXISTS probes (
    ts REAL NOT NULL,
    network_id TEXT,
    host TEXT,
    rtt_median_ms REAL,
    rtt_p95_ms REAL,
    jitter_ms REAL,
    loss_pct REAL,
    awdl_active INTEGER,
    source TEXT
);
CREATE INDEX IF NOT EXISTS probes_net_ts ON probes(network_id, ts);
CREATE TABLE IF NOT EXISTS sessions (
    started REAL NOT NULL,
    ended REAL,
    network_id TEXT,
    client TEXT,
    input_mode TEXT,
    bypass TEXT,
    exit_code INTEGER,
    latency_p50_ms REAL,
    latency_p95_ms REAL
);
"""
MIGRATIONS = (
    "ALTER TABLE sessions ADD COLUMN latency_p50_ms REAL",
    "ALTER TABLE sessions ADD COLUMN latency_p95_ms REAL",
)


@contextmanager
def _db(path: Path | None = None) -> Iterator[sqlite3.Connection]:
    p = path or HISTORY_DB
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(p), timeout=2.0)
    try:
        conn.executescript(SCHEMA)
        cols = {r[1] for r in conn.execute("PRAGMA table_info(sessions)")}
        for stmt in MIGRATIONS:
            if stmt.split()[5] not in cols:
                conn.execute(stmt)
        yield conn
        conn.commit()
    finally:
        conn.close()


def record_probe(report: Any, network_id: str | None, source: str, path: Path | None = None) -> None:
    """Store a net_probe.NetworkReport. Never raises: history must not break a launch."""
    try:
        with _db(path) as conn:
            conn.execute(
                "INSERT INTO probes VALUES (?,?,?,?,?,?,?,?,?)",
                (
                    time.time(),
                    network_id,
                    getattr(report, "host", None),
                    getattr(report, "rtt_median_ms", None),
                    getattr(report, "rtt_p95_ms", None),
                    getattr(report, "jitter_ms", None),
                    getattr(report, "packet_loss_pct", None),
                    int(bool(getattr(report, "awdl_active", False))),
                    source,
                ),
            )
            conn.execute("DELETE FROM probes WHERE ts < ?", (time.time() - RETENTION_DAYS * 86400,))
    except sqlite3.Error:
        pass


def start_session(
    network_id: str | None, client: str, input_mode: str, bypass: str | None, path: Path | None = None
) -> int | None:
    try:
        with _db(path) as conn:
            cur = conn.execute(
                "INSERT INTO sessions (started, network_id, client, input_mode, bypass) VALUES (?,?,?,?,?)",
                (time.time(), network_id, client, input_mode, bypass or "off"),
            )
            return int(cur.lastrowid or 0) or None
    except sqlite3.Error:
        return None


def end_session(
    session_id: int | None, exit_code: int, latency: dict[str, Any] | None = None, path: Path | None = None
) -> None:
    if not session_id:
        return
    lat = latency or {}
    try:
        with _db(path) as conn:
            conn.execute(
                "UPDATE sessions SET ended=?, exit_code=?, latency_p50_ms=?, latency_p95_ms=? WHERE rowid=?",
                (time.time(), exit_code, lat.get("p50_ms"), lat.get("p95_ms"), session_id),
            )
    except sqlite3.Error:
        pass


def recent_sessions(limit: int = 10, path: Path | None = None) -> list[dict[str, Any]]:
    with _db(path) as conn:
        rows = conn.execute(
            "SELECT started, ended, network_id, client, input_mode, bypass, exit_code, latency_p50_ms, latency_p95_ms "
            "FROM sessions ORDER BY started DESC LIMIT ?",
            (limit,),
        ).fetchall()
    keys = (
        "started",
        "ended",
        "network_id",
        "client",
        "input_mode",
        "bypass",
        "exit_code",
        "latency_p50_ms",
        "latency_p95_ms",
    )
    return [dict(zip(keys, r)) for r in rows]  # noqa: B905 - equal lengths; zip(strict=) needs 3.10


def _p(values: list[float], q: float) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return round(values[0], 1)
    cuts = statistics.quantiles(sorted(values), n=100, method="inclusive")
    return round(cuts[max(0, min(98, int(q) - 1))], 1)


@dataclass
class NetworkStats:
    network_id: str | None
    probes: int
    sessions: int
    play_minutes: float
    rtt_median_ms: float | None
    rtt_p75_ms: float | None
    jitter_p75_ms: float | None
    loss_mean_pct: float | None
    awdl_seen_pct: float | None
    last_seen: float | None


def network_stats(network_id: str | None, days: int = 30, path: Path | None = None) -> NetworkStats:
    since = time.time() - days * 86400
    with _db(path) as conn:
        rows = conn.execute(
            "SELECT rtt_median_ms, jitter_ms, loss_pct, awdl_active, ts FROM probes WHERE network_id IS ? AND ts >= ?",
            (network_id, since),
        ).fetchall()
        sess = conn.execute(
            "SELECT COUNT(*), COALESCE(SUM(COALESCE(ended, started) - started), 0) FROM sessions "
            "WHERE network_id IS ? AND started >= ?",
            (network_id, since),
        ).fetchone()
    rtts = [r[0] for r in rows if r[0] is not None]
    jit = [r[1] for r in rows if r[1] is not None]
    loss = [r[2] for r in rows if r[2] is not None]
    return NetworkStats(
        network_id=network_id,
        probes=len(rows),
        sessions=int(sess[0] or 0),
        play_minutes=round(float(sess[1] or 0) / 60.0, 1),
        rtt_median_ms=_p(rtts, 50),
        rtt_p75_ms=_p(rtts, 75),
        jitter_p75_ms=_p(jit, 75),
        loss_mean_pct=round(statistics.fmean(loss), 2) if loss else None,
        awdl_seen_pct=round(100.0 * sum(r[3] for r in rows) / len(rows), 0) if rows else None,
        last_seen=max((r[4] for r in rows), default=None),
    )


def known_networks(days: int = 30, path: Path | None = None) -> list[str | None]:
    since = time.time() - days * 86400
    with _db(path) as conn:
        rows = conn.execute(
            "SELECT network_id, MAX(ts) AS last FROM probes WHERE ts >= ? GROUP BY network_id ORDER BY last DESC",
            (since,),
        ).fetchall()
    return [r[0] for r in rows]


def recent_probes(network_id: str | None, limit: int = 60, path: Path | None = None) -> list[dict[str, Any]]:
    with _db(path) as conn:
        rows = conn.execute(
            "SELECT ts, rtt_median_ms, jitter_ms, loss_pct FROM probes WHERE network_id IS ? ORDER BY ts DESC LIMIT ?",
            (network_id, limit),
        ).fetchall()
    return [{"ts": r[0], "rtt_ms": r[1], "jitter_ms": r[2], "loss_pct": r[3]} for r in reversed(rows)]


def conservative_report(report: Any, stats: NetworkStats, min_probes: int = 5) -> Any:
    """Blend a live probe with this network's history: use whichever is worse (p75 history vs now).

    One lucky quiet probe on a network that is usually jittery should not pick the 1080p preset.
    """
    if stats.probes < min_probes:
        return report
    import dataclasses

    changes: dict[str, Any] = {}
    if stats.rtt_p75_ms is not None and (report.rtt_median_ms or 0) < stats.rtt_p75_ms:
        changes["rtt_median_ms"] = stats.rtt_p75_ms
    if stats.jitter_p75_ms is not None and (report.jitter_ms or 0) < stats.jitter_p75_ms:
        changes["jitter_ms"] = stats.jitter_p75_ms
    if stats.loss_mean_pct is not None and report.packet_loss_pct < stats.loss_mean_pct:
        changes["packet_loss_pct"] = stats.loss_mean_pct
    return dataclasses.replace(report, **changes) if changes else report
