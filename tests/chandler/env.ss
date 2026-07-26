#!chezscheme
;;; tests/chandler/env.ss --- (chandler env) .env 读取测试(C3)

(library (tests chandler env)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler fs)
          (chandler layout)
          (chandler env))

  ;; 写一份 .env 到临时目录,返回其路径
  (define (dotenv! text)
    (let ([d (mktmp)])
      (write-file (join-paths d ".env") text)
      (join-paths d ".env")))

  (define (val pairs key) (cond [(assoc key pairs) => cdr] [else #f]))

  (define-suite suite

    (missing-file-is-empty
      (assert-equal '() (read-dotenv "/no/such/path/.env")))

    (basic-key-value
      (let ([e (read-dotenv (dotenv! "FOO=bar\nBAZ=qux\n"))])
        (assert-string= "bar" (val e "FOO"))
        (assert-string= "qux" (val e "BAZ"))
        (assert-equal 2 (length e))))

    (preserves-order
      (let ([e (read-dotenv (dotenv! "A=1\nB=2\nC=3\n"))])
        (assert-equal '("A" "B" "C") (map car e))))

    (blank-and-comment-lines-skipped
      (let ([e (read-dotenv (dotenv! "# a comment\n\nFOO=bar\n   \n#another\nBAZ=qux\n"))])
        (assert-equal 2 (length e))
        (assert-string= "bar" (val e "FOO"))))

    (export-prefix-stripped
      (let ([e (read-dotenv (dotenv! "export FOO=bar\n"))])
        (assert-string= "bar" (val e "FOO"))))

    (whitespace-around-key-and-value
      (let ([e (read-dotenv (dotenv! "  FOO = bar  \n"))])
        (assert-string= "bar" (val e "FOO"))))

    (empty-value
      (let ([e (read-dotenv (dotenv! "FOO=\n"))])
        (assert-string= "" (val e "FOO"))))

    (double-quoted-value
      (let ([e (read-dotenv (dotenv! "FOO=\"hello world\"\n"))])
        (assert-string= "hello world" (val e "FOO"))))

    (double-quote-escapes
      (let ([e (read-dotenv (dotenv! "FOO=\"a\\tb\\nc\"\n"))])
        (assert-string= "a\tb\nc" (val e "FOO"))))

    (single-quoted-is-literal
      ;; 单引号内 ${VAR} 不展开、转义不生效(与 shell 一致)
      (let ([e (read-dotenv (dotenv! "FOO='literal ${HOME} \\n'\n"))])
        (assert-string= "literal ${HOME} \\n" (val e "FOO"))))

    (unquoted-trailing-space-trimmed
      (let ([e (read-dotenv (dotenv! "FOO=bar   \n"))])
        (assert-string= "bar" (val e "FOO"))))

    (expand-earlier-entry
      ;; ${VAR} 先查本文件更早的条目
      (let ([e (read-dotenv (dotenv! "BASE=/opt\nBIN=${BASE}/bin\n"))])
        (assert-string= "/opt/bin" (val e "BIN"))))

    (expand-in-unquoted
      (let ([e (read-dotenv (dotenv! "BASE=/opt\nBIN=${BASE}/bin\n"))])
        (assert-string= "/opt/bin" (val e "BIN"))))

    (expand-from-process-env
      ;; 本文件没有则查进程环境
      (let ([old (getenv "CHANDLER_TEST_XYZ")])
        (dynamic-wind
          (lambda () (putenv "CHANDLER_TEST_XYZ" "from-proc"))
          (lambda ()
            (let ([e (read-dotenv (dotenv! "FOO=${CHANDLER_TEST_XYZ}/x\n"))])
              (assert-string= "from-proc/x" (val e "FOO"))))
          (lambda () (putenv "CHANDLER_TEST_XYZ" (or old ""))))))

    (expand-missing-is-empty
      (let ([e (read-dotenv (dotenv! "FOO=[${NO_SUCH_VAR_XYZ}]\n"))])
        (assert-string= "[]" (val e "FOO"))))

    (earlier-entry-beats-process-env
      ;; 同名时本文件更早条目优先于进程环境
      (let ([old (getenv "CHANDLER_TEST_DUP")])
        (dynamic-wind
          (lambda () (putenv "CHANDLER_TEST_DUP" "proc"))
          (lambda ()
            (let ([e (read-dotenv (dotenv! "CHANDLER_TEST_DUP=file\nX=${CHANDLER_TEST_DUP}\n"))])
              (assert-string= "file" (val e "X"))))
          (lambda () (putenv "CHANDLER_TEST_DUP" (or old ""))))))

    (bare-dollar-not-expanded
      ;; 只认 ${…};裸 $VAR 与孤立 $ 原样保留
      (let ([e (read-dotenv (dotenv! "FOO=$HOME/x\nBAR=cost$5\n"))])
        (assert-string= "$HOME/x" (val e "FOO"))
        (assert-string= "cost$5" (val e "BAR"))))

    (unterminated-brace-kept
      (let ([e (read-dotenv (dotenv! "FOO=a${bad\n"))])
        (assert-string= "a${bad" (val e "FOO"))))

    (value-with-equals-sign
      ;; 只在**第一个** = 处切分,值里可含 =
      (let ([e (read-dotenv (dotenv! "URL=k=v&a=b\n"))])
        (assert-string= "k=v&a=b" (val e "URL"))))

    ;; ── 错误路径:malformed 报错(带行号,可操作)──
    (missing-equals-errors
      (assert-raises (lambda () (read-dotenv (dotenv! "FOO=ok\nGARBAGE LINE\n")))))

    (empty-key-errors
      (assert-raises (lambda () (read-dotenv (dotenv! "=value\n")))))

    (invalid-key-errors
      (assert-raises (lambda () (read-dotenv (dotenv! "1BAD=x\n"))))
      (assert-raises (lambda () (read-dotenv (dotenv! "a-b=x\n")))))

    ))
