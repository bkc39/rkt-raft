"""Twin of kmeans-canary/tests/twin-test.rkt: cuml.cluster.KMeans fits the data
the canary made, with the canary's init and seed, and sklearn scores both."""

import json
import sys

import cuml
import cupy as cp
import numpy as np
from sklearn.cluster import KMeans as SkKMeans
from sklearn.metrics import adjusted_rand_score


def host(a):
    return cp.asnumpy(a) if isinstance(a, cp.ndarray) else np.asarray(a)


def matched_centroids(ours, theirs, centroids):
    order = {}
    for mine, other in zip(ours, theirs):
        order.setdefault(int(mine), int(other))
    k = centroids.shape[0]
    return [centroids[order[i]].tolist() if i in order else None for i in range(k)]


def run(case):
    dtype = np.dtype(case["dtype"])
    X = np.asarray(case["X"], dtype=dtype)
    init = case["init"]
    if isinstance(init, list):
        init = np.asarray(init, dtype=dtype)
    km = cuml.cluster.KMeans(
        n_clusters=case["n_clusters"],
        init=init,
        random_state=case["seed"],
        n_init=case["n_init"],
        max_iter=case["max_iter"],
        tol=case["tol"],
    ).fit(X)
    labels = host(km.labels_).astype(np.int64)
    centroids = host(km.cluster_centers_)
    canary = np.asarray(case["labels"], dtype=np.int64)
    sk = SkKMeans(
        n_clusters=case["n_clusters"], random_state=case["seed"], n_init=10
    ).fit(X)
    return {
        "ari": adjusted_rand_score(canary, labels),
        "ari_truth": adjusted_rand_score(case["truth"], labels),
        "ari_sklearn": adjusted_rand_score(canary, sk.labels_),
        "inertia": float(km.inertia_),
        "n_iter": int(km.n_iter_),
        "centroids": matched_centroids(canary, labels, centroids),
        "version": cuml.__version__,
    }


with open(sys.argv[1]) as f:
    cases = json.load(f)["cases"]

with open(sys.argv[2], "w") as f:
    json.dump({"results": [run(case) for case in cases]}, f)
