from types import SimpleNamespace

from src.config import RiskConfig
from src.risk import DailyLossGuard, calculate_lot


def _symbol(**kw):
    defaults = dict(
        trade_tick_value=1.0,
        trade_tick_size=0.0001,
        volume_step=0.01,
        volume_min=0.01,
        volume_max=100.0,
    )
    defaults.update(kw)
    return SimpleNamespace(**defaults)


def test_lot_scales_with_risk():
    cfg = RiskConfig(risk_per_trade_pct=1.0, min_lot=0.01, max_lot=100.0)
    lot = calculate_lot(cfg, equity=10_000, stop_loss_points=0.0010, symbol_info=_symbol())
    # risk = $100; loss per lot = (0.0010/0.0001)*1 = $10 -> 10 lots
    assert abs(lot - 10.0) < 1e-6


def test_lot_respects_max_cap():
    cfg = RiskConfig(risk_per_trade_pct=50.0, min_lot=0.01, max_lot=2.0)
    lot = calculate_lot(cfg, equity=10_000, stop_loss_points=0.0010, symbol_info=_symbol())
    assert lot == 2.0


def test_lot_respects_min_floor():
    cfg = RiskConfig(risk_per_trade_pct=0.01, min_lot=0.05, max_lot=100.0)
    lot = calculate_lot(cfg, equity=100, stop_loss_points=0.0010, symbol_info=_symbol())
    assert lot >= 0.05


def test_daily_loss_guard_blocks_after_limit():
    cfg = RiskConfig(max_daily_loss_pct=5.0)
    guard = DailyLossGuard(cfg)
    guard.update_day(10_000)
    assert guard.can_trade(9_600) is True   # 4% down, still allowed
    assert guard.can_trade(9_400) is False  # 6% down, blocked
