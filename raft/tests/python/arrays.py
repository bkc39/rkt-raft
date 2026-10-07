"""Twin of raft/tests/array-twin-test.rkt: each case goes to the device
through pylibraft and comes back, beside NumPy's strides and layouts."""

import json
import sys

import numpy as np
from pylibraft.common import device_ndarray


def in_order(arr, order):
    return np.asfortranarray(arr) if order == "F" else np.ascontiguousarray(arr)


def element_strides(arr):
    return [s // arr.itemsize for s in arr.strides]


def run(case):
    if case.get("empty"):
        arr = np.empty(case["shape"], dtype=case["dtype"], order=case["order"])
        d = device_ndarray.empty(
            case["shape"], dtype=case["dtype"], order=case["order"]
        )
        return {
            "strides": element_strides(arr),
            "c_contiguous": d.c_contiguous,
            "numpy_c": bool(arr.flags.c_contiguous),
            "numpy_f": bool(arr.flags.f_contiguous),
        }
    data = case["data"]
    arr = np.array(data, dtype=case["dtype"]) if case["dtype"] else np.array(data)
    arr = in_order(arr, case["order"])
    back = device_ndarray(arr).copy_to_host()
    other = "C" if case["order"] == "F" else "F"
    return {
        "dtype": arr.dtype.name,
        "strides": element_strides(arr),
        "values": back.tolist(),
        "storage": arr.ravel(order="K").tolist(),
        "relaid": in_order(arr, other).ravel(order="K").tolist(),
    }


with open(sys.argv[1]) as f:
    cases = json.load(f)["cases"]

with open(sys.argv[2], "w") as f:
    json.dump({"results": [run(case) for case in cases]}, f)
