"""Risk manager: drawdown limits, per-trade sizing, loss-streak pause.

Enforces:
  - 0.5% risk per entry, 2% max per trade idea (cycle)
  - 3% daily, 8% weekly drawdown stops
  - 10% emergency hard-stop
  - pause after 3 consecutive losing trade ideas
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime


@dataclass
class RiskState:
    equity: float
    day: date
    week: int
    day_start_equity: float
    week_start_equity: float
    consecutive_losses: int = 0
    halted_today: bool = False
    halted_week: bool = False
    emergency_stop: bool = False
    cycle_risk_used: float = 0.0     # fraction of equity at risk in current idea


class RiskManager:
    def __init__(self, settings, equity: float, now: datetime | None = None):
        self.s = settings
        now = now or datetime.utcnow()
        self.peak_equity = equity
        self.st = RiskState(
            equity=equity,
            day=now.date(),
            week=now.isocalendar().week,
            day_start_equity=equity,
            week_start_equity=equity,
        )

    # --- time rollover ---
    def _roll(self, now: datetime) -> None:
        if now.date() != self.st.day:
            self.st.day = now.date()
            self.st.day_start_equity = self.st.equity
            self.st.halted_today = False
        wk = now.isocalendar().week
        if wk != self.st.week:
            self.st.week = wk
            self.st.week_start_equity = self.st.equity
            self.st.halted_week = False

    def update_equity(self, equity: float, now: datetime) -> None:
        self.st.equity = equity
        self.peak_equity = max(self.peak_equity, equity)
        self._roll(now)
        self._check_limits()

    def _dd(self, anchor: float) -> float:
        return (anchor - self.st.equity) / anchor if anchor > 0 else 0.0

    def _check_limits(self) -> None:
        if self._dd(self.peak_equity) >= self.s.emergency_dd:
            self.st.emergency_stop = True
        if self._dd(self.st.day_start_equity) >= self.s.max_daily_dd:
            self.st.halted_today = True
        if self._dd(self.st.week_start_equity) >= self.s.max_weekly_dd:
            self.st.halted_week = True

    # --- gates ---
    def can_open_new_idea(self) -> tuple[bool, str]:
        if self.st.emergency_stop:
            return False, "EMERGENCY 10% drawdown hit — trading disabled"
        if self.st.halted_week:
            return False, "weekly drawdown limit reached"
        if self.st.halted_today:
            return False, "daily drawdown limit reached"
        if self.st.consecutive_losses >= self.s.max_consecutive_losses:
            return False, "paused after 3 consecutive losses"
        return True, "ok"

    def can_add_entry(self, next_risk: float) -> bool:
        return (self.st.cycle_risk_used + next_risk) <= self.s.max_cycle_risk + 1e-9

    # --- sizing ---
    def position_size(self, entry: float, stop: float) -> float:
        risk_money = self.st.equity * self.s.risk_per_entry
        per_unit = abs(entry - stop)
        if per_unit <= 0:
            return 0.0
        return risk_money / per_unit

    # --- lifecycle ---
    def open_cycle(self) -> None:
        self.st.cycle_risk_used = 0.0

    def register_entry(self) -> None:
        self.st.cycle_risk_used += self.s.risk_per_entry

    def close_idea(self, pnl: float, now: datetime) -> None:
        self.st.equity += pnl
        if pnl < 0:
            self.st.consecutive_losses += 1
        else:
            self.st.consecutive_losses = 0
        self.st.cycle_risk_used = 0.0
        self.update_equity(self.st.equity, now)

    def note_idea_result(self, pnl: float) -> None:
        """Update the loss streak / reset the cycle WITHOUT touching equity
        (used when equity is marked from the broker elsewhere)."""
        if pnl < 0:
            self.st.consecutive_losses += 1
        else:
            self.st.consecutive_losses = 0
        self.st.cycle_risk_used = 0.0
