"""Twin of raft/tests/device-resources-test.rkt: the CUDA devices CuPy sees."""

import json
import sys

import cupy as cp

with open(sys.argv[2], "w") as f:
    json.dump({"devices": cp.cuda.runtime.getDeviceCount()}, f)
