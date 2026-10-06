"""Twin of raft/tests/compat-twin-test.rkt: np.asarray(nested, dtype=...)
then device_ndarray, beside the storage order and the values that come back."""

import json
import sys

import numpy as np
from pylibraft.common import device_ndarray


def run(case):
    arr = np.asarray(case["data"], dtype=case["dtype"])
    if case["order"] == "F":
        arr = np.asfortranarray(arr)
    back = device_ndarray(arr).copy_to_host()
    return {
        "dtype": arr.dtype.name,
        "shape": list(arr.shape),
        "storage": arr.ravel(order="K").tolist(),
        "values": back.tolist(),
    }


with open(sys.argv[1]) as f:
    cases = json.load(f)["cases"]

with open(sys.argv[2], "w") as f:
    json.dump({"results": [run(case) for case in cases]}, f)
