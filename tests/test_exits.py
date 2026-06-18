from types import SimpleNamespace

from src.exits import select_profit_exits


def _pos(ticket, profit):
    return SimpleNamespace(ticket=ticket, profit=profit)


def test_closes_only_positions_in_profit():
    positions = [_pos(1, 2.0), _pos(2, -3.0), _pos(3, 0.0)]
    to_close, reason = select_profit_exits(positions, min_profit_money=0.5,
                                           basket_profit_money=0.0)
    assert [p.ticket for p in to_close] == [1]
    assert reason == "in profit"


def test_respects_min_profit_threshold():
    positions = [_pos(1, 0.2), _pos(2, 0.6)]
    to_close, _ = select_profit_exits(positions, min_profit_money=0.5,
                                      basket_profit_money=0.0)
    assert [p.ticket for p in to_close] == [2]


def test_basket_closes_everything_when_total_reached():
    positions = [_pos(1, 3.0), _pos(2, -1.0), _pos(3, 4.0)]  # total = 6.0
    to_close, reason = select_profit_exits(positions, min_profit_money=10.0,
                                           basket_profit_money=5.0)
    assert {p.ticket for p in to_close} == {1, 2, 3}
    assert "basket" in reason


def test_basket_not_triggered_below_target():
    positions = [_pos(1, 1.0), _pos(2, 1.0)]  # total = 2.0 < 5.0
    to_close, reason = select_profit_exits(positions, min_profit_money=0.5,
                                           basket_profit_money=5.0)
    # Falls back to per-position: both are in profit >= 0.5
    assert {p.ticket for p in to_close} == {1, 2}
    assert reason == "in profit"


def test_empty_positions():
    assert select_profit_exits([], 0.5, 0.0) == ([], "")
