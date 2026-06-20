"""Confidence engine: 0-100 from five 20-point components."""
from __future__ import annotations

from dataclasses import dataclass


COMPONENTS = ("liquidity_sweep", "rsi_divergence", "choch", "bos", "volume")
POINTS = 20.0


@dataclass
class Confidence:
    score: float
    detail: dict
    side: str  # 'long' | 'short' | 'none'

    @property
    def passes(self) -> bool:
        return self.side != "none" and self.score >= 80.0


def score(side: str, *, liquidity_sweep: bool, rsi_divergence: bool,
          choch: bool, bos: bool, volume: bool) -> Confidence:
    detail = {
        "liquidity_sweep": liquidity_sweep,
        "rsi_divergence": rsi_divergence,
        "choch": choch,
        "bos": bos,
        "volume": volume,
    }
    total = sum(POINTS for v in detail.values() if v)
    return Confidence(score=total, detail=detail, side=side)
