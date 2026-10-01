# rkt-raft

Racket bindings to [NVIDIA RAFT](https://github.com/rapidsai/raft): CUDA device
arrays and primitives, and the base for Racket cuML bindings.

Linux on x86-64 with an NVIDIA GPU (CUDA 13 driver, release 580 or newer) and
Nix with flakes:

```bash
nix develop
racket -l racket/base -l raft -e '(raft-version)'
```

- The manual is `raft/scribblings/raft.scrbl`: a guide (Getting started,
  Concepts) and a reference. Render it with `scripts/render-docs.sh <dir>`.
- The approved plan is [`plans/scoping-plan.md`](plans/scoping-plan.md).
- Contributors and agents: [`AGENTS.md`](AGENTS.md).

Apache-2.0.
