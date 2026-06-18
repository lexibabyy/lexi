"""Profit-taking exit logic.

Pure, side-effect-free selection so it can be unit-tested without MT5.
A "position" here is anything with a ``profit`` attribute (the floating
profit/loss in account currency), which matches MT5 position objects.
"""
from __future__ import annotations

from typing import List, Sequence, Tuple


def select_profit_exits(
    positions: Sequence,
    min_profit_money: float,
    basket_profit_money: float,
) -> Tuple[List, str]:
    """Decide which positions to close to bank earnings.

    Returns ``(positions_to_close, reason)``.

    1. If ``basket_profit_money`` > 0 and the combined floating profit of
       all positions reaches it, close everything at once.
    2. Otherwise close each individual position whose profit is positive
       and at least ``min_profit_money`` — i.e. "as long as it has
       earnings, close it".
    """
    if not positions:
        return [], ""

    if basket_profit_money and basket_profit_money > 0:
        total = sum(p.profit for p in positions)
        if total >= basket_profit_money:
            return list(positions), f"basket profit {total:.2f} >= {basket_profit_money:.2f}"

    to_close = [
        p for p in positions
        if p.profit > 0 and p.profit >= min_profit_money
    ]
    return to_close, "in profit"
