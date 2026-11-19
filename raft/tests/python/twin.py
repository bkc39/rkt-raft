"""What the twins share: JSON has no NaN or infinity, so they cross as the
strings nan, inf and -inf; and NumPy's memory orders by name."""

import math

import numpy as np

SPECIAL = {"nan": math.nan, "inf": math.inf, "-inf": -math.inf}


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
    return xs


def in_order(arr, order):
    return np.asfortranarray(arr) if order == "F" else np.ascontiguousarray(arr)
