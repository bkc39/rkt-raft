"""Twin of raft/tests/gpu/csr-twin-test.rkt: SciPy builds each case as a
csr_matrix, checks its format in full and reports its parts, its dense form
and its COO triplets; CuPy builds the same case from the same input."""

import json
import math
import sys

import cupy as cp
import cupyx.scipy.sparse as cusparse
import numpy as np
import scipy.sparse

DENSE_LIMIT = 10**6


def decoded(xs):
    if isinstance(xs, list):
        return [decoded(x) for x in xs]
    return math.nan if xs == "nan" else xs


def encoded(xs):
    if isinstance(xs, list):
        return [encoded(x) for x in xs]
    if isinstance(xs, float) and math.isnan(xs):
        return "nan"
    return xs


def csr_matrix(case, xp, sparse):
    dtype = case.get("dtype", "float64")

    def values(key):
        return xp.asarray(np.asarray(decoded(case[key]), dtype=dtype))

    kind = case["kind"]
    if kind == "dense":
        return sparse.csr_matrix(values("dense").reshape(case["shape"]))
    shape = tuple(case["shape"])
    if kind == "triplets":
        rows = xp.asarray(case["rows"], dtype=np.int64)
        cols = xp.asarray(case["cols"], dtype=np.int64)
        return sparse.csr_matrix(
            (values("vals"), (rows, cols)), shape=shape, dtype=dtype
        )
    index_dtype = case["index_dtype"]
    return sparse.csr_matrix(
        (
            values("data"),
            xp.asarray(case["indices"], dtype=index_dtype),
            xp.asarray(case["indptr"], dtype=case.get("indptr_dtype", index_dtype)),
        ),
        shape=shape,
    )


def parts_of(indptr, indices, data):
    return {
        "indptr": indptr.tolist(),
        "indices": indices.tolist(),
        "data": encoded(data.tolist()),
        "index_dtype": indices.dtype.name,
    }


def cupy_result(case):
    try:
        B = csr_matrix(case, cp, cusparse)
    except (TypeError, ValueError) as e:
        return {"error": f"{type(e).__name__}: {e}"}
    return parts_of(B.indptr.get(), B.indices.get(), B.data.get())


def run(case):
    try:
        A = csr_matrix(case, np, scipy.sparse)
        A.check_format(full_check=True)
    except ValueError as e:
        return {"valid": False, "error": str(e)}
    result = {"valid": True, "shape": list(A.shape)}
    result.update(parts_of(A.indptr, A.indices, A.data))
    rows, cols = A.shape
    result["dense"] = (
        encoded(A.toarray().tolist()) if rows * cols <= DENSE_LIMIT else None
    )
    coo = A.tocoo()
    result["coo"] = [coo.row.tolist(), coo.col.tolist(), encoded(coo.data.tolist())]
    result["cupy"] = cupy_result(case)
    return result


with open(sys.argv[1]) as f:
    cases = json.load(f)["cases"]

with open(sys.argv[2], "w") as f:
    json.dump({"results": [run(case) for case in cases]}, f)
