"""Twin of raft/tests/gpu/gather-twin-test.rkt: NumPy takes rows by index,
compresses them by a mask and compares them with a scalar; CuPy does the same
on the device, with cupy.take for the index."""

import json
import sys

import cupy as cp
import numpy as np
from cupy.cuda.compiler import CompileException
from twin import decoded, encoded, in_order

OPS = {
    "=": "equal",
    "<": "less",
    "<=": "less_equal",
    ">": "greater",
    ">=": "greater_equal",
    "!=": "not_equal",
}


def source(case):
    a = np.asarray(decoded(case["data"]), dtype=case["dtype"]).reshape(case["shape"])
    return in_order(a, case["order"])


def operand(case, key, xp):
    return xp.asarray(np.asarray(case[key], dtype=case[key + "_dtype"]))


def numpy_result(case, a):
    kind = case["kind"]
    if kind == "gather":
        return a[operand(case, "indices", np)]
    if kind == "select":
        return np.compress(operand(case, "mask", np), a, axis=0)
    return getattr(np, OPS[case["op"]])(a, decoded(case["x"])).astype(np.int32)


def cupy_values(case, a):
    kind = case["kind"]
    if kind == "gather":
        return cp.take(a, operand(case, "indices", cp), axis=0)
    if kind == "select":
        return cp.compress(operand(case, "mask", cp), a, axis=0)
    return getattr(cp, OPS[case["op"]])(a, decoded(case["x"])).astype(cp.int32)


def described(r):
    return {
        "values": encoded(r.tolist()),
        "shape": list(r.shape),
        "dtype": r.dtype.name,
        "c_contiguous": bool(r.flags.c_contiguous),
        "f_contiguous": bool(r.flags.f_contiguous),
    }


def cupy_result(case, a):
    try:
        r = cupy_values(case, cp.asarray(a))
    except (IndexError, ValueError, TypeError, CompileException) as e:
        return {"error": f"{type(e).__name__}: {e}"}
    return described(r)


def run(case):
    a = source(case)
    try:
        r = numpy_result(case, a)
    except (IndexError, ValueError, OverflowError, TypeError) as e:
        result = {"valid": False, "error": f"{type(e).__name__}: {e}"}
    else:
        result = {"valid": True, **described(r)}
    result["cupy"] = cupy_result(case, a)
    return result


with open(sys.argv[1]) as f:
    cases = json.load(f)["cases"]

with open(sys.argv[2], "w") as f:
    json.dump({"results": [run(case) for case in cases]}, f)
