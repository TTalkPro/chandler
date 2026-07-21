#!chezscheme
;;; chandler/test/proc.ss --- (chandler proc) 测试(POSIX 命令)

(library (chandler test proc)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler proc))

  (define-suite suite
    (quote-plain
      (assert-string= "'abc'" (shell-quote "abc")))

    (quote-with-quote
      (assert-string= "'a'\\''b'" (shell-quote "a'b")))

    (quote-metachars
      ;; 空格与 $ 被引用后原样,不展开
      (let ([r (run-capture "echo" (list "a b" "$HOME"))])
        (assert-equal 0 (proc-result-code r))
        (assert-string= "a b $HOME\n" (proc-result-out r))))

    (capture-stdout
      (let ([r (run-capture "echo" '("hello"))])
        (assert-equal 0 (proc-result-code r))
        (assert-string= "hello\n" (proc-result-out r))))

    (capture-stderr-and-code
      (let ([r (run-capture "sh" '("-c" "echo oops 1>&2; exit 3"))])
        (assert-equal 3 (proc-result-code r))
        (assert-string= "oops\n" (proc-result-err r))))

    (run-check-ok
      (assert-string= "ok\n" (run-check "echo" '("ok"))))

    (run-check-fails
      (assert-raises (lambda () (run-check "false" '()))))

    (run-status-bool
      (assert-equal 0 (run-status "true" '()))
      (assert-equal 1 (run-status "false" '())))

    (cwd-option
      (let ([r (run-capture "pwd" '() '((cwd . "/tmp")))])
        (assert-equal 0 (proc-result-code r))
        ;; /tmp 或其 realpath(如 macOS /private/tmp);至少非空且以换行结尾
        (assert-true (> (string-length (proc-result-out r)) 1))))

    (env-option
      (let ([r (run-capture "sh" '("-c" "echo $CHANDLER_TEST_VAR")
                            '((env . (("CHANDLER_TEST_VAR" . "xyz")))))])
        (assert-string= "xyz\n" (proc-result-out r))))))
