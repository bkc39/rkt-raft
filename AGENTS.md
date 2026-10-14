# AGENTS.md

This file is the canonical guidance for agents and contributors. `CLAUDE.md`
only points here.

## Project overview

`raft` is a Racket binding to [NVIDIA RAFT](https://github.com/rapidsai/raft):
CUDA device arrays and data-science primitives, and the base a later Racket
cuML binding (`rkt-cuml`) stands on. The approved scoping plan is
`plans/scoping-plan.md` (approved 2026-10-01); read its §3 Architecture, §5
raft/core, §6 raft/array and raft/compat, §7 Memory model, §8 Shim ABI, §9
Parity, §10 Build and §12 Starting cuML work before changing the design.

- **Pins.** RAPIDS **26.08** (the `libraft-cu13`, `librmm-cu13` and
  `rapids-logger` 0.2.3 wheels from PyPI, and for cuML `libcuml-cu13` 26.8.0,
  `libcuvs-cu13` 26.8.1, `libnvforest-cu13` 26.8.0 and `nvidia-nccl-cu13`
  2.32.3). 26.10 is not on PyPI; never bump without its own leg (#7). **CUDA
  13 only.** Development builds target **sm_86** (the lab host's RTX 3090
  Ti). Racket **9.3**. One nixpkgs pin, `07e1d92`, which carries Racket 9.3
  and `cudaPackages_13` = CUDA 13.2 (with nvJitLink taken from 13.3; see
  Decisions recorded in L1d).
- **Platforms.** `x86_64-linux` with an NVIDIA GPU. No CPU fallback, no macOS.
- **Package.** One package and one collection, `raft` (the `raft/`
  directory), one manual. Apache-2.0.
- **Status.** Milestone M1 "cuML-ready" (epic #1) is reached with L1d. Leg 0 (#2)
  landed the scaffold: the flake, the wheels, the shim, the FFI layer, the
  gates, the formatting and lint toolchain, CI and the manual skeleton, with
  `raft-version` and `raft-abi`. Leg L1a (#3) landed `raft/core`:
  `device-resources`, `device-resources?`, `resources-device`,
  `resources-sync!`, `current-device-resources`, `with-device-resources`,
  `device-count` and `exn:fail:raft`, and the default async memory resource.
  Leg L1b (#4) landed `raft/array`: `device-matrix`, `device-vector`, the
  predicates, `shape`, `dtype`, `layout`, `strides`, `numel`, `contiguous`,
  printing, phantom bytes, and the list, nested-list and flvector
  conversions; in the shim, the `rr_view` descriptor, the dtype and op
  tables, the dispatch macros and the first kernels. Leg L1c (#5) landed
  `raft/compat`: the conversion table for vectors, nested vectors and lists
  of either rank, `f32vector`s, `f64vector`s, byte strings, `math/matrix`
  matrices and `math/array` arrays of rank 1 and 2, plus re-exports of
  `raft/array`'s list and flvector conversions. Leg L1d (#6) landed the
  frozen downstream interface: `raft/unsafe` (`resources->handle-pointer`,
  `with-array-views`, `status-checker`, `raft-abi-pointer`), the C entry
  point `rr_resources_handle`, the header-only `raftrkt/view.hpp`,
  `raftrkt/error.hpp` and `raftrkt/abi.h` in `packages.raft-dev`, cuML in
  `packages.rapids`, and the k-means canary in `downstream/kmeans-canary/`
  that proves them against `cuml.cluster.KMeans`. #21 runs long downstream
  calls as jobs on a native executor (#32). #22 added outputs sized by the
  call: `deposit`, `deposit?`, `with-deposits` and `deposit->list` in
  `raft/unsafe`, `raftrkt/deposit.h` and the header-only
  `raftrkt/deposit.hpp`, and the canary's `cluster-members` (raft 0.2).

## Layout

```
flake.nix  flake.lock         one system: x86_64-linux
nix/rapids.nix                the RAPIDS wheels as one patched prefix (packages.rapids;
                                passthru.core is RAFT, RMM and the logger only)
nix/python-twins.nix          pylibraft, rmm, CuPy, cuML (and cudf, which it imports),
                                scikit-learn for the twins
nix/treefmt.nix               what `nix fmt` runs: formatters and linters
nix/racket-tools.nix          raco fmt and raco review, pinned as a fixed-output derivation
.fmt.rkt                      raco fmt's layout rules for this repository's own forms
lint/                         raft-lint: the raco review extension for the test macros
shim/                         libraftrkt: C++20 over RAFT's headers (CMake, g++; nvcc for .cu)
  include/raftrkt/            C headers: core.h memory.h array.h abi.h job.h, umbrella c_api.h;
                                header-only C++: error.hpp view.hpp job.hpp (all frozen, below)
  cmake/raftrkt-config.cmake  find_package(raftrkt): raftrkt::headers, in packages.raft-dev
  src/{core,array,detail}/    host C++ (.cpp); a .cu only for code that launches kernels
  src/detail/dtypes.def       the dtypes: name, C++ type, code
  src/array/ops.def           what the array module instantiates, per op
  tests/                      gtest; GPU cases print SKIP without a device
  tests/probe/                libraftrkt_probe, a second RMM user for the tests, and a
                                downstream that fills deposits (rr_probe_deposit)
raft/                         the Racket package and collection
  main.rkt core.rkt           the public surface
  private/foreign/*.rkt       FFI bindings, one module per shim header
  array.rkt                   raft/array, re-exported by main.rkt
  compat.rkt                  raft/compat, the only module that requires math-lib
  unsafe.rkt                  raft/unsafe, the frozen interface for native bindings
  private/{abi,error,resource,resources,install-native,deposit}.rkt
  private/{array,dtype,pack,print}.rkt   arrays over buffers, the tables, packing, printing
  scribblings/                the manual: guide/ chapters, reference/ sections
  tests/                      raco tests; tests/private/ the harness; tests/python/ the twins
scripts/                      gates, the GPU suite, the docs render, the binding census
bench/README.md               how to run the benchmarks, and the last measured table (#25)
bench/conversions.rkt         the conversion speed table (raft/compat), 10^6 elements
bench/typed-arrays.rkt        math/array arrays built in Typed Racket against untyped (typed-table.rkt)
downstream/kmeans-canary/     the k-means canary, a minimal cuML binding (packages.kmeans-canary)
  include/ src/ tests/        the C API (kc_), its C++ over libcuml, gtests with libraftrkt
  kmeans-canary/              the Racket package: private/native.rkt, main.rkt, pool.rkt,
                                tests/ (the cuML twin, 1,000 fits, the shared pool)
plans/scoping-plan.md         the approved plan (revision 5), as Markdown
```

## Owner rules

1. **AGENTS.md is canonical.** Keep it current in the same PR as the change.
2. **No explanatory comments in source.** Usage docs live in Scribble. A
   comment survives only if it states an invariant the code cannot show, a
   cross-boundary gotcha, or a deliberate deviation from upstream behaviour;
   the owner deletes the rest in review. Delete, don't shorten.
3. **No contracts in M1** (owner decision, a deviation from rktorch and
   rkt-polars).
   - Plain `provide`. No `define/contract-out`, no `define/checked-out`, and
     no hand-written argument validation in Racket in their place.
   - One exception type, `exn:fail:raft`, carrying RAFT's or the shim's
     message, prefixed with the Racket caller's name, plus a `kind` field
     (`'out-of-memory`, `'cuda`, `'logic`, `'generic`) for the memory retry.
     The shim's own refusals never name its `rr_` entry points (internal
     names in user-facing errors are bugs, bkc39/rkt-polars#151–#153); a
     failed CUDA call is named (`cudaGetDeviceCount: …`).
   - The shim keeps the memory-safety checks: C++ exceptions are translated
     into a status, and an unsupported dtype, layout or rank, a NULL handle,
     or output extents that do not fit are refused before the GPU is touched.
     A bad call raises; it never corrupts memory or crashes.
   - Contracts arrive in their own later leg.
4. **Constructors are named after the type:** `(device-matrix 1000 128)`,
   `(device-resources)`, `(cuda-async-memory-resource)`. Never `make-…`.
   Predicates look like `device-matrix?`. On a name collision prefix rather
   than fall back to `make-`: `cuda-stream`, because `racket/stream` exports
   `stream`.
5. **Names.** `->` for conversions (`device-matrix->list*`), never `-to-`. A
   star means nested, as in `math/array` (`list*->array`). `in-*` sequences
   use `make-do-sequence`. The short getters `shape`, `dtype`, `layout`
   collide with rktorch's; accepted for M1 (#8).
6. **Macros.** `define-syntax-parse-rule`, or `define-syntax-parser` for
   several clauses (Resyntax rewrites a single-clause parser into a parse
   rule), with a syntax class on every pattern variable. Never
   `define-syntax-rule` or `syntax-rules`: `scripts/no-syntax-rule.sh` gates
   it.
7. **Scoped native resources** go through `with-*` forms over
   `dynamic-wind` (`raft/private/resource.rkt`), with the finalizer as the
   backstop. The finalizer is the default and is correct on its own; a
   `with-*` form exists to give a managed object's lifetime a clear
   timeline, a release at a known point, because a resources object holds
   GPU and driver state (its CUDA stream, the cuBLAS, cuSOLVER and cuSPARSE
   handles RAFT creates on first use) that the tracing GC cannot see and
   would otherwise free only eventually, in no particular order. The manual
   says so where readers meet it (Concepts).
   `with-release` expands into a call of the procedure `call-with-release`
   (owner review of #11), which holds the `dynamic-wind`, the re-entry
   refusal and the release-once, so each binding expands to one call and one
   `lambda`: 25 nodes of fully expanded code per binding instead of 116. The
   acquire is an argument, so it is evaluated once, before the body's
   extent; the release expression and `#:who` are evaluated with it, once,
   after the acquire and before the body (`resource-test.rkt` pins the
   order). Every exit from the body releases (a return, a raise, an escape,
   a generator's `yield`), and control that jumps back in afterwards (a
   generator resume, a re-entered continuation) raises `exn:fail:raft`
   (kind `'logic`) instead of acquiring again. A public form passes its own name as `#:who`
   (`with-device-resources`), which prefixes that message; without it the
   message names nothing internal. No raw `malloc`/`free` outside that module
   and `raft/private/foreign/host.rkt`, which allocates the non-moving host
   staging memory (`'atomic-interior`, owned by the GC, so it has no free and
   nothing to scope): `scripts/no-raw-malloc.sh` gates it.
8. **Imports and size.** `(only-in …)` with alphabetised names, collection
   requires before relative ones (raco review enforces the order). Exempt,
   with a comment at the require: pure re-export facades (`main.rkt`, marked
   `#|review: ignore|#`), modules re-exported whole (`scribble/manual` and
   `scribble/example` in `scribblings/utils.rkt`), and `racket/runtime-path`,
   `syntax/parse/define` and `syntax/parse/pre`, whose expansions or syntax
   classes need bindings `only-in` strips. Racket modules of 500
   lines or fewer is a target; C, C++ and CUDA files of 500 lines or fewer is
   a gate.
9. **The FFI layer** lives in `raft/private/foreign/`, one module per shim
   header, defined with `define-raft` (`define-ffi-definer`,
   `convention:hyphen->underscore`, so `rr-buffer-alloc` is `rr_buffer_alloc`).
   - Handles come back through out-parameters typed `_rr-…/null`, and every
     handle-returning binding carries `#:wrap resources-allocator` or
     `#:wrap buffer-allocator` from `foreign/memory.rkt`. No binding returns a
     bare `_pointer`, and no binding takes one. Every release is wrapped by
     `release-once` (a `deallocator` that retags the handle `'rr-released`
     after the native free): releasing it again does nothing, any other use
     raises `exn:fail:raft` from the handle type's Racket-to-C conversion
     instead of reaching freed memory, and a handle of the wrong type fails
     the type's tag check before its finalizer is dropped. `raft/tests/allocator-audit-test.rkt` reads every binding and
     enforces all of this, including that each allocator releases its own
     handle type through `release-once`; a new handle type needs an entry
     there. A borrowed pointer, which Racket never frees, has a cpointer type
     of its own listed in the audit's `borrowed-types` (`_raft-handle`, the
     `raft::handle_t*` that `rr_resources_handle` lends), and a binding that
     returns one with an allocator wrap is refused.
   - A host buffer crosses with its own length: the copy bindings take
     `_host` (`foreign/host.rkt`), an `flvector` or host memory the library
     allocated and sized itself, and compute the byte count from it, so a
     copy cannot run past the host side; the shim checks the device side. A
     raw `_pointer` plus a caller-chosen size is not allowed for host memory,
     and neither is an `f64vector`, whose length `ffi/vector`'s
     `s:f64vector` struct can forge. An flvector lives in the GC heap, so
     these calls must stay non-blocking.
   - A fallible binding answers its result (or `#t`) on success and `#f` on
     failure, from the `_fun` result expression. The caller wraps it in
     `call/raft` (`raft/private/error.rkt`), which makes the call and reads
     the error message and kind in one `call-as-atomic`: the last-error slot
     belongs to the OS thread, which every Racket thread in the place shares.
     These calls are short and some take GC-heap memory, so they stay on the
     place's OS thread; a downstream's short calls go through
     `status-checker`; its long calls are jobs.
   - The native drop counters (`rr_resources_drop_count`,
     `rr_buffer_drop_count`) count every release, and
     `rr_release_failure_count` every release that leaked because its device
     was unreachable; reclamation tests assert on them, because Racket cannot
     otherwise observe a native free. A release completes on the reaper
     thread, so a test reads a counter only once `rr_releases_pending` (the
     releases queued for or running on the reaper, declared beside the
     counters in `memory.h` so a downstream's tests can settle too) is 0
     (`settled-count` and `releases-settled?` in `tests/private/collect.rkt`,
     `rr::test::releases_settled` in the gtests).
   - A changed C signature gets a new symbol name, so a stale library fails
     at load, not at the call. L0's `rr_resources_create(device, out)` and
     `rr_buffer_alloc(resources, bytes, out)` are narrower than the plan's §8
     sketches; when L1a and L1b need the plan's signatures (a stream and
     stream count, a memory kind), they get new names.
   - `scripts/check-bindings.rkt` compares the `rr_` exports (`nm -D`) with
     the bindings, both ways. A C function is bound once per calling
     convention: `rr_os_thread_id` also has an `#:in-original-place? #t`
     binding.
10. **Staging the native library.** `libraftrkt.so` reaches
    `raft/native-libs/` by temp file plus `rename(2)`, and only when the
    bytes differ (the flake's shell hook, `nix run .#copy-native-libs`, and
    the pre-install hook `raft/private/install-native.rkt`). Never `cp` in
    place: rewriting a mapped library faults live REPLs (rktorch #72). Restart
    a REPL to pick up a new shim.
11. **Nix builds see only tracked files.** `git add` new files before any nix
    command.
12. **Skips are visible.** A self-skipping test prints `SKIP: <reason>`
    (`test-gpu` and `test-twin` in `raft/tests/private/`, `RR_REQUIRE_GPU` in
    the gtests). Never assume a case ran because the run was green.
13. **Python twins** run the same RAPIDS build as the shim: the
    `pylibraft-cu13` and `rmm-cu13` 26.8.0 wheels are patched against the very
    `packages.rapids` prefix the shim links, `cupy-cuda13x` against the same
    `cudaPackages_13`. The flake asserts the twins' version equals the
    shim's. Twins are compared by machine, never by eye.
14. **Every doc example is a test** (rkt-polars #152): the behaviour each
    manual example shows is pinned in `raft/tests/docs-*test.rkt`
    (`docs-test.rkt` for leg 0's pages, `docs-core-test.rkt` for
    `raft/core`'s reference and the *Resources and the GPU* chapter,
    `docs-array-test.rkt` for `raft/array`'s and *Device arrays*,
   `docs-compat-test.rkt` for `raft/compat`'s and the *Device arrays*
   chapter's other forms of Racket data, `docs-unsafe-test.rkt` for
   `raft/unsafe`'s, which needs the canary and prints SKIP without it).
15. **Every review finding is addressed**, from reviewer agents and from bots
    (`chatgpt-codex-connector[bot]` leaves inline comments): fixed with a
    test, or explained with evidence. No silent deferrals.

## Architecture

### The shim (`shim/`)

- `extern "C"`, prefix `rr_`, every export marked `RR_API`. Status codes:
  `RR_OK` 0, `RR_ERROR` 1, `RR_BUFFER_TOO_SMALL` 2. Error kinds:
  `RR_ERROR_GENERIC` 0, `RR_ERROR_OOM` 1, `RR_ERROR_CUDA` 2,
  `RR_ERROR_LOGIC` 3. The headers are C11-clean (the `c-headers` check and
  `tests/c_api_compile_test.c`).
- Every entry point body runs inside `rr::translate_exceptions`
  (`src/detail/error.hpp`), which clears the last error, catches
  `std::exception` and `...`, classifies the failure and records the cause.
  It is the public `raftrkt::translate_exceptions` (`include/raftrkt/error.hpp`)
  over the shim's own thread-local `raftrkt::error_slot`, so a downstream shim
  that includes the header classifies and records exactly as the shim does.
  The message lives in a fixed 4 KiB thread-local buffer, so recording an
  error never allocates (the out-of-memory path included); longer messages
  are truncated at a UTF-8 character boundary, and Racket decodes the message
  leniently all the same. An out-pointer is set to NULL before any work.
- Every entry point selects the device recorded in its object
  (`rr::device_guard`, which throws when `cudaSetDevice` fails, where
  `rmm::cuda_set_device_raii` ignores the failure), so calls and finalizers
  work from any OS thread. Releases (`rr_resources_free`, `rr_buffer_free`) accept NULL, never
  throw, and leak rather than unwind if the device is unreachable.
- **The reapers** (`src/core/memory.cpp`). Dropping the last
  `shared_ptr<raft::handle_t>` can destroy a cuBLAS handle, and a free
  without memory pools is `cudaFree`; both synchronize the device. A Racket
  release runs in atomic mode (a deallocator or a finalizer), so
  `rr_resources_free` and the last unpin of a buffer or a deposit holder
  only queue the object and return. Two process-wide reaper threads take
  them: the buffer lane frees a buffer's memory and then queues its handle
  references (`owner`, `keep`) on the handle lane, which drops handles,
  resources and deposit holders (whose owner frees device memory and may
  hold the last handle reference). A buffer free never waits behind a
  handle drop that synchronizes the device. A job worker and the reapers
  release in place (`rr::on_native_worker`), except that the buffer lane
  always passes the handle references on. Each queued release is counted
  in the exit registry until it completes, and a buffer's handle references
  are admitted before its buffer release retires; after a clean verdict
  releases run on the caller, after a skip they leak and are counted.
- `rr_resources` holds its device and a `std::shared_ptr<raft::handle_t>`
  that aliases an owner holding an `rmm::cuda_stream` and the handle. Each
  resources object owns its stream; the per-thread default stream would bind
  to whichever OS thread a finalizer ran on.
- `rr_resources_ready` queries the stream without blocking
  (`cudaStreamQuery`); Racket's `resources-sync!` polls it.
- **Internal entry points.** `rr_resources_ready` and
  `rr_memory_resource_kind` are exported for raft's own Racket code and
  tests, but declared only in `src/detail/internal_api.h` and bound in
  `private/foreign/internal.rkt`. They are not part of the downstream
  interface L1d freezes; L2's stream API (`rr_stream_query`) may replace
  the first.
  `rr_resources_sync` blocks and stays for C callers and the gtests.
  `src/detail/executor_api.h` declares the executor's internal entry
  points the same way (`rr_resources_create_host`, `rr_job_submit` and the
  job accessors, the counters, `rr_exit_drain`, `rr_os_thread_id`), bound
  in `private/foreign/job-api.rkt`. `rr_exit_waiters` counts the threads
  waiting inside a drain, so the exit gtests can open a job only once
  every drain is waiting.
- **The executor** (`src/core/executor.cpp`, #32). Each `rr_resources`
  owns an `rr::executor_slot`: one worker thread, started on first use,
  that runs that object's jobs in FIFO order, one at a time; workers of
  different objects run in parallel. A worker never runs Racket. A job
  copies its argument block, pins each buffer through its native reference
  count, keeps the resources' `shared_ptr<raft::handle_t>`, and signals an
  eventfd when done. `rr_resources_free` closes the slot: queued jobs still
  run, then the worker exits.
- **Exit** (`src/core/exit.cpp`). A registry of the bounds of jobs in
  flight and a count of the reapers' releases. `rr_exit_drain` waits for
  both to empty, up to the largest bound (at least one second while a
  release is pending; once no job runs, a pending release gets that second
  from the later of the drain's start and the last job's end, so a
  place's teardown after a long fit is not cut off), and reports the jobs in flight and the jobs and
  releases still running; past it, it registers `on_exit(skip_teardown)`,
  which flushes stdout if unlocked and calls `_exit`, so no static
  destructor runs under a job. A release that arrives after a skip verdict
  leaks and is counted as a release failure (releasing it on the caller
  could block the exit); after a clean verdict it runs on the caller. A
  backstop registered with `on_exit` at the first submit or release does the same
  when no drain ran (raft instantiated only in a place). An `exit()` on a
  worker or on a reaper (a job's entry, a release) skips teardown when it
  reaches the backstop, which would otherwise wait on its own caller; the
  handlers and function-local statics registered after the backstop's
  arming (the first job or release) run before it, on that thread, while
  other jobs and the reapers keep going. Re-arming cannot close this:
  glibc gives no way to know a handler was registered since.
- **Host resources.** `rr_resources_create_host` (tests only) makes
  resources with device −1, no handle and their own executor, so CI runs
  the executor without a GPU. Every entry point that needs a handle goes
  through `rr::handle_of` and refuses them with `'logic` `the resources
  have no device`.
- **Arrays.** The public `array.h` holds what a downstream shim needs:
  `rr_view` (`RR_MAX_RANK` 8; `data` already offset; strides in elements;
  152 bytes, pinned by `_Static_assert`s and the Racket mirror's size test),
  the `RR_DTYPE_*` and `RR_MEMORY_*` codes (memory in `raft::memory_type`'s
  order), and `rr_buffer_view(buffer, offset, view)`, the one way to get a
  bound view: the caller fills `dtype`, `rank`, `shape` and `strides`; the
  shim validates them against the buffer (`rr::bind`) and fills `data`
  (base plus offset), `device` and `memory`. `data` is valid only while the
  buffer lives and only for work ordered on the buffer's stream; the header
  says so at the declaration. The entry points only raft's Racket uses are
  internal:
  `rr_dtype_table` and `rr_op_table` in `internal_api.h`, and
  `rr_array_create`, `rr_array_contiguous`, `rr_buffer_ready`,
  `rr_buffer_read` and `rr_buffer_write` in `src/detail/array_api.h`
  (bound in `private/foreign/array-api.rkt`).
- **One table per fact.** `src/detail/dtypes.def` lists the dtypes and
  `src/array/ops.def` each op's dtypes and layouts (a module adds its own
  `ops.def` beside its sources). `detail/dtype.hpp` and `detail/dispatch.hpp`
  build the tables from them; `RR_DISPATCH_DTYPE(op, code, T, body)` and
  `RR_DISPATCH_LAYOUT(op, layout, L, body)` instantiate the body only for
  what the op's entry lists and refuse anything else, naming the op
  (`unsupported dtype int32 for gemm`, `unsupported layout col-major for
  gemm`). Racket reads the tables at load
  (`private/dtype.rkt`). The dtype codes are the table's order; a test
  round-trips each.
- **Views are validated against their buffer.** Racket passes a view's
  dtype, rank, shape and strides with the buffer and a byte offset;
  `rr::bind` (`detail/view.cpp`) checks the dtype, the rank, non-negative
  extents and strides, the offset's alignment and that the span the strides
  reach fits the buffer, then fills `data`, `device` and `memory`. Names
  (`dtype`, `layout`) cross as strings and the shim refuses unknown ones,
  so an unsupported dtype or layout is refused there, not in Racket.
  Strides are NumPy's, in elements: all zero for an array with no
  elements. As in NumPy, an axis of extent 1 does not constrain the layout,
  so a vector, a matrix with one row or one column, and an empty matrix are
  in both layouts and reported row-major (pylibraft's `c_contiguous`); the
  twin pins it.
- **contiguous** is `raft::copy` (`raft/core/copy.cuh`) between a row-major
  and a col-major `device_matrix_view`: cuBLAS `geam` for float32 and
  float64 (the path `raft::linalg::transpose` takes) and RAFT's
  `mdspan_copy_kernel` for int32 and int64, which `linalg::transpose` does
  not accept (it is `enable_if`'d to floating point). The result is
  allocated on the source buffer's owner handle, so the copy, the result's
  free and the source's free share one stream. cuBLAS takes `int` extents,
  so extents beyond 2^31-1 are refused. `src/array/copy.cu` holds only the
  16 explicit instantiations (4 dtypes x 2 x 2 layouts), driven by
  `dtypes.def` with a `static_assert` against `ops.def`; validation and
  dispatch are in `array.cpp`, which clang-tidy reads. cuBLAS is linked
  explicitly (`CUDA::cublas`).
- **The default memory resource.** `rr_resources_create` calls
  `rr::install_default_memory_resource` (`src/core/memory_resource.cpp`)
  before it builds the handle, so RAFT's workspace factories see the pool.
  Once per device and process it replaces RMM's initial
  `cuda_memory_resource` with a default-constructed
  `rmm::mr::cuda_async_memory_resource`; a resource of any other type is
  left alone, as is a device without memory-pool support
  (`cudaDevAttrMemoryPoolsSupported`, checked first, since constructing the
  pool there throws); nothing is installed again after that first visit. If
  another library sets a resource between the check and the swap, the
  previous resource `set_per_device_resource` returns is put back. That is
  best effort: the put-back is itself an unlocked write, so a third library
  setting a resource in that instant would be overwritten. It is never
  unsafe, because every allocation holds its resource by value.
  `rr_memory_resource_kind` reads the registry back (`cuda`, `cuda-async`,
  `other`) for the tests.
- `src/detail/device.{hpp,cpp}`: `device_guard` and `require_device`, host
  code that needs no RAFT header.
- **The public C++ headers are the shim's own.** `core.cpp` builds the tag
  `rr_abi` returns with `raftrkt::compiled_abi()` (`abi.h`), `view.cpp`
  decides layouts with `raftrkt::canonical_strides` and `raftrkt::has_layout`
  (`view.hpp`), and every entry point records errors through `error.hpp`, so
  the gtests of the shim exercise the frozen headers on every build;
  `tests/headers_test.cpp` covers what the shim itself does not call
  (`require_abi`, the typed-pointer and mdspan checks, a downstream slot).
- `rr_buffer` holds that same `shared_ptr`, its device and an
  `rmm::device_buffer` allocated on the handle's stream from the current
  device resource. The `shared_ptr` is declared first, so the buffer is freed
  on a stream that still exists, even after its resources were released.
  Its native reference count is Racket's reference plus one per pinning
  job; `rr_buffer_free` drops Racket's, and the last drop frees the buffer
  on its device, counted by `rr_buffer_drop_count`. `rr_holder` (#22)
  counts the same way: a job that takes a deposit pins its holder, and the
  worker closes the holder (as `rr_holder_close` does) and drops the pin
  when the entry returns; `rr_holder_create` refuses resources without a
  device.
- Visibility: our code is `-fvisibility=hidden` and exports only `RR_API`
  names. RAFT and RMM declare their namespaces default-visibility on purpose
  and must stay exported: RMM's per-device memory-resource registry is a set
  of header-inline statics that the dynamic linker unifies across every
  library that uses RMM. A `local: *` version script would give the shim a
  private registry and break the one-memory-pool rule with a cuML shim (#10).
  L1a tests it with `libraftrkt_probe` (`tests/probe/probe.cpp`, installed as
  `$tests/lib/libraftrkt_probe.so`): a second library that links RMM on its
  own and is loaded `RTLD_LOCAL` by the Racket tests, as a cuML binding will
  be. It sees the async pool `libraftrkt` installed, and a buffer
  `libraftrkt` allocates shows in that pool's used bytes. L1d repeats the
  check with the cuML canary. #22 makes it a downstream too:
  `rr_probe_deposit` fills a deposit through `deposit.hpp` (or by hand, to
  test the shim's re-check) with its own error slot and owner counters, so
  `deposit-test.rkt` drives a second library through `status-checker`, and
  `deposit-job-test.rkt` through its job twins `rr_probe_deposit_job` and
  the pipe-gated `rr_probe_deposit_after_gate_job`. The
  static CUDA runtime that `rmm::rmm` links is hidden with
  `--exclude-libs,ALL`; `--no-undefined` catches a missing library at link
  (except under `RAFTRKT_SANITIZE`, where the sanitizer runtime's symbols
  resolve from the executable).
- Two gtest binaries, installed in the shim derivation's `tests` output
  (`bin/`): `raftrkt_tests` (the C API, plus white-box cases that include
  `detail/handles.hpp` and `detail/memory_resource.hpp`) and
  `raftrkt_error_tests` (white box; it compiles `error.cpp` itself and does
  not link the library, so its `rr_last_error` cannot interpose the
  library's). Cases that depend on which resources come first in a process
  run as gtest death tests (`threadsafe` style, a fresh process each).
  The probe library's entries each have a job twin, `rr_probe_<name>_job`,
  one `raftrkt::run_job` line, so CI exercises `job.hpp`.
- **Host C++ unless it launches kernels.** Every L0 source is a `.cpp`
  compiled by g++: `raft::handle_t`, RMM and the copies are host APIs, so
  nvcc is not needed until a leg instantiates a RAFT kernel. A `.cu` holds
  only that instantiation and calls back into `.cpp` for the rest, because
  clang-tidy cannot read a `.cu`: in CUDA mode (`-x cuda
  --cuda-path=<cudaPackages_13> --cuda-gpu-arch=sm_86`) LLVM 21.1.8 stops at
  `__clang_cuda_runtime_wrapper.h:388:10: error: 'texture_fetch_functions.h'
  file not found` (CUDA 13 removed it) and
  `crt/math_functions.hpp:2987:40: error: expected function body after
  function declarator`. CMake keeps the CUDA language enabled with
  `--threads=1`, `-Werror=all-warnings` and `-Xcompiler=-Wall,-Wextra,-Werror`;
  probed on the RAFT baseline, `gemm<float, row_major>`,
  `reduce<float, row_major>` and `reduce<double, col_major>`, all compile
  clean. `tests/cuda_language_test.cu` is the one `.cu` in L0: a trivial
  kernel that keeps the CUDA path (nvcc flags, `-Xcompiler` sanitizer flags,
  the CUDA link) built and run in every check until L1b brings real ones.
- C++20 module scanning is off (`CMAKE_CXX_SCAN_FOR_MODULES`): the shim uses
  no modules, and the scanner's gcc flags (`-fmodules-ts`,
  `-fmodule-mapper=…`) break clang-tidy.

### Racket (`raft/`)

- `main.rkt` re-exports `core.rkt`, which defines `device-count` and
  `raft-version` and re-exports `private/abi.rkt` (`raft-abi` with its
  predicate and accessors), `private/resources.rkt` and `exn:fail:raft`, and
  `array.rkt`, the public `raft/array`.
- `private/array.rkt`: a `buffer` (native handle, device, byte size, and
  phantom bytes of exactly that size) and the `device-array` over it
  (offset, shape, strides, dtype, memory). Only the handle has a finalizer.
  Reads and writes first poll the buffer's stream (`rr_buffer_ready` over
  `in-backoff`, as `resources-sync!` does), then copy on that stream.
- `private/pack.rkt`, shared by `raft/array` and `raft/compat`: dtype
  inference (`infer-dtype` over any sequence, `infer-rows-dtype` over
  rows), `matrix-shape` (rows that are lists or vectors; a ragged row raises
  `exn:fail:raft` naming the row), packing into host memory by the array's
  strides (bounded by its shape, so it cannot write past the memory) from
  rows (`pack-matrix`) or from row-major data (`pack-row-major`), and
  unpacking into lists or vectors. `private/print.rkt`: the printed form.
- `compat.rkt` (`raft/compat`) has no packing rules of its own: every
  conversion goes through `pack.rkt`. It re-exports `raft/array`'s six
  conversions, and `raft` does not re-export it (`core-test.rkt` pins both
  export sets and that `raft` loads no `math/array`).
- `private/foreign/host.rkt` keeps the FFI's host side in one place: the
  `_host` type (an flvector, a byte string or `host-memory`, each sized by
  itself), `host-memory`, element access by dtype, and the copies between
  `f32vector`s or `f64vector`s and host memory. Every FFI detail
  (pointer types, the `rr_view` cstruct, flvector passing) stays under
  `private/foreign/` for the planned port to `ffi2` (#15).
- `private/exn.rkt` also defines `raise-raft` (`who kind format arg ...`),
  the one place an `exn:fail:raft` is built.
- `unsafe.rkt` (`raft/unsafe`, not re-exported by `raft`) holds no FFI
  detail of its own: the views come from `private/array.rkt`'s
  `settled-view` (poll the buffer's stream, then `rr_buffer_view`) and are
  cleared by `foreign/array.rkt`'s `clear-view!`, whose
  `void/reference-sink` keeps the array reachable until the post thunk of
  `with-release` runs; the handle comes from `foreign/core.rkt`'s
  `rr-resources-handle`. `status-checker` takes thunks, so it is independent
  of the FFI a downstream binding uses; it runs the call and both error
  reads in one `call-as-atomic`. `with-deposits` takes its records and
  closes them through `private/deposit.rkt` (the `deposit` struct over an
  `_rr-holder`, `deposit->list`), which binds `src/detail/deposit_api.h`
  through `private/foreign/deposit-api.rkt`; the record is the borrowed
  `_rr-deposit`.
- `private/job.rkt`: `define-job` and `job-procedure`, which packs the
  arguments into a block laid out as the C side's `run_job` unpacks it,
  binds each `deposit` parameter's record and submits it in one
  `call-as-atomic` (closing the deposits it bound if either raises), and waits on an `unsafe-poller` over the job's eventfd with
  breaks deferred until the job returns; it also provides `jobs-in-flight`,
  `jobs-live` and `executor-threads` for the tests. `private/exit.rkt`:
  `current-exit-wait` and the main place's at-exit hook, which calls
  `rr_exit_drain` and logs on the `'raft` topic. The hook is registered
  when the place's OS thread is the original one, read under
  `call-as-atomic`: a parallel thread runs non-atomic code on its own OS
  thread but atomic code on its place's, so loading raft from a parallel
  thread of the main place still registers it, and a place's never does.
  `private/foreign/job-api.rkt` binds `executor_api.h`.
- `private/resources.rkt`: the `device-resources` struct (with
  `#:omit-define-syntaxes`, so the constructor procedure can carry the
  type's name; the raw constructor is `handle->device-resources`),
  `resources-sync!` over the `in-backoff` sequence, the thread-cell
  defaults and `with-device-resources` (over `with-release`). It also
  provides internal names: `resources-handle`, which every binding that
  takes resources goes through (`(resources-handle who r)` answers the
  native handle or raises `exn:fail:raft` naming `who` if the resources
  were released; `resources-sync!` calls it on every poll), and
  `memory-resource-kind`, the tests' view of the default memory resource.
- `private/foreign/library.rkt`: the runtime path to `native-libs/`, `ffi-lib`
  (default local binding: only one copy of each RAPIDS library can load per
  process), `define-raft`, and the cpointer types `_rr-resources`,
  `_rr-buffer`. `core.rkt`, `memory.rkt`, `array.rkt` bind `core.h`,
  `memory.h`, `array.h`.
- `private/exn.rkt`: `exn:fail:raft`, with no dependencies, so the loader can
  raise it. `private/error.rkt`: `call/raft`, re-exporting the exception. A
  released handle's cpointer type refuses it with `exn:fail:raft` (kind
  `'logic`) before the call, named by the public noun:
  `device-resources: used after its release` and
  `device-array: used after its release` (#16).
  `private/resource.rkt`: `with-release`. `private/install-native.rkt`: the
  pre-install hook, honouring `RAFT_NATIVE_LIB_PATH` (a directory whose
  `lib/` holds `libraftrkt.so`).
- Tests: `tests/private/gpu.rkt` (`gpu-available?`, `test-gpu`),
  `tests/private/probe.rkt` (the probe library, from `RAFT_SHIM_PROBE`,
  its jobs bound with `define-job`, `gate-job`, `test-host-probe`, which
  skips only without the probe, `test-probe`, and `test-pools`, which also
  skips a device without memory pools), `tests/private/collect.rkt` (`collect-until`,
  `drain-finalizers!`, run before reading a drop counter),
  `tests/private/raft-error.rkt` (`check-raft-error kind message thunk`),
  `tests/private/ticker.rkt` (`call-with-ticker`, which answers how many
  10 ms waits another thread finished during the thunk, then its values),
  `tests/private/gate.rkt` (`closed-gate`, two pipes released by
  `with-release`: a probe job writes an entry byte and polls the gate's fd
  until the test's `open-gate!`, and `await-entry` reads the entry byte
  through a port, so a test checks mid-job state without a clock or a held
  place),
  `tests/private/exit-run.rkt` (`run-exit-program`, which writes a fixture's
  module to a temporary `program.rkt`, runs it with `PLTSTDERR=debug@raft`,
  and answers its code, stdout and stderr lines; `in-flight-line` and
  `still-running-line` match the exit hook's lines),
  `tests/private/python-env.rkt` (the twin runner: `PYTHONSAFEPATH` probes,
  a temp directory, JSON in and out, `check-close`, `test-twin`),
  `tests/private/bindings.rkt` (the binding reader shared by the audit and
  the census), `tests/private/deposits.rkt` (the probe's fill helpers,
  owner and drop counters and `released-once`, shared by `deposit-test.rkt`
  and `deposit-job-test.rkt`).

## Build and test

```bash
nix develop                        # the GPU shell (first entry builds and provisions)
nix flake check --max-jobs 1 --cores 4   # the CI-equivalent; GPU cases print SKIP
scripts/gpu-suite.sh               # in the shell, on the GPU host: gtests, LD_BIND_NOW
                                   #   load, raco tests with twin parity, the census;
                                   #   red on any SKIP but the no-driver cases
raco test raft                     # the Racket tests
racket scripts/check-bindings.rkt  # rr_ exports against the bindings
scripts/render-docs.sh <dir>       # the manual, red on any warning or broken link
nix fmt                            # format and lint everything; `-- --ci` fails on a change
scripts/review.sh                  # raco review over every .rkt
scripts/resyntax.sh                # Resyntax against the PR's base, red on any suggestion
nix run --max-jobs 1 --cores 4 .#copy-native-libs   # restage the shim after a C++ change
cmake -S shim -B shim/build -G Ninja -DBUILD_TESTING=ON   # the shim's inner loop
nix build --max-jobs 1 --cores 4 .#kmeans-canary  # the canary (lib/, and tests/bin in .tests)
raco test downstream/kmeans-canary/kmeans-canary  # the canary's Racket tests, twin included
```

`nix develop` does this on entry, from the checkout's root only:

- **Filters `LD_LIBRARY_PATH`.** The lab host's `~/.bashrc` puts CUDA 11.7
  (`/usr/local/cuda-11.7/lib64`) on it, which would shadow the CUDA 13
  libraries; every `/usr/local/cuda*` entry is removed. Verify with the GPU
  suite's `LD_BIND_NOW=1` load of the shim.
- **Links the driver.** The host is Ubuntu with no `/run/opengl-driver`, so
  `libcuda.so.1`, `libnvidia-ml.so.1` and `libnvidia-ptxjitcompiler.so.1` are
  found with `ldconfig -p` and symlinked into `.cuda-driver/`, which goes
  first on `LD_LIBRARY_PATH` (rktorch's `cudaHook`). Twin subprocesses get
  only that directory (`RAFT_CUDA_DRIVER_PATH`).
- **Stages the shim** and exports `RAFT_NATIVE_LIB_PATH`, `RAFT_SHIM_TESTS`
  (the gtest binaries) and `RAFT_SHIM_PROBE` (the probe library).
- **Points at the canary:** `RAFT_KMEANS_CANARY` (its `libkmeans_canary.so`
  in the store, loaded from there: it is never staged), `RAFT_KMEANS_CANARY_TESTS`
  (its gtests) and `RAFT_RAPIDS_PREFIX` (`packages.rapids`, for the
  `libcuml.so` symbol check).
- **Gives each checkout its own `PLTUSERHOME`** under
  `~/.cache/rkt-raft-devshell/<hash of the path>`, installs `raft` and
  `kmeans-canary` there in link mode once (re-run when either `info.rkt`
  changes) and installs the pinned
  Resyntax, raco fmt, raco review and `raft-lint` (from `lint/`, linked).
- Provides `python3` with the twins, `CUDA_PATH` set for CuPy, `nvcc`,
  CMake, the CUDA headers and `compute-sanitizer` for the shim's inner loop,
  and the `treefmt` that `nix fmt` runs.

The GPU is shared with other sessions: keep test sizes small and leave no
process running.

### Build memory

The lab host has 62 GB of RAM shared with other sessions, and a global OOM on
2026-10-01 took down the owner's session; nvcc jobs were part of it. So:

- Run nix as `nix … --max-jobs 1 --cores 4`, and never two builds of the shim
  at once.
- The shim builds at most `buildJobs` = 4 compile jobs at a time (the flake
  caps ninja and `CMAKE_BUILD_PARALLEL_LEVEL`; the dev shell exports
  `CMAKE_BUILD_PARALLEL_LEVEL=4`), and nvcc runs with `--threads 1`.
- Measured with GNU `time -f %M` (one translation unit, sm_86, the shim's
  flags), a RAFT translation unit (`gemm.cuh` or `reduce.cuh`, one
  instantiation) peaks at 730–760 MB. The cap keeps a build near 3 GB; keep
  `buildJobs` × peak RSS under about 24 GB, and measure again when a heavier
  header family (`linalg/svd`, `sparse`, `cluster`) arrives.
- Check `free -g` before a heavy build; with less than 30 GB available, wait
  and retry rather than start.

### Gates

**Every adversarial-review finding gets a regression test** (owner rule,
#27 round 4; it holds for every leg, the downstream cuML algorithms
included). Each finding, of every severity, gets a minimal test that fails
without its fix, shown failing on the tree with the fix reverted and
passing with it. A deadlock or hang test is bounded, so a regression fails
instead of hanging: a gtest child's `alarm()`, `sync/timeout`, or a
subprocess with a timeout. A GPU-only repro runs in the `gpu` gate, with a
host-resources variant for CI wherever one can be built. A test is named
for the property it checks; the finding's id goes in the commit message,
not in a comment.

`.racket-dev.rktd` declares them for the racket-dev plugin's runner
(`racket <plugin>/hooks/gate.rkt . all`); the pre-push hook runs `format`,
`no-syntax-rule`, `no-raw-malloc`, `bounded-death-tests`, `review`,
`compile`, `test` and `bindings`. Before every push: `nix flake check` green, the GPU suite green
with its counts, the docs rendered with no warnings, and Resyntax clean with
both rule sets (see Tooling). After pushing, poll `gh pr checks <n>` (it exits
non-zero while checks are pending) until green.

Every test run is bounded, so a hang fails instead of stalling a gate or
a runner. ctest fails a shim gtest past 6 s and a canary gtest past 2 s
(`gtest_discover_tests ... PROPERTIES TIMEOUT`, about three times the
slowest test; the nix checks run the gtests through ctest). `raco test
--timeout 45` bounds each Racket file, and `test-timeouts` in `raft/info.rkt`
and the canary's `info.rkt` give the slow exit, memory and twin files their
own, with room for a loaded GPU host.
Every `EXPECT_EXIT`/`EXPECT_DEATH` body is a named function whose first
statement is `alarm(...)`, or `std::_Exit` itself;
`scripts/bounded-death-tests.sh` fails on any other.
`scripts/gpu-suite.sh` runs under a 1800 s `timeout`, and every CI job has a
`timeout-minutes`. A test that legitimately grows past its bound raises the
bound in the same commit.

The `resyntax` gate runs `scripts/resyntax.sh` with no argument, which
analyzes only what the branch changes: after a `git fetch`, its base is
`git merge-base HEAD origin/<base>`, `<base>` being the PR's base branch from
`gh pr view`, or `master` when there is no PR or `gh` fails. On a stacked
branch, `origin/master` would re-analyze every leg below it. A green run
records a key in `/var/tmp/rkt-raft-resyntax-cache/`: the sha-256 of the
base, `git diff <base> -- '*.rkt' '*.scrbl'` (the working tree included),
the installed Resyntax checksum and the script itself. A run whose key is
recorded prints `resyntax: unchanged since a green run` and exits 0;
`RESYNTAX_NO_CACHE=1` forces the analysis. An explicit base, as CI passes,
always runs in full and records nothing.

`nix flake check` runs fourteen checks: `shim` (build plus both gtest
binaries), `shim-sanitizers` (both gtest binaries under ASAN and UBSAN),
`c-headers` (the umbrella header compiled as C11 with `-Werror`),
`clang-tidy`, `kmeans-canary` (the canary's build against `packages.raft-dev`
and `packages.rapids`, plus its gtests), `clang-tidy-canary`, `line-count`
(500 lines per C/C++/CUDA file under `shim/` and `downstream/`), `formatting`
(treefmt), `racket` (the package build, `raco setup --check-pkg-deps
--unused-pkg-deps`, `raco test raft`, the manual compiled but not rendered,
the binding census), `racket-review`, `racket-version` (at least 9.3),
`no-syntax-rule`, `no-raw-malloc` and `bounded-death-tests`.

## Tooling

| Tool | What it checks | Where it runs | How to fix |
|---|---|---|---|
| treefmt (`nix fmt`, `nix/treefmt.nix`) | runs every formatter and linter in the next seven rows; fails on any change or finding | flake check `formatting`; CI "Format and lint"; pre-push `format` | `nix fmt`, then fix what the linters report |
| raco fmt, width 102 (`.fmt.rkt`) | layout of every `.rkt` | treefmt | `nix fmt` |
| clang-format (`.clang-format`) | C, C++ and CUDA layout | treefmt | `nix fmt` |
| nixfmt | `*.nix` | treefmt | `nix fmt` |
| shfmt, indent 2 | shell scripts | treefmt | `nix fmt` |
| ruff format, ruff check | the Python twins | treefmt | `nix fmt`; `ruff check` findings by hand |
| shellcheck | shell scripts | treefmt | by hand |
| actionlint (`.github/actionlint.yaml`) | workflows, including the shell in their `run:` steps | treefmt | by hand; move a long `run:` script into `scripts/` |
| raco review, with `lint/` | Racket lint: unused and shadowed bindings, require order, unbound names, in `raft/`, `downstream/`, `lint/`, `scripts/` and `bench/` | flake check `racket-review`; CI "Format and lint"; pre-push `review` (`scripts/review.sh`) | by hand; `;; noqa` only as below |
| Resyntax, default rules (pinned `40f3497`) | refactoring suggestions in `.rkt` files changed since the base | CI "Resyntax lint"; gate `resyntax` (`scripts/resyntax.sh`) | `resyntax fix --local-git-repository . origin/master`, then `nix fmt` |
| Resyntax, bkc-style rules | the owner's style suite from the racket-dev plugin | locally, before a push | as above |
| `raco setup --check-pkg-deps --unused-pkg-deps` | `raft/info.rkt`'s dependencies, missing and unused | flake check `racket` | edit `deps` and `build-deps` |
| grep gates | `define-syntax-rule`/`syntax-rules`; raw `malloc`/`free` outside `resource.rkt` (`raft/`, `downstream/`, `lint/`, `scripts/`) | flake checks; CI "Format and lint"; pre-push | rules 6 and 7 |
| compiler warnings | g++: `-Wall -Wextra -Wpedantic -Werror`; nvcc: `-Werror=all-warnings -Xcompiler=-Wall,-Wextra,-Werror` | every shim build | by hand |
| clang-tidy (`shim/.clang-tidy`, `downstream/kmeans-canary/.clang-tidy`) | every `.cpp` under `shim/src`, `shim/tests` and the canary's `src` and `tests`, warnings as errors: `bugprone-*`, `performance-*`, `readability-*` except `identifier-length` (below), `modernize-use-nullptr`, `modernize-use-override` | flake checks `clang-tidy`, `clang-tidy-canary` | by hand |
| `c-headers`, `line-count` | the umbrella header as C11; 500 lines per C/C++/CUDA file | flake checks | by hand |
| ASAN and UBSAN (`-DRAFTRKT_SANITIZE=ON`) | host memory errors, leaks and undefined behaviour in both gtest binaries | flake check `shim-sanitizers` (GPU cases SKIP); the GPU suite (GPU cases run); gate `sanitizers` | by hand |
| compute-sanitizer memcheck | device memory errors, device leaks (`--leak-check full`) and failing CUDA calls (`--report-api-errors explicit`) in both gtest binaries and the canary's | the GPU suite (gate `gpu`, `gpu.yml`) | by hand |

- **raco fmt** formats `.rkt` files only. It crashes on Scribble's
  at-expressions (`regexp-match: contract violation … given: 'text` in
  `fmt/core.rkt`), so `.scrbl` is excluded; `.rktd` keeps its hand layout
  (the audit fixtures, the gate config). `.fmt.rkt` adds what raco fmt gets
  wrong here: `_fun` keeps each `-> …` on its own line under the arguments
  (raco fmt alone puts every `->` on a line by itself); `hash`, `hasheq` and
  `hasheqv` keep a key and its value together; `define-cstruct` puts one
  field per line under the name; `define-raft` is laid out like `define`,
  `generator` and `define-pretty` like `lambda`; `with-release`,
  `with-device-resources` and the test macros keep the name (and
  `test-unless-skipped`'s reason) on the first line and a body that holds a
  list below, as `let` does, while a body of atoms (a macro's `body ...`)
  stays on one line. The `_fun`, hash and body formatters use fmt's internal
  document model, which fmt calls unstable, so `nix/racket-tools.nix` pins
  fmt, review and pretty-expressive by commit (the catalog's own source for
  each) and a bump is a deliberate change: check `.fmt.rkt` with the new fmt. Any form whose head is a
  configured name gets that layout, even inside a quote, so keep such lists
  out of quoted data (as `lint/review.rkt` does with a `seteq`). Run `nix
  fmt` after `resyntax fix`: Resyntax's rewrites are not laid out by these
  rules, and once formatted the tree is a fixed point of both tools.
- **raco review** reads every `.rkt` (`scripts/review.sh`). The `raft-lint`
  extension (`lint/review.rkt`) gives `test-gpu`, `test-pools`, `test-probe`,
  `test-twin`, `test-without-gpu` and `test-unless-skipped` a scope of their
  own, as
  rackunit's `test-case` has, so a name defined in one test body does not
  clash with another's. It also treats `define-syntax-parse-rule` as review
  treats `define-syntax-rule`, recording the name and skipping the template;
  without it review reads the header as a function's and reports every
  `x:expr` as an unused argument. It skips quoted data and reads quasiquoted
  data (lists, vectors, boxes, hash values, prefab fields) only at its
  unquotes. `;; noqa` is allowed only where review cannot see a
  binding's definition or use: names that `define-cpointer-type` and
  `define-cstruct` generate, a struct re-exported with `struct-out`, a value
  used only inside a macro template, and a name that `struct` leaves free
  with `#:omit-define-syntaxes` and the module then defines (review reads
  that as a second definition: `device-resources`). `#|review: ignore|#` is for
  `info.rkt` files and re-export facades. Test data that is quoted code lives
  in a `.rktd` fixture, which review does not read.
- **Resyntax** exits 0 with findings; `scripts/resyntax.sh` greps for
  `resyntax: .*\.rkt:N:N [` and fails. The pin `40f3497` was upstream HEAD on
  2026-10-01. CI runs the default rules only. The bkc-style rules live in the
  racket-dev plugin, which has no remote yet; publishing it is the owner's
  decision, so the rules are not vendored here. Run them locally with the
  plugin's `resyntax/bkc-style` package linked into the dev shell's
  `PLTUSERHOME`:
  `resyntax analyze --local-git-repository . origin/master --refactoring-suite bkc-style bkc-style`.
- **clang-tidy** runs every `bugprone-*`, `performance-*` and
  `readability-*` check at its default settings (cognitive complexity 25,
  which no function comes near) except `readability-identifier-length`. That
  check rejects the one-letter names of a catch parameter (`e`), a loop
  index (`i`) and a handle bound for two lines (`r`, `b`, `n`): 24 findings
  in L0, none of them an unclear name. Re-enabling it means renaming those,
  not suppressing them.
- **Sanitizers.** ASAN needs `protect_shadow_gap=0` beside the CUDA runtime;
  the builds also set `detect_leaks=1:abort_on_error=1`,
  `UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1` (the flake's
  `sanitizerOptions`, exported to the GPU suite as `RAFT_ASAN_OPTIONS` and
  `RAFT_UBSAN_OPTIONS`) and turn `_FORTIFY_SOURCE` off. The flags reach C
  and C++ directly and CUDA through `-Xcompiler=`. `shim-sanitizers`
  installs its gtests (`RAFT_SHIM_SANITIZED_TESTS`), so the GPU suite runs
  the alloc, copy, free and destructor-order paths sanitized on the device.
- **compute-sanitizer** checks device memory, device leaks and failing CUDA
  calls. Until L1b the only kernel to check is the fixture in
  `tests/cuda_language_test.cu`, but the step still catches a bad copy, a
  leaked allocation or a failing call. `--report-api-errors explicit` (the
  default) reports every failing call the shim makes; `all` is unusable,
  because the CUDA runtime's own lazy context creation probes
  `cuCtxGetDevice` and fails by design. The two gtests that provoke failing
  calls on purpose (`Buffers.AnImpossibleAllocationIsOutOfMemory`,
  `Release.AnUnreachableDeviceLeaksAndIsCounted`) run in a second pass with
  API-error reporting off and leak checking on. It skips the gtest death
  tests, which run unsanitized just before: under compute-sanitizer their
  re-executed child blocks on a futex (13.2.76, ten minutes at 0% CPU)
  instead of running.

## CI

- `.github/workflows/nix.yml`, three jobs on `ubuntu-latest`: "Format and
  lint" (the `formatting`, `racket-review`, grep, `line-count` and
  `racket-version` checks, which need no CUDA, so it reports in minutes);
  `nix flake check` (after freeing disk: the CUDA 13 redistributables are
  unfree, so no public cache serves them); and "Resyntax lint"
  (`scripts/resyntax.sh` in the lean `.#ci` shell, default rules; the shell
  also installs raco fmt, because Resyntax expands `.fmt.rkt`). The
  `nix-cache` action is rktorch's; this repository has no Tailscale secrets,
  so it falls back to `cache.nixos.org`. Actions: `actions/checkout@v7`,
  `DeterminateSystems/nix-installer-action@v23`,
  `DeterminateSystems/magic-nix-cache-action@v15`,
  `tailscale/github-action@v4`.
- `.github/workflows/gpu.yml`: the GPU suite and the docs render on
  `runs-on: [self-hosted, linux, gpu]`, only when `vars.GPU_RUNNER == 'true'`
  and the pull request's author is `bkc39` (or a manual dispatch). No runner
  is registered yet (#9); until then the GPU gates run by hand on the lab
  host and their counts go in the review packet. The `if:` is not a security
  boundary: a fork's PR runs workflow files it controls, so keeping forks off
  the runner is the runner group's job (#9 lists the settings).
- No docs build in GitHub CI: doc examples need the GPU.

## Documentation

- One manual, `raft/scribblings/raft.scrbl`: a guide (chapters under
  `guide/`) and a reference (one section per module under `reference/`).
  `utils.rkt` holds `make-raft-eval`, `make-downstream-eval`, `listing` and
  `excerpt` (a listing read from a repository file).
- **The manual assumes a catalog install** (`raco pkg install raft`; what
  that still needs is #24) and mentions no Nix at all: no dev shell, flake,
  `nix build`, `packages.*`, test-running or rendering instructions. Those
  are maintainer material and live in `README.md` (Development) and here.
- **The manual shows Racket code only.** No Python blocks, no comparisons
  with pylibraft, CuPy, NumPy or cuML, and no mention of the twins. Python
  parity lives in the tests and CI, never in the docs (owner decision,
  reversing the earlier Python-beside-Racket convention). A fact about Racket semantics
  (strides in elements, per-thread default resources, dtype inference,
  layouts) is stated on its own terms.
- **Front matter is terse**, as in glmnet: three one-sentence paragraphs led
  by bold text (License, Acknowledgements, AI Disclosure) on the landing page
  (`raft.scrbl`), before the table of contents, the same on every leg; not
  sections. The per-component licences live in `README.md` (Licences).
- **The manual describes the current library as final**: no leg names,
  `@status` markers or future-work references (no "arrives later", no
  forward issue links). Each leg's manual describes that leg's library as
  complete and never mentions what an upper leg adds.
- **The Device arrays chapter loads iris** from `datasets` through `polars`,
  both build dependencies (the docs tests require them, so
  `--unused-pkg-deps` sees them used). The sandboxed builds cannot reach the
  catalog, so the flake installs both offline from glmnet's pins
  (`installDocsDeps`: the `rkt-polars`, `datasets-src`, `data-frame-src` and
  `al2-test-runner-src` inputs), and the dev shell does the same. They are
  installed without docs, so the manual does not link their names.
- **Concepts' lifetime figure is a pict** (`guide/lifetime-diagram.rkt`,
  `pict-lib` a build dependency), rendered to an image by Scribble.
  `render-docs.sh` ignores the lab host's `Fontconfig warning:` cache-version
  line that drawing it prints.
- **The owner reviews each leg's docs.** Every leg adds its own guide chapter
  and reference section. A guide chapter is a tutorial on realistic client
  code, evaluated live.
- Every exported name gets a `@defproc`/`@defform`/`@defthing` with prose and
  at least three live examples showing real use, not trivial calls.
- Examples run through `scribble/example`; output is never pasted by hand.
  Each one's behaviour is pinned in `raft/tests/docs-*test.rkt`.
- Render after the leg's final commit with
  `scripts/render-docs.sh ~/dev/rkt/rkt-raft-docs/<leg-slug>`
  (`l0`, `l1a`, `l1b`, `l1c`, `l1d`); it fails on `undefined tag`,
  `badlink`, `multiple times` or any warning.

## Process

- **Arcs and legs.** Epic #1 (M1) lists the legs #2 L0, #3 L1a, #4 L1b, #5
  L1c, #6 L1d. Follow-ups: #7 (RAPIDS 26.10), #8 (shared array protocol with
  rktorch), #9 (the self-hosted GPU runner), #10 (test the one-pool rule
  across shims).
- **The stack.** M1 is one GitHub native stack: `master` ← L0 ← L1a ← L1b ←
  L1c ← L1d. Branch with `git fetch origin && git checkout -B <branch>
  origin/<base>`. Never force-push and never rebase a pushed branch; pick up
  the leg below with `git merge origin/<base>`. Never push to `master`, merge
  a PR or close an issue; the orchestrator links the stack with
  `gh stack link`.
- **gh is a snap and cannot read hidden directories:** pass bodies on stdin,
  `gh pr create … --body-file - < /path/body.md`.
- Commits end with a blank line and the `Co-Authored-By:` trailer. PR titles
  are `<area>: <what lands> (#<leg issue>)`; bodies are short.
- **The review packet is the PR's first comment** (racket-dev
  `review-packet`), then a comment on the epic: the PR number, the decisions
  taken, what was deferred and to which issue. A follow-up is a new issue,
  never a TODO comment.
- **Spec step.** A leg adding public surface commits its spec first:
  signatures, Scribble entries and failing tests (no contracts in M1).

## Decisions recorded in leg 0

- **One nixpkgs pin** (`07e1d92`) for everything: it carries Racket 9.3 and
  CUDA 13.2, so the shim, the Racket binary and the twins share one glibc.
  rktorch needs two pins only because its main pin predates Racket 9.3.
- **nvcc 13.2 against wheels built with 13.3.** Verified: nvcc 13.2 compiles
  the wheels' RAFT, RMM and CCCL 3.4.3 headers (the wheel's CCCL comes first
  on the include path), and the 13.3-built `libraft.so`/`librmm.so` run with
  13.2's cuBLAS, cuSOLVER, cuSPARSE, cuRAND and nvJitLink on driver 580 (CUDA
  13.0), since `libraft.so` references no versioned nvJitLink symbol. The
  pin also carries `cudaPackages_13_3` if that ever changes.
- **SASS and PTX for sm_86** (`CMAKE_CUDA_ARCHITECTURES=86`): the driver runs
  the SASS; the driver cannot JIT 13.2 PTX, so the PTX is inert.
- **RAPIDS Python wheels skip their loader packages.** `pylibraft` and `rmm`
  import `libraft`/`librmm` only if installed; the twins omit them and patch
  the extensions against `packages.rapids` instead, so both sides load the
  same `libraft.so` and `librmm.so`.
- **The ABI tag is a struct** in Racket (`raft-abi`) and `rr_abi_tag` in C:
  tag version, RAFT, RMM and CCCL versions, CUDA runtime,
  `sizeof(raft::handle_t)` and the resource-type count. The Racket struct is
  transparent (`equal?`, `struct-copy raft-abi`) with a `prop:custom-write`
  printer; its fields are `version`, `raft`, `rmm`, `cccl`, `cuda-runtime`,
  `resource-types` and `handle-size`, read by `raft-abi-version` (not
  `raft-abi-abi-version`), `raft-abi-raft` and so on, with `raft-abi?`. The
  name `raft-abi` is one compile-time binding (`private/abi.rkt`) that is the
  query in an expression, a keyword match pattern (`(raft-abi #:raft r)`;
  every keyword optional, unnamed fields ignored, an unknown keyword a syntax
  error listing the fields) and the struct's static info for `struct-copy`;
  the `struct` form itself binds its info to `raft-abi-struct` and its
  constructor to `make-raft-abi`, neither exported (owner-approved design,
  replacing the hash).
- **Errors carry a kind** (a field of `exn:fail:raft`, not a subtype).

## Decisions recorded in L1a

- **The default memory resource is installed by the shim,** on the first
  `rr_resources_create` for a device, not by Racket: every C caller,
  including a downstream shim that creates resources through the C API, gets
  the same behaviour. "Already replaced" means the registry holds anything
  but a `cuda_memory_resource` (`cuda::mr::resource_cast`); a plain
  `cuda_memory_resource` set on purpose before that point cannot be told
  from RMM's initial one and is replaced too (the manual says so).
- **The pool takes RMM's defaults**, as `rmm.mr.CudaAsyncMemoryResource()`
  does: no initial size, and a release threshold of `UINT64_MAX`, so freed
  memory stays in the pool. Sizes and trimming are leg 2 and leg 5.
- **`resources-sync!` polls.** It queries the stream, yields for 16 polls,
  then sleeps from 10 µs, doubling to 1 ms (`in-backoff`). Each poll looks
  the handle up again, so resources released by another thread mid-wait end
  the wait with `exn:fail:raft`. A `cudaErrorNotReady` from the query is
  cleared from the runtime's last error, as PyTorch does.
- **Per-thread defaults** live in a thread cell (not preserved) holding an
  immutable `hasheqv` from device to resources. A released default is
  replaced on the next request.
- **Use after release raises `exn:fail:raft`** of kind `'logic`, with the
  message `<who>: the device resources on device N were released`, from
  `resources-handle`; the cpointer retag stays as the memory-safety net
  underneath. `resources-device` still answers after release.
- **`with-device-resources` binds like `let*`:** each expression sees the
  names bound before it, never its own, and duplicate names are a syntax
  error. It passes `#:who 'with-device-resources` to `with-release`, so a
  refused re-entry (rule 7) names the public form.
- **`device-count` never answers 0,** as CuPy's `getDeviceCount` does not:
  with no device, CUDA reports `cudaErrorNoDevice`, which raises.
- **`abi-version` stays 1.** L1a only adds entry points; the tag's version
  changes when a change would break a library built against the previous
  one, and L1d freezes the downstream interface.

## Decisions recorded in L1b

- **`numel`** is the element count, as rktorch names it, so the shared array
  protocol (#8) has one name; NumPy's `size` is mentioned in the manual.
- **Defaults.** `device-matrix` and `device-vector` make `float32`,
  row-major, as `device_ndarray.empty` does. `contiguous`'s `#:layout`
  defaults to `'row-major`, as `np.ascontiguousarray`; `'col-major` is
  `np.asfortranarray`. Conversions infer as NumPy (an empty list gives
  float64) and integer dtypes truncate toward zero, as NumPy's casts do.
- **No Racket argument checks** (rule 3): an unknown dtype or layout name
  or a negative extent is refused by the shim. What the conversions refuse
  is data they cannot convert, not argument kinds: a ragged row (the leg
  brief requires the row to be named; the packer is bounded by the shape,
  so a ragged row could not overrun memory, but it would silently drop or
  leave uninitialised elements), a value the element type cannot hold (a
  complex number, an infinity or NaN for an integer type, an integer out of
  range), and data with no inferable dtype. Each raises `exn:fail:raft`
  naming the public procedure. Wrong-kind arguments (a matrix where a
  vector goes, a string for a list) may surface Racket's own errors until
  the contracts leg.
- **Reads and writes poll** the buffer's stream before copying, so the GC
  and other threads are not held up by queued GPU work, as in L1a. The copy
  itself is a second, non-blocking call that ends in
  `cudaStreamSynchronize`: work another Racket thread queues on the same
  stream between the poll and the copy is waited for inside it, holding up
  the place. Safe, and rare; L3's stream rule revisits it.
- **Printing** follows NumPy's summarising (threshold 1000 elements, three
  edge items) and prints float32 as its shortest round-tripping decimal;
  it reads only the elements it shows.
- **`rr_view` has no reserved or flags word.** Versions move in lockstep:
  a downstream shim compiles against identical headers and compares
  `rr_abi` at load, so forward compatibility is not a goal, and any change
  to the struct bumps the ABI tag and the canary. A reserved field older
  readers ignore would invite exactly the silent misreading the ABI check
  exists to prevent. DLPack mapping (#8) is a separate struct, not a field.
- **Bound views come from `rr_buffer_view`**, public in `array.h`, rather
  than a frozen (buffer, offset, descriptor) triple: a downstream shim
  receives ready `rr_view`s, and the binding is validated in one place.
  Racket's `bound-view` (`private/array.rkt`) calls it; L1d's
  `with-array-views` will. A refused call leaves `data` NULL and `device`
  and `memory` -1, so a reused view never pairs an old pointer with an
  unvalidated shape.
- **The stream rule for L1d.** A downstream shim cannot learn a buffer's
  stream from an `rr_view`; only raft's own handle knows it. So L1d must
  run a downstream op on the resources the arrays were allocated with (or
  synchronise those arrays' streams before handing them to work on another
  stream), and `with-array-views` must keep every array reachable for the
  whole native call, since its finalizer frees the memory on its own
  stream. An internal stream accessor is not added in L1b: nothing reads
  it yet, and L3's cross-stream rule (recorded events) is where one
  belongs.
- **`contiguous?`** is the public layout predicate (NumPy's
  `flags.c_contiguous`/`f_contiguous`); `layout` answers one symbol and
  says `'row-major` for an array in both layouts.
- **Printing never raises.** A released array prints `<released>`; a read
  that fails prints `<values unavailable: ...>`, so an error message that
  shows an array (`raise-argument-error`, rackunit) keeps its own error.
- **A finite value that overflows a float type is refused** (`1e300` into
  float32, `10^400` into float64), as integer overflow is, where NumPy
  stores an infinity (float32 narrowing) or raises (`OverflowError` for
  `10**400`). Infinities and NaN pass into float types.
- **The released-buffer noun is `device-array`** (#16): the public
  predicate is `device-array?`. No public procedure releases a buffer in
  L1b, so only internal code can reach it.
- **L0's copies** (`rr_copy_h2d`, `rr_copy_d2h`) stay in the public header
  for C callers and tests; Racket binds them with `_host`.

## Decisions recorded in L1c

- **`raft/compat` is the only module that requires `math-lib`** (a runtime
  dependency of the package; `math-doc` is a build dependency for the
  manual's links). `raft` does not re-export it.
- **The rank comes from the nesting** in `list*->device-array` and
  `vector*->device-array`, by following first elements, as NumPy reads it
  from the first entry: a sequence of rows (lists or vectors, as NumPy takes
  lists and tuples) is a matrix, anything else a vector,
  and `'()` an empty vector (`np.asarray([])`). A mixed depth is refused
  naming the element or row; ranks other than 1 and 2, from a nesting or a
  `math/array` array, raise `rank N is not supported yet; rank 1 and 2
  convert, and any rank arrives in leg 3`.
- **Reading `math/array` arrays.** Every array that reaches untyped code
  carries Typed Racket's contract, which checks each element as it is read:
  `array->flarray`, `array->list` and `array->vector` all cost 0.6 to 1.2
  µs an element from untyped code (measured: `array->flarray` on a 10^6-element
  FlArray took 1.1 s). So the conversion takes a mutable array's vector
  (`mutable-array-data`, O(1)) and a flonum array's flvector
  (`flarray-data`, O(1)), and reads any other array once with
  `array->vector`. There is no public `flarray?` and Typed Racket cannot
  make one (`FlArray`'s contract is a chaperone, not flat), so a settable
  array that is not mutable is tried with `flarray-data`, and its contract
  failure means "not a flonum array" (only an `FCArray`, whose complex
  elements are then refused). The blame message would print the whole
  array, 10.9 s for a 1000×1000 `FCArray`, so the call runs with
  `error-value->string-handler` returning `"?"` (about 9 ms); a test bounds
  the refusal's time. The brief's `array->flarray` route was
  measured and not taken. Results of `math/matrix` operations and
  `build-array` are neither, so they take the element-by-element path.
- **One loop per representation.** `pack.rkt`'s `over-elements` wraps an
  ordinary `for` form (so raco review and raco fmt read it as one) and
  expands it once each for lists, vectors, flvectors and any other sequence
  in its first clause, so
  the list paths keep `in-list`'s speed while taking vectors too;
  `list*->device-matrix` now infers through `infer-rows-dtype`, the same
  rule as every nested conversion. `repack` converts host memory between
  element types directly (an `f32vector` sent as `'float64`), through the
  same converter, so a finite value that overflows `'float32` is refused on
  every path (L1b's rule).
- **Arrays come back** as flonum arrays from floating-point device arrays,
  built with `unsafe-flarray` (exported by `math/array`, undocumented) over
  the flvector read from the device. `unsafe-flarray` does not check that the
  flvector's length is the product of the shape; `math-array` in
  `compat.rkt` relies on `numel` sizing that flvector, so a `'float64` round trip copies once
  each way; integer arrays come back as mutable arrays (`vector->array`). A
  device matrix with an extent of 0 comes back as an empty array that
  `matrix?` rejects.
- **`f32vector`s and `f64vector`s** are copied by `memcpy` between their
  storage and `host-memory` sized by their own length, not passed as
  `_host` (L1b's rule: `s:f64vector` can forge a length); the extra host
  copy costs about 3 ms per 10^6 elements. Byte strings pass as `_host`
  directly: `bytes-length` cannot be forged.
- **`bytes->device-vector` takes a required `#:dtype`**, reads the machine's
  byte order (`np.frombuffer`), and refuses a length that is not a whole
  number of elements. An unknown dtype name is refused by the shim, as
  elsewhere.
- **`matrix->device-vector` refuses** a matrix with more than one row and
  more than one column (data the conversion cannot make a vector of);
  `matrix->device-matrix` given an array of another rank is a wrong kind,
  unchecked until the contracts leg.

## The frozen downstream interface

Frozen at ABI version 1 (`RR_ABI_VERSION`, `raft-abi-version`) by
L1d. A change to anything in this list is a new ABI version, and the k-means
canary changes with it in the same pull request:

- **C:** `rr_view` (152 bytes, its field offsets pinned by
  `tests/c_api_compile_test.c`), `RR_MAX_RANK`, the `RR_DTYPE_*` and
  `RR_MEMORY_*` codes, `rr_buffer_view`, `rr_resources_handle`, `rr_abi_tag`
  (56 bytes) with `rr_abi` and `RR_ABI_VERSION`, the status codes, the error
  kinds and the `rr_last_error`/`rr_last_error_kind` convention.
- **C++ headers** (`packages.raft-dev`, `find_package(raftrkt)` →
  `raftrkt::headers`): `raftrkt/abi.h` (`rr_abi_compare`,
  `raftrkt::compiled_abi`, `raftrkt::require_abi`), `raftrkt/error.hpp`
  (`error_slot`, `translate_exceptions`, `classify`, `logic_error`,
  `cuda_error`, `cuda_check`, `require`, `device_scope`, `sync_guard`),
  `raftrkt/view.hpp` (`matrix_data`, `vector_data`, `matrix_view`,
  `vector_view`, `has_layout`, `canonical_strides`, `dtype_code`,
  `dtype_name`, `any_extent`, `handle_of`, `device_of`,
  `require_on_device`). Only the four dtype codes of today are frozen; cuVS's
  int8, uint8 and half arrays need new codes and so ABI version 2 (#8).
- **Racket** (`raft/unsafe`): `resources->handle-pointer`,
  `with-array-views` (with its `#:resources [handle r]` clause),
  `status-checker`, `raft-abi-pointer`; `core-test.rkt` pins the export set.
- **Additions at version 1 (#22):** `rr_deposit` (1256 bytes, offsets pinned
  by `c_api_compile_test.c`), `RR_MAX_REGIONS`, `RR_DEPOSIT_*` (OPEN 0,
  FILLED 1, CLOSED 2, FILLING 3), `rr_release_fn`, `raftrkt/deposit.hpp`
  (`region`, `deposit`), and `deposit`, `deposit?`, `with-deposits`,
  `deposit->list`. A downstream
  detects them by requiring `("raft" #:version "0.2")` or with
  `__has_include(<raftrkt/deposit.hpp>)`; a later change to `rr_deposit`'s
  layout is version 2.
- **Additions at version 1 (#32):** `raftrkt/job.h` (`rr_job_outcome`, 4104
  bytes, its offsets pinned by `tests/c_api_compile_test.c`;
  `RR_JOB_MESSAGE_BYTES`; `rr_job_fn`), `raftrkt/job.hpp` (`run_job`,
  `job_args_size`, the `job_parameter` concept, which admits #22's
  `rr_deposit*`) and `define-job` in
  `raft/unsafe`. A downstream detects them with
  `__has_include(<raftrkt/job.hpp>)`.

What a downstream binding must do, which the canary does: compile against `packages.rapids` and
`packages.raft-dev` of this flake (never another RAPIDS); check the tag at
load (`kc_check_abi` with `raft-abi-pointer`); take the handle and the
views with `with-array-views #:resources`, which keeps the resources
reachable for the call; run each entry point inside
`raftrkt::translate_exceptions` over its own thread-local `error_slot`;
select the handle's device (`device_scope`) and refuse arrays on another one
(`require_on_device`); read arrays only through `view.hpp`; allocate outputs
with raft's constructors on the resources the call runs on, or deposit
outputs sized by the call (`raftrkt::deposit` into a record from
`with-deposits`, on the call's handle); and synchronise
the handle's stream on every exit, a throw included (`sync_guard`), until
the stream API (#13) gives it events; and run each call that can run long
as a job: an `extern "C"` entry over `raftrkt::run_job`, bound with
`define-job`; `status-checker` for short calls only. Internal entry points
(`src/detail/*_api.h`) are not part of it and may change freely.

## Decisions recorded in L1d

- **`raft/unsafe` is a module, not a submodule of `raft`.** It gets its own
  `defmodule` and reference section and its own export pin, and `raft` does
  not re-export it, as with `raft/compat`; `(submod raft unsafe)` would put
  unsafe names one `require` away from every user of `raft`.
- **Four exports, not three.** The ABI check runs in the downstream's C++,
  against the headers it was compiled with (`require_abi`), so it needs
  `libraftrkt`'s tag: `raft-abi-pointer` hands it over. A Racket-side
  comparison could only check what the downstream recorded about itself.
- **`with-array-views`** evaluates the array expressions first, then for each
  array polls its stream until queued work is done (`settled-view`) and binds
  a view filled by `rr_buffer_view`. It expands to `with-release` (acquire
  once, refuse re-entry, `#:who 'with-array-views`); the release clears the
  view (`data` NULL, `device` and `memory` -1, so a view kept past the form is
  refused by `view.hpp`) and `void/reference-sink`s the array, which keeps
  it reachable for the whole extent. `#f` binds `#f` (a NULL `_pointer`), for
  optional arrays such as sample weights. It does not wait after the body:
  the downstream synchronises on every exit (L1b's stream rule). Waiting
  before binding costs a poll per array; the stream API (#13) can relax it to
  recorded events without changing the C interface.
- **`status-checker`** is curried, `((status-checker last-error
  last-error-kind #:exn exn) who thunk)`: the thunk's first value is the C
  status and the rest are returned on success, so a `_fun` that answers
  `(values status out ...)` needs no wrapper. Call and reads run on one OS
  thread, since the slot is per OS thread (one `call-as-atomic`; see #21
  and #32 below). Kind codes 0 to 3 map to
  `exn:fail:raft`'s kinds, anything else is `'generic`; bytes are decoded
  leniently. `#:exn` takes a constructor with `exn:fail:raft`'s fields, so a
  downstream can raise a subtype.
- **The handle pointer is borrowed**: a cpointer of the new type
  `_raft-handle`, never freed by Racket; the allocator audit gained
  `borrowed-types` and refuses an allocator wrap on one. It does not keep
  its resources reachable (the review of #20 reproduced the handle being
  freed while the pointer was held: `with-array-views`'s wait yields to the
  finalizer thread), so **`with-array-views` takes `#:resources [handle r]`**
  and keeps `r` reachable for the body, as it keeps the arrays. The bound
  handle is a plain cpointer, not cleared on exit, so it must not escape the
  form (documented). One form,
  not a separate `with-resources-handle`: every downstream call needs the
  handle and its arrays together, on the same resources (L1b's stream rule),
  so one form acquires both, in one extent, and a binding cannot take one
  without the other by mistake. `resources->handle-pointer` stays for code
  that holds the resources itself.
- **The headers carry the per-call rules** (review of #20): `device_scope`
  (the shim's own `rr::device_guard` is now this type), `sync_guard` (sync
  on success with an error, sync on a throw swallowing a second error),
  `handle_of`, `device_of` and `require_on_device` moved from the canary into
  the frozen headers, and `classify` knows RAFT's cuBLAS, cuSOLVER and
  cuSPARSE errors (`'cuda`, or `'out-of-memory` for
  `*_STATUS_ALLOC_FAILED`, read as `Reason=<code>:` from RAFT's message,
since cuSPARSE's error string for it is only "out of memory"). The frozen rule is
  "synchronise on every exit".
- **One implementation of each header.** `rr::translate_exceptions` is
  `raftrkt::translate_exceptions` over the shim's slot, `rr_abi`'s tag is
  `raftrkt::compiled_abi()`, and `view.cpp` uses `view.hpp`'s layout test.
  `rr_abi_tag` moved from `core.h` to `abi.h` (`core.h` keeps its typedef);
  its layout did not change, so the ABI version stays 1, which is the frozen
  version. `rr_abi_compare` is a `static inline` C function using
  `snprintf`, so a C caller can compare too (the C11 compile test calls it).
- **`view.hpp` checks what memory safety needs, named by argument:** a NULL or
  unbound view, the rank, the element type (`const T` reads `T`), the layout
  (an axis of extent 1 fits either), requested extents, extents that fit the
  index type, contiguous vectors. Messages are `"X: expected float32, got
  int32"`; the Racket binding prefixes its procedure's name.
- **`packages.rapids` is the full set** (RAFT, RMM, logger, cuML, cuVS,
  nvForest, NCCL) and `packages.raft-dev` is the shim's `dev` output (headers
  and `raftrkt-config.cmake`). The shim itself builds against
  `rapids.core`, the same `libraft`/`librmm`/logger derivations without
  cuML, so its checks do not download cuML on CI. The `libcuml-cu13` wheel
  ships its headers (`include/cuml`), so no source tag is pinned.
  `libcuvs-cu13` is 26.8.1, the only 26.08 release on PyPI (libcuml requires
  `==26.8.*`). `libnvforest` (a `NEEDED` of `libcuml.so`) and NCCL (a
  `NEEDED` of `libcuvs.so`; nixpkgs builds NCCL from source) come from their
  wheels. cuVS and nvForest join the prefix as `lib64` only: nvForest ships a
  second CCCL under `include/rapids`, which must not shadow RAFT's.
- **nvJitLink 13.3 everywhere.** `libcuvs.so` references
  `__nvJitLinkCreate_13_3`, which 13.2's library lacks, and only one
  `libnvJitLink.so.13` loads per process, so the flake overrides
  `cudaPackages_13.libnvjitlink` with `cudaPackages_13_3`'s (13.3.33, which
  keeps the 13.0 to 13.2 symbols). nvcc and the rest stay 13.2.
- **The canary links `libcuml.so` directly**, as an imported target:
  `cuml-config.cmake` requires Treelite and nvForest CMake packages that the
  run-time prefix does not carry. It does not link `libraftrkt`. It hides its
  static CUDA runtime (`--exclude-libs,ALL`) and keeps RMM's registry
  symbols exported, as the shim does (#10); its tests find them `UNIQUE` in
  both `libkmeans_canary.so` and `libcuml.so`, and show cuML's workspace
  coming from the pool raft installed (the pool's high-water mark rises
  during a fit and its use returns).
- **The canary's API**: `blobs` (rule 4 rules out `make-blobs`; it binds the
  C++ `ML::Datasets::make_blobs`, which differs from cuML Python's CuPy
  `make_blobs`), `kmeans-fit` (values centroids, inertia, iterations) and
  `kmeans-predict` (values labels, inertia), with cuML Python's `init` names
  and its `n_init='auto'` rule, `#:seed` defaulting to 0. It refuses data it
  would have to convert (column-major, integer) where cuML Python converts.
  It synchronises its handle's stream on every exit (`sync_guard`). It calls cuML's
  `int` overloads, as cuML Python does whenever the element count fits an
  `int`, and `view.hpp` refuses a view whose extent or element count does
  not; the `int64_t` overloads are the cuML binding's to add. A device
  matrix as `#:init` gives the cluster count by its rows (`#:n-clusters` is
  not consulted; cuML Python raises when they disagree, which would be a
  Racket argument check here). Its tests reach into raft's internals
  (`raft/private/foreign/memory` for the drop counters,
  `raft/tests/private/*` for the skip and twin helpers); only tests may.
- **`rr_resources_create` resolves the handle's device id under its device
  guard.** RAFT caches it from whatever device is current on first use, so a
  downstream's first `get_device_id` on another thread could otherwise
  cache the wrong device.
- **The twin passes the canary's data** to Python as JSON (exact for
  float32 and float64) instead of re-seeding, and compares by machine:
  adjusted Rand index 1 (`sklearn.metrics.adjusted_rand_score`), inertia and
  centroids (matched by label) within `1e-4`, on eight data sets covering
  both float types and all four inits.
- **The twin environment** gains `cuml-cu13`, which imports `cudf` at load,
  so `cudf`, `pylibcudf`, `libcudf`, `libkvikio`, `nvcomp`, `nvforest`,
  `treelite`, `numba-cuda`, `cuda-core` and `nvtx` come too, as wheels
  patched against the same prefix; nixpkgs supplies scikit-learn, pandas,
  pyarrow, numba and scipy. Their runtime-dependency check is off, since
  cudf caps pandas, pyarrow and numba just below the pin's versions, and
  `numba-cuda` 0.30.4 is patched not to register `np.row_stack`, which NumPy
  2.5 removed. Everything the twin runs imports and fits.
- **`status-checker` ran the whole native call in atomic mode**, holding up
  the place; #21 replaced it with an OS thread per call, and #32 restored
  it for short calls and made long calls jobs (below).
- **The memory test also samples `cudaMemGetInfo`** (`kc_device_memory`) and
  allows 256 MiB of device-wide drift, since the GPU is shared; the pool's
  own numbers are asserted exactly.
- **The twin covers seed-sensitive data:** nine overlapping-blob cases
  (2000×4, std 4.0, k=8, three inits × three fit seeds on one data set)
  besides the eight separated ones, and checks the iteration count against
  cuML's as well as ARI, inertia and centroids; on the overlapping cases the
  seed changes the result, so a dropped seed or init would show.
- **Follow-ups from the re-verification:** outputs sized only by the call
  (HDBSCAN's condensed tree) need an additive entry point that adopts a native
  buffer as a raft array (#22); `excerpt` in `scribblings/utils.rkt` reads
  repository files, which a catalog install lacks (#23), so fix it before
  any catalog release.
- **The ffi2 port (#15).** The frozen Racket exports hand out
  `ffi/unsafe` cpointers (a handle, cstruct pointers), and downstream
  bindings pass them as `_pointer`. A port to ffi2 must keep these exports
  producing values `ffi/unsafe` accepts, or bump the ABI version;
  `status-checker` takes thunks and is unaffected.

## Decisions recorded in #21 and #32

- **A long downstream call is a job** (#32, owner 2026-10-13). It runs on
  a native worker thread owned by its resources object: jobs on one object
  run one at a time in FIFO order, jobs on different objects in parallel,
  and the worker never runs Racket. The job owns a copy of its arguments and
  native references to its handle and buffers. The caller waits on an
  `unsafe-poller` over the job's eventfd, which registers nothing between
  sleeps and so needs no cleanup. A job costs about 20 µs a call (19,895 ns
  in `bench/status-checker.rkt`), against 31–33 µs for #21's OS thread per
  call.
- **`status-checker` is #20's `call-as-atomic`**, for short calls only;
  `os-call.rkt`, `calls-in-flight` and the `#:blocking?`/`atomic-interior`
  rule are gone.
- **Breaks are deferred.** A break during a job is raised when the job
  returns, ahead of the job's failure: cuML cannot be cancelled. Leaving
  `parameterize-break #f` does not raise a queued break, so the job
  re-enters the caller's break setting. A job called in atomic mode raises
  `'logic` (the spike's process died there).
- **Native pins replace the owner table.** A job pins each buffer and each
  deposit's holder through its native reference count and keeps the
  handle's `shared_ptr`, so a killed caller's arrays, deposits and resources
  live until the job returns; the
  worker drops them before the job leaves the registry. `hold-owner!` and
  its ephemeron table are gone.
- **A job leaves the registry before it is done** (#32 preflight, a
  departure from the spec's worker order). The worker releases everything
  native, erases its bound, and only then stores `RR_JOB_DONE` and signals
  the eventfd, so a caller woken by its job never counts it in flight
  (`Executor.AJobLeavesTheRegistryBeforeItIsDone` stalls the eventfd write
  to pin the order). The worker drops its own reference only after the
  signal, so a gtest reads its `rr_jobs_live` baseline settled
  (`settled_jobs_live`). A submit asks for admission before it prepares the
  job, so a refused submit copies, opens and pins nothing (it closes the
  deposits it was given, as the worker would have); a preparation
  that throws erases the bound again.
- **Two further departures from the spec's letter** (#32 review). The
  exit hook's `register-custodian-shutdown` result is discarded, not held
  in a module-level variable: it is only a weak custodian reference, and
  the callback still fires after repeated major collections. Law 59's
  `looping-main` fixture sleeps 0.3 s and then polls, bounded, until
  `jobs-in-flight` is 1 before `(exit 10)`, since job boundaries drift
  under load and a bare sleep races them.
- **What the spike settled** (S1–S5): a static first touched inside a job
  registers its destructor after any `on_exit` armed at the first submit,
  so that alone is not enough (S1); `register-custodian-shutdown` with the
  value `#f` never calls its callback, so the hook's value is `'raft` (S2);
  `unsafe-fd->evt` would need a `'remove` on every path out (S3); default
  resources live in a thread cell, so each thread gets its own worker (S4);
  places keep running during `exit()` (S5). No worker runs Racket, but a
  place can be inside a short call (`rr_buffer_alloc`,
  `rr_resources_create`, a finalizer's release) while `exit()` runs the
  RMM and cudart static destructors; the registry counts only jobs and
  reaper releases. The window is real and unfixed: `exit-test.rkt` runs a
  place allocating and freeing in a loop through `(exit 7)` fifty times
  and has never seen it, so short calls are not counted (#27 round 4).
- **The refinements over the spike** (R1–R9): the exit wait runs in the
  main place's at-exit hook, with a C backstop (R1); a submit during exit
  answers a refused job, not NULL (R2); outputs are copied back with
  `rr_job_read` (R3); the spike's timing and tracing knobs are dropped (R4);
  a job pins its deposits' holders and closes them on the worker (R5); `run_job` catches escaping
  exceptions, refuses a wrong block size without allocating, and constrains
  its parameters with a concept (R6); a job in atomic mode raises (R7); CI
  runs the executor on host resources (R8); `define-job` takes only listed
  number types and one `view` class (R9).
- **Exit is a bounded drain.** The main place's root-custodian `#:at-exit?`
  hook calls the blocking `rr_exit_drain`, which waits for the jobs in
  flight up to the largest `current-exit-wait` among them (read at submit),
  then logs `exit: jobs in flight: n; waited W ms` at `'debug` on `'raft`.
  Past the bound it logs `exit: jobs still running: n; releases still
  running: m; exiting without native teardown` at `'warning` and registers `on_exit(skip_teardown)`,
  which, registered last, runs first and calls `_exit`. A C backstop,
  registered with `on_exit` at the first submit, drains inside `exit()`
  when no hook ran (raft instantiated only in a place); destructors
  registered after that first job may then run first. Queued jobs run and
  count. A submit after the drain began answers a refused job, and its
  caller parks. One window is known: a job still running may register a
  destructor between the hook's arming and `exit()`.
- **The exit gtests gate their jobs instead of timing them** (#27 round
  3, a departure from laws 96, 97 and 103). A job that sleeps a fixed time
  is timed from the worker's start and each drain from its own, so under
  load a window such as law 96's 100–200 ms missed either way. The job now
  waits on a gate that opens once `rr_exit_waiters` shows every drain
  waiting. Law 96 asserts both drains get (1, 0); a waiter left asleep
  never returns, and the child's 5 s alarm fails the test. Law 97's
  1e300 and `+inf` cases assert (1, 0) with no window. Law 97's recompute
  case bounds the gated job at 10 s beside a stuck job bound to 0.1 and
  asserts (2, 1) in 0.1–3 s: without the recompute the drain waits out the
  10 s and the alarm fires. Law 103 asserts (2, 0) with no window. The
  windows of laws 94, 95 and 98 to 102 are measured from the drain's own
  start against bounds the drain computes, so no thread's start moves
  them.
- **#26 and #28 are closed by #32.**
- **Releases go to two reaper threads** (#27 round 4, R-H1; round 5,
  D-M1). Process-wide native reapers take every release made outside a
  worker, rather than the resources' own worker: they cover resources that
  never ran a job and buffers that outlive their resources, and they are
  two threads however many resources exist. Buffer memory has its own
  lane: one FIFO let a stream-ordered free wait behind a cuBLAS destroy's
  `cudaDeviceSynchronize`, holding freed memory with no bound. A release
  enqueued after a clean exit verdict runs on its caller; after a skip it
  leaks (D-L8). The drain waits for releases in progress up to the
  largest job bound or one second (`release_grace`), whichever is longer,
  and past it skips teardown.
- **Resources charge the collector** (#27 round 4, R-L2). Each resources
  object holds phantom bytes, 1 MiB plus 64 KiB on a device and 64 KiB for
  host resources, dropped on an explicit release. Measured on the lab GPU:
  about 120 KiB of device memory for the stream and 50 KiB of RSS for the
  worker thread, and 8.8 MiB of device memory once cuBLAS is created. The
  1 MiB charge brought the live workers of 2,000 sequential short-lived
  threads from a peak of 391 to 11–14; `worker-growth-test.rkt` asserts
  fewer than 100 over the baseline for 500 threads.

## Decisions recorded in #22

- **A deposit record, not `rr_buffer_adopt(device_buffer&&)`.** A
  downstream cannot call `libraftrkt` (it does not link it, and `ffi-lib`
  loads raft locally), cuML keeps HDBSCAN's call-sized outputs in private
  `device_uvector` members, and an RMM buffer cannot cross a C boundary
  (its `any_resource` vtable belongs to the allocating library). So raft
  makes an `rr_deposit` inside an `rr_holder`, and the downstream's header
  code writes an owner, a release function and up to 8 region views into it,
  as cuML's Python does with `UnownedMemory(ptr, size, owner)`.
- **The ABI version stays 1**; the additions are listed as such and raft's
  package version is 0.2.
- **`with-deposits` is its own form**, so `with-array-views` stays frozen.
  A job pins the holder natively and closes it on the worker (or at a
  refused submit, which pins nothing); `define-job` binds a job's deposits
  through `call-with-deposits-bound` (`deposit.rkt`, over `with-release`),
  which closes those it bound when a later binding or the submit raises and
  otherwise leaves them to the worker. `with-deposits` (short calls) closes
  on every exit. A closed record
  refuses a fill.
  `rr_holder_record` hands the record out once (every exit closes, so no
  legitimate second binding exists). `deposit.hpp` first claims the record
  with a compare-and-swap from OPEN to `RR_DEPOSIT_FILLING` (3, an addition
  at version 1); a refused claim touches nothing, so a second filler cannot
  disturb the first. Only the claimant writes the other fields, and it
  publishes with a compare-and-swap from FILLING to FILLED, taking the owner
  only after it succeeds; a close in between wins, the claimant clears what
  it wrote and refuses with "closed", and the caller's `unique_ptr` frees the
  owner. A refused claim says "being filled" for FILLING, "already
  filled" for FILLED and "closed" otherwise: a claimant can still unclaim or
  lose to a close. Readers treat FILLING as OPEN. `rr_holder_count` and
  `rr_holder_adopt` refuse a deposit with "still open" while it is open,
  while it is being filled, and while a job that filled it still runs (#30,
  a departure from #22's spec, which refused only OPEN and FILLING): a job
  publishes FILLED while its entry still runs and the worker closes the
  deposit after the entry returns, so `queued_job` sets the holder's
  `job_bound` before the submit and adoption of a job's deposit waits for
  the close (law 104). A FILLED deposit no job holds adopts unclosed: a
  `with-deposits` caller killed after the fill never runs the close (law 8).
  The shim's refusals: "the deposit is
  closed", "the deposit is already filled", "the deposit is already bound",
  "the deposit is still open", "the deposit has no region 3; it holds 2",
  "region 0 is already adopted".
- **`deposit.hpp` checks a region's byte size before its layout**, unlike
  the spec's order: canonical strides of overflowing extents overflow too,
  so the layout check would report a misleading "neither row-major nor
  col-major".
- **Adoption is all or nothing.** `deposit->list` adopts regions in order;
  a failure after the index checks clears every adopted flag, and Racket
  frees the arrays it already made, so a retry starts again instead of
  failing "region 0 is already adopted".
- **Ownership.** The holder and every adopted `rr_buffer` share one
  `shared_ptr<void>(owner, release)`, made on the first adopt or at holder
  free; the handle `shared_ptr` is declared before it, so the owner is
  released, once, with its handle alive, in every order of freeing (the
  ASAN gtest runs all 6). `rr_owner_release_count` counts releases;
  `release_on_device` covers holders, so `rr_release_failure_count` counts
  a holder that could not select its device.
- **The shim checks a filled record again** at `rr_holder_count` and
  `rr_holder_adopt` with `deposit.hpp`'s own checks, so a record filled by
  hand raises `'logic` instead of crashing. Messages name the region, never
  an `rr_` function.
- **`deposit->list` adopts every region in one `call-as-atomic`** and caches
  the list, so two threads get `eq?` arrays. Phantom bytes cover the regions
  only.
- **`deposit->owner-pointer`** for opaque state (HDBSCAN's `PredictionData`)
  waits for rkt-cuml's HDBSCAN prediction leg; it is additive.
- **The canary's `cluster-members`** gathers on the host side of the copy
  engine (labels to host, one device-to-device copy per run of rows), since
  the canary has no CUDA language; its owner holds two `device_uvector`s and
  the handle, like cuML's outputs. It runs as a job
  (`kc_cluster_members_job`, a `deposit` parameter, a 328-byte block);
  `with-deposits` stays for short calls.
