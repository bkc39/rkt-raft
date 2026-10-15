"""Twin of raft/tests/smoke-test.rkt: a list of floats goes to the device
through pylibraft and comes back."""

import json
import sys

import numpy as np
import pylibraft
from pylibraft.common import device_ndarray

with open(sys.argv[1]) as f:
    values = json.load(f)["values"]

back = device_ndarray(np.array(values, dtype=np.float64)).copy_to_host()

with open(sys.argv[2], "w") as f:
    json.dump({"version": pylibraft.__version__, "values": back.tolist()}, f)
