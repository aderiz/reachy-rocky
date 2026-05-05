"""EMA and critically-damped second-order filters.

CriticalDamper:
    Second-order critically-damped filter that drives a state x toward a
    target r without overshoot. Used here to smoothly track the world-frame
    yaw/pitch targets as detections arrive sparsely. Settling time
    ~ 5.83 / omega seconds (5% criterion); for omega=3 rad/s, ~1.94 s.
    The original face tracker used omega = 3 rad/s (memory).

EMA:
    Plain exponential moving average. alpha=0.5 in the original face
    tracker (memory).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class EMA:
    alpha: float
    value: float = 0.0
    initialized: bool = False

    def reset(self, value: float = 0.0) -> None:
        self.value = value
        self.initialized = False

    def update(self, x: float) -> float:
        if not self.initialized:
            self.value = x
            self.initialized = True
        else:
            self.value = self.alpha * self.value + (1.0 - self.alpha) * x
        return self.value


@dataclass
class CriticalDamper:
    """Critically-damped 2nd-order filter.

    Implements x'' + 2*omega*x' + omega^2 * (x - r) = 0
    via semi-implicit Euler stepping. Stable for typical 50-100 Hz tick rates.
    """
    omega: float
    x: float = 0.0   # position
    v: float = 0.0   # velocity

    def reset(self, x: float = 0.0) -> None:
        self.x = x
        self.v = 0.0

    def step(self, dt: float, target: float) -> float:
        # Semi-implicit Euler:
        #   v <- v + dt * (-2*omega*v - omega^2 * (x - target))
        #   x <- x + dt * v
        a = -2.0 * self.omega * self.v - (self.omega ** 2) * (self.x - target)
        self.v += dt * a
        self.x += dt * self.v
        return self.x
