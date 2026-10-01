;; Gates for the racket-dev plugin's runner (hooks/gate.rkt) and pre-push hook.
;;
;;   racket <plugin>/hooks/gate.rkt . all      ; everything, in this order
;;   racket <plugin>/hooks/gate.rkt . push     ; the subset the pre-push hook runs
;;   racket <plugin>/hooks/gate.rkt . docs     ; one gate by name
;;
;; A command whose first word is `nix` runs as is; every other command is
;; prefixed by `shell`. nix reads the git-tracked tree, so stage new files
;; before any nix gate.

((shell "nix develop --command")
 (base-ref "origin/master")
 (gates
  (native         "nix run .#copy-native-libs")
  (no-syntax-rule ("scripts/no-syntax-rule.sh" #:shell ""))
  (no-raw-malloc  ("scripts/no-raw-malloc.sh" #:shell ""))
  (compile        "raco make -v raft/main.rkt scripts/check-bindings.rkt")
  (test           "raco test raft")
  (bindings       "racket scripts/check-bindings.rkt")
  ;; Needs the GPU host: shim gtests, an LD_BIND_NOW load, the Racket tests
  ;; with twin parity, the census. Prints the SKIP count.
  (gpu            "scripts/gpu-suite.sh")
  (resyntax       "resyntax analyze --local-git-repository . origin/master")
  (docs           "scripts/render-docs.sh /tmp/rkt-raft-docs")
  ;; The CI-equivalent: shim build and gtests, C headers as C, clang-format,
  ;; clang-tidy, the line gate, the Racket build and tests, the census, the
  ;; version floor and both grep gates.
  (check          "nix flake check"))
 (push-gates (no-syntax-rule no-raw-malloc compile test bindings)))
