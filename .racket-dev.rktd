;; Gates for the racket-dev plugin's runner (hooks/gate.rkt) and pre-push hook.
;;
;;   racket <plugin>/hooks/gate.rkt . all      ; everything, in this order
;;   racket <plugin>/hooks/gate.rkt . push     ; the subset the pre-push hook runs
;;   racket <plugin>/hooks/gate.rkt . docs     ; one gate by name
;;
;; A command whose first word is `nix` runs as is; every other command is
;; prefixed by `shell`. nix reads the git-tracked tree, so stage new files
;; before any nix gate. AGENTS.md's Tooling table says what each gate checks.

((shell "nix develop --max-jobs 1 --cores 4 --command")
 (base-ref "origin/master")
 (gates
  (native         "nix run --max-jobs 1 --cores 4 .#copy-native-libs")
  ;; treefmt in CI mode: every formatter, shellcheck, actionlint and ruff
  ;; check; fails when a file would change.
  (format         "nix fmt --max-jobs 1 --cores 4 -- --ci")
  (no-syntax-rule ("scripts/no-syntax-rule.sh" #:shell ""))
  (no-raw-malloc  ("scripts/no-raw-malloc.sh" #:shell ""))
  (review         "scripts/review.sh")
  (compile        "raco make -v raft/main.rkt scripts/check-bindings.rkt")
  (test           "raco test raft")
  (bindings       "racket scripts/check-bindings.rkt")
  ;; Needs the GPU host: shim gtests (also under compute-sanitizer memcheck),
  ;; an LD_BIND_NOW load, the Racket tests with twin parity, the census.
  ;; Prints the SKIP count.
  (gpu            "scripts/gpu-suite.sh")
  (resyntax       "scripts/resyntax.sh origin/master")
  (docs           "scripts/render-docs.sh /tmp/rkt-raft-docs")
  (sanitizers     "nix build --max-jobs 1 --cores 4 --no-link .#checks.x86_64-linux.shim-sanitizers")
  ;; The CI-equivalent: every flake check (AGENTS.md lists them).
  (check          "nix flake check --max-jobs 1 --cores 4"))
 (push-gates (format no-syntax-rule no-raw-malloc review compile test bindings)))
