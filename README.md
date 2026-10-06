# rkt-raft

Racket bindings to [NVIDIA RAFT](https://github.com/rapidsai/raft): CUDA device
arrays and primitives, and the base for Racket cuML bindings.

Linux on x86-64 with an NVIDIA GPU (compute capability 8.6 or a later 8.x), a
CUDA 13 driver (release 580 or newer) and Racket 9.3:

```bash
raco pkg install raft
racket -l racket/base -l raft -e '(raft-version)'
```

A catalog install does not yet fetch the native libraries
([#24](https://github.com/bkc39/rkt-raft/issues/24)); until it does, use the
development shell below.

- The manual is `raft/scribblings/raft.scrbl`: a guide (Getting started,
  Concepts) and a reference.
- The approved plan is [`plans/scoping-plan.md`](plans/scoping-plan.md).

## Development

Nix with flakes. The shell builds the native library, installs `raft` into a
Racket user directory of the checkout's own, and provides the Python twins
(`pylibraft`, `rmm`, CuPy, NumPy from the same RAPIDS release):

```bash
git clone https://github.com/bkc39/rkt-raft && cd rkt-raft
nix develop
raco test raft                 # the Racket tests
scripts/gpu-suite.sh           # everything that needs the GPU, parity with Python included
scripts/render-docs.sh <dir>   # the manual, red on any warning or broken link
```

A test that cannot run prints a line starting with `SKIP:`; a green run with
SKIP lines has not tested what was skipped. Contributors and agents:
[`AGENTS.md`](AGENTS.md).

### Native bindings

A downstream shim (the cuML binding, the k-means canary) compiles against the
raftrkt headers and the RAPIDS 26.08 prefix that `libraftrkt` was built with,
and never another RAPIDS. The flake provides them as `packages.raft-dev` (the
headers and `find_package(raftrkt)`), `packages.shim` (`libraftrkt`) and
`packages.rapids` (RAFT, RMM, cuML, cuVS and their libraries); a package
outside this repository takes the flake as an input and uses them. The canary's derivation, `kmeansCanary` in
`flake.nix`, is the pattern, and `downstream/kmeans-canary/` a minimal cuML
binding on the frozen interface in `raft/unsafe`:

```bash
nix build --max-jobs 1 --cores 4 .#kmeans-canary
export RAFT_KMEANS_CANARY=$PWD/result/lib/libkmeans_canary.so   # nix develop sets it
```

Apache-2.0.
