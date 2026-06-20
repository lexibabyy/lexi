"""SQLite trade journal."""
from __future__ import annotations

import sqlite3
from datetime import datetime


SCHEMA = """
CREATE TABLE IF NOT EXISTS trades (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    opened_at TEXT, closed_at TEXT,
    symbol TEXT, side TEXT,
    confidence REAL,
    entries INTEGER,
    avg_entry REAL, exit_price REAL,
    qty REAL, pnl REAL,
    r_multiple REAL,
    reason TEXT
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT, kind TEXT, payload TEXT
);
"""


class Journal:
    def __init__(self, path: str = "btc_bot.db"):
        self.conn = sqlite3.connect(path)
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def log_event(self, kind: str, payload: str = "") -> None:
        self.conn.execute(
            "INSERT INTO events(ts, kind, payload) VALUES (?,?,?)",
            (datetime.utcnow().isoformat(), kind, payload),
        )
        self.conn.commit()

    def record_trade(self, **kw) -> None:
        cols = ("opened_at", "closed_at", "symbol", "side", "confidence",
                "entries", "avg_entry", "exit_price", "qty", "pnl",
                "r_multiple", "reason")
        self.conn.execute(
            f"INSERT INTO trades({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
            tuple(kw.get(c) for c in cols),
        )
        self.conn.commit()

    def stats(self) -> dict:
        cur = self.conn.execute(
            "SELECT COUNT(*), COALESCE(SUM(pnl),0), "
            "COALESCE(SUM(CASE WHEN pnl>0 THEN 1 ELSE 0 END),0) FROM trades"
        )
        n, total, wins = cur.fetchone()
        return {
            "trades": n,
            "net_pnl": total,
            "win_rate": (wins / n) if n else 0.0,
        }
