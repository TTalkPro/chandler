#!chezscheme
;;; chandler/test/miniregex.ss --- (chandler miniregex) 测试
;;;
;;; 覆盖文法四件:字面量 / `.` 任意 / `^`-`$` 锚点 / `\X` 转义,以及
;;; 库实例化时把 regexp-match? 注册进 task-engine 钩子这件事。

(library (chandler test miniregex)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler task-engine)
          (chandler miniregex))

  (define-suite suite
    (regexp-parse
      ;; regexp 返回 miniregex record;锚点不进 atoms。
      (let ((re (regexp "^ab$")))
        (assert-true (miniregex? re))
        (assert-true (miniregex-start-anchored? re))
        (assert-true (miniregex-end-anchored? re))
        (assert-equal 2 (length (miniregex-atoms re))))
      (let ((re (regexp "ab")))
        (assert-false (miniregex-start-anchored? re))
        (assert-false (miniregex-end-anchored? re))))

    (match-literal
      ;; 无锚点 = 子串匹配。
      (assert-true  (regexp-match? "bc" "abcd"))
      (assert-true  (regexp-match? "abcd" "abcd"))
      (assert-false (regexp-match? "bd" "abcd"))
      (assert-false (regexp-match? "abcde" "abcd")))

    (match-anchors
      (assert-true  (regexp-match? "^ab" "abcd"))
      (assert-false (regexp-match? "^bc" "abcd"))
      (assert-true  (regexp-match? "cd$" "abcd"))
      (assert-false (regexp-match? "bc$" "abcd"))
      (assert-true  (regexp-match? "^abcd$" "abcd"))
      (assert-false (regexp-match? "^abc$" "abcd")))

    (match-any
      (assert-true  (regexp-match? "a.c" "abc"))
      (assert-true  (regexp-match? "^..$" "xy"))
      (assert-false (regexp-match? "^..$" "xyz")))

    (match-escape
      ;; `\.` 是字面点,不是「任意字符」—— rule pattern 的常用形 `\.ss$`。
      (assert-true  (regexp-match? "\\.ss$" "foo.ss"))
      (assert-false (regexp-match? "\\.ss$" "fooxss"))
      (assert-true  (regexp-match? ".ss$"  "fooxss")))

    (match-precompiled
      ;; regexp-match? 既收字符串也收编译好的 miniregex。
      (let ((re (regexp "\\.so$")))
        (assert-true  (regexp-match? re "lib/a.so"))
        (assert-false (regexp-match? re "lib/a.ss"))))

    (hook-registered
      ;; 库体末尾注册进 task-engine —— engine 的 resolve 靠它匹配 rule。
      (assert-true  ((current-regexp-matcher) "\\.out$" "a.out"))
      (assert-false ((current-regexp-matcher) "\\.out$" "a.in")))

    ))
