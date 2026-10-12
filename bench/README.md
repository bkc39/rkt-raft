# Benchmarks

Run on the lab host, in the dev shell, with nothing else on the GPU. The
planned benchmarks and how they should run are in
[#25](https://github.com/bkc39/rkt-raft/issues/25).

## Conversions

```bash
racket bench/conversions.rkt      # the table below, as Markdown
racket bench/typed-arrays.rkt     # math/array built in Typed Racket against untyped
```

`conversions.rkt` sends each Racket form to the GPU as `float64` and as
`float32` and brings it back, 10^6 elements (the last four rows 1000×1000),
and prints the median of five runs after a warm-up, with a minor collection
before each run.

Milliseconds per million elements; RTX 3090 Ti, Racket 9.3 CS, 2026-10-05.
A dash means the same time as the flonum array, through which every
`math/array` array comes back.

| Racket value | to float64 | to float32 | back from float64 | back from float32 |
|---|---:|---:|---:|---:|
| list | 33.5 | 32.6 | 51.0 | 49.6 |
| list, by list*->device-array | 38.2 | 35.4 | 48.4 | 50.7 |
| vector | 32.2 | 30.6 | 35.1 | 30.1 |
| flvector | 0.8 | 35.9 | 3.8 | 63.2 |
| f64vector | 4.0 | 44.3 | 12.2 | 52.2 |
| f32vector | 44.3 | 1.8 | 51.3 | 3.3 |
| bytes | 0.8 | 0.4 | 3.8 | 1.9 |
| math FlArray | 1.1 | 31.3 | 4.1 | 55.9 |
| math mutable array | 32.4 | 30.7 | — | — |
| math array from build-array | 558.8 | 567.2 | — | — |
| nested list, 1000×1000 | 49.3 | 50.0 | 52.7 | 52.7 |
| nested vector, 1000×1000 | 36.1 | 38.2 | 42.5 | 41.1 |
| math FlArray, 1000×1000 | 1.0 | 31.0 | 3.9 | 57.1 |
| math mutable array, 1000×1000 | 33.6 | 35.1 | — | — |

- Storage that matches the element type crosses in one copy, 1 to 4 ms: an
  `flvector` or flonum array as `float64`, bytes as anything; an `f32vector`
  or `f64vector` in its own type takes one more host copy.
- Lists and vectors cost 35 to 55 ns an element.
- Changing the element type on the way costs 30 to 60 ms.
- Any other `math/array` array, such as one from `build-array` or
  `math/matrix`, is read through a Typed Racket contract, about 0.6 µs an
  element; built in Typed Racket and converted with `array->flarray` there,
  1000×1000 takes 80 ms against 710 (`typed-arrays.rkt`).

## Downstream calls

```bash
racket bench/status-checker.rkt   # ns per call of the canary's kc_pool_bytes
```

The median of five runs of 20,000 calls, after a warm-up. RTX 3090 Ti,
Racket 9.3 CS, 2026-10-12, for #15.

| kc_pool_bytes through | ns/call |
|---|---:|
| the bare _fun | 258 |
| call-as-atomic (status-checker before #21) | 1055 |
| status-checker (an OS thread per call) | 35040 |

- Starting an OS thread for each call costs about 34 µs over the
  `call-as-atomic` checker. A one-second `kmeans-fit` does not notice; a
  downstream making many short calls does.
- During a one-second `kmeans-fit` a 10 ms ticker thread ran 95 to 99 times
  (none through `call-as-atomic`), and a break sent 50 ms in was raised at
  967 ms, when the fit returned.
