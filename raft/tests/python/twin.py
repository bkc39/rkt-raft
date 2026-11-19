"""What the twins share: JSON has no NaN or infinity, and Racket's reader
drops the sign of -0.0, so they cross as the strings nan, inf, -inf and
-0.0; and NumPy's memory orders by name."""

import math

import numpy as np

SPECIAL = {"nan": math.nan, "inf": math.inf, "-inf": -math.inf, "-0.0": -0.0}


def decoded(xs):
    if isinstance(xs, list):
        return [decoded(x) for x in xs]
    return SPECIAL.get(xs, xs) if isinstance(xs, str) else xs


def encoded(xs):
    if isinstance(xs, list):
        return [encoded(x) for x in xs]
    if isinstance(xs, float) and math.isnan(xs):
        return "nan"
    if isinstance(xs, float) and math.isinf(xs):
        return "inf" if xs > 0 else "-inf"
    if isinstance(xs, float) and xs == 0 and math.copysign(1, xs) < 0:
        return "-0.0"
    return xs


def in_order(arr, order):
    return np.asfortranarray(arr) if order == "F" else np.ascontiguousarray(arr)
