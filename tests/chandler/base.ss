#!chezscheme
;;; tests/chandler/base.ss --- (chandler base) umbrella 冒烟测试

(library (tests chandler base)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler base))

(define-suite suite
  (re-exports-runtime-paths
    (assert-true (procedure? resource-path))
    (assert-true (procedure? find-resource-path)))

  (re-exports-hash
    (assert-true (procedure? sha256-string)))

  (re-exports-version
    (assert-true (procedure? version-match?)))

  (re-exports-util
    (assert-true (procedure? string-split))
    (assert-true (procedure? getenv*)))

  (re-exports-fs
    (assert-true (procedure? copy-file))
    (assert-true (procedure? ensure-dir)))

  (re-exports-sexp
    (assert-true (procedure? read-datum-file)))

  (re-exports-layout
    (assert-true (procedure? join-paths))
    (assert-true (procedure? current-machine-type)))

  (re-exports-runtime-detector
    (assert-true (procedure? current-runtime))
    (assert-true (procedure? chez-version-string)))

  (re-exports-proc
    (assert-true (procedure? run-capture)))))
