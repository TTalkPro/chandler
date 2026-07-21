#!chezscheme
;;; chandler/test/version.ss --- (chandler version) 测试

(library (chandler test version)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler version))

  (define-suite suite
    (parse-basic
      (assert-equal '(1 2 0) (parse-version "1.2.0"))
      (assert-equal '(1 2) (parse-version "1.2"))
      (assert-equal '(0 3) (parse-version "0.3"))
      (assert-equal '(1 2 3) (parse-version "v1.2.3"))          ; 剥 v
      (assert-equal '(1 2 0) (parse-version "1.2.0-rc1")))       ; 截 pre-release

    (parse-rejects
      (assert-raises (lambda () (parse-version "1.x.0"))))

    (compare
      (assert-equal -1 (version-compare '(1 2 0) '(1 3 0)))
      (assert-equal 1  (version-compare '(2 0 0) '(1 9 9)))
      (assert-equal 0  (version-compare '(1 2 0) '(1 2)))        ; 缺位视 0
      (assert-true (version<? '(1 0 0) '(1 0 1)))
      (assert-true (version=? '(1 2) '(1 2 0))))

    (exact
      (assert-true (version-match? "1.2.0" "1.2.0"))
      (assert-false (version-match? "1.2.0" "1.2.1")))

    (any
      (assert-true (version-match? "*" "99.0.0")))

    (gte-lte
      (assert-true (version-match? ">=0.3" "0.3.0"))
      (assert-true (version-match? ">=0.3" "1.0.0"))
      (assert-false (version-match? ">=0.3" "0.2.9"))
      (assert-true (version-match? "<=1.0.0" "1.0.0"))
      (assert-false (version-match? ">1.0.0" "1.0.0"))
      (assert-true (version-match? ">1.0.0" "1.0.1")))

    (caret
      ;; ^1.2.0 → >=1.2.0 <2.0.0
      (assert-true (version-match? "^1.2.0" "1.2.0"))
      (assert-true (version-match? "^1.2.0" "1.9.9"))
      (assert-false (version-match? "^1.2.0" "2.0.0"))
      (assert-false (version-match? "^1.2.0" "1.1.9"))
      ;; ^0.2.3 → >=0.2.3 <0.3.0(最左非零 = minor)
      (assert-true (version-match? "^0.2.3" "0.2.9"))
      (assert-false (version-match? "^0.2.3" "0.3.0"))
      ;; ^0.0.3 → >=0.0.3 <0.0.4
      (assert-true (version-match? "^0.0.3" "0.0.3"))
      (assert-false (version-match? "^0.0.3" "0.0.4")))

    (tilde
      ;; ~1.2.0 → >=1.2.0 <1.3.0
      (assert-true (version-match? "~1.2.0" "1.2.9"))
      (assert-false (version-match? "~1.2.0" "1.3.0"))
      ;; ~1 → >=1.0.0 <2.0.0
      (assert-true (version-match? "~1" "1.9.9"))
      (assert-false (version-match? "~1" "2.0.0")))

    (conjunction
      (assert-true (version-match? ">=0.4 <0.5" "0.4.3"))
      (assert-false (version-match? ">=0.4 <0.5" "0.5.0"))
      (assert-false (version-match? ">=0.4 <0.5" "0.3.9")))

    (select-highest-tags
      (assert-string= "v1.4.0"
        (select-highest "^1.2.0" '("v1.2.0" "v1.4.0" "v2.0.0" "v1.3.5")))
      (assert-string= "v1.3.5"
        (select-highest "~1.3" '("v1.2.0" "v1.3.5" "v1.4.0")))
      (assert-equal #f
        (select-highest "^3.0.0" '("v1.0.0" "v2.0.0")))
      ;; 混入非版本 tag 应被跳过
      (assert-string= "v1.1.0"
        (select-highest ">=1.0" '("release" "v1.1.0" "nightly"))))))
