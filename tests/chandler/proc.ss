#!chezscheme
;;; tests/chandler/proc.ss --- (chandler proc) 测试
;;;
;;; 两部分:
;;;   ① POSIX 端到端 —— 真起子进程,验证引用后的串穿过 /bin/sh 原样抵达。
;;;   ② **平台参数化**的串生成 —— `windows-shell?` 是个 parameter,于是 Windows
;;;      那半边(cmd 引用 / `set "K=v" &&` / `cd /d`)在 Linux 上就能逐字断言。
;;;      不这么做,那半边代码在 CI 里等于从来没被执行过(D33,designs/14 §5)。

(library (tests chandler proc)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
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

    (env-prefix-quotes-and-skips-false
      ;; 值经 shell-quote,故含空格/元字符的值不会被 sh 拆开或展开;
      ;; 值为 #f 的项整条跳过(调用方把可选环境变量直接写成 (cons "K" #f))。
      (assert-string= "A='x y' " (env-prefix '(("A" . "x y"))))
      (assert-string= "A='$HOME' " (env-prefix '(("A" . "$HOME"))))
      (assert-string= "B='2' " (env-prefix '(("A" . #f) ("B" . "2")))))

    (env-prefix-round-trips-through-sh
      ;; 端到端:含空格与 $ 的值必须原样抵达子进程,不被 /bin/sh 展开
      (let ([r (run-capture "sh" '("-c" "printf %s \"$V\"")
                            '((env . (("V" . "a b $HOME `id` \"q\"")))))])
        (assert-equal 0 (proc-result-code r))
        (assert-string= "a b $HOME `id` \"q\"" (proc-result-out r))))

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
        (assert-string= "xyz\n" (proc-result-out r))))

    ;; ══════════════════════════════════════════════════════════════
    ;; Windows 侧(平台参数化;不起子进程,逐字断言生成的命令串)
    ;; ══════════════════════════════════════════════════════════════

    ;; shell-quote 按 windows-shell? 分派到两份实现
    (shell-quote-dispatches-on-platform
      (assert-string= "'abc'" (parameterize ([windows-shell? #f]) (shell-quote "abc")))
      (assert-string= "\"abc\"" (parameterize ([windows-shell? #t]) (shell-quote "abc"))))

    ;; MSVCRT 规则:普通字符之前的反斜杠**原样**,不加倍
    (cmd-quote-plain-backslashes
      (assert-string= "\"C:\\Users\\t\"" (cmd-quote "C:\\Users\\t"))
      (assert-string= "\"C:\\Program Files\\x\"" (cmd-quote "C:\\Program Files\\x")))

    ;; **结尾**的连续反斜杠必须加倍 —— 否则最后那个 \ 会转义掉我们的收尾引号,
    ;; 参数边界就此崩掉,后面的参数被并进来。这是 MSVCRT 引用最容易漏的一条。
    (cmd-quote-doubles-trailing-backslashes
      (assert-string= "\"a\\\\\"" (cmd-quote "a\\"))
      (assert-string= "\"a\\\\\\\\\"" (cmd-quote "a\\\\"))
      ;; 中间的不加倍,只有结尾的加倍
      (assert-string= "\"a\\b\\\\\"" (cmd-quote "a\\b\\")))

    ;; cmd 元字符全在引号内 → 这一层自动安全,不需要额外 ^ 转义
    (cmd-quote-metachars-are-inside-quotes
      (for-each
        (lambda (s)
          (assert-string= (string-append "\"" s "\"") (cmd-quote s)))
        (list "a&b" "a|b" "a>b" "a<b" "a^b" "a(b)c" "a;b" "a,b" "a=b")))

    ;; `%` **刻意放行**:cmd 只展开已定义的 %VAR%,而 URL 编码(%20)随处可见,
    ;; 一律拒会造出大量假阳性。限制记在 designs/14 §3.3。
    (cmd-quote-allows-percent
      (assert-string= "\"https://h/a%20b.git\"" (cmd-quote "https://h/a%20b.git")))

    ;; 无法安全传递的当场硬错 —— 传错比报错危险得多:字面 `"` 会让引号配对错位,
    ;; 后面的 & | > ^ 落到引号外变成 cmd 的控制字符(命令注入面)。
    (cmd-quote-rejects-unsafe
      (assert-raises (lambda () (cmd-quote "quo\"te")))
      (assert-raises (lambda () (cmd-quote "line\nbreak")))
      (assert-raises (lambda () (cmd-quote "cr\rhere")))
      ;; 经 shell-quote 分派进来也一样拒
      (assert-raises (lambda () (parameterize ([windows-shell? #t]) (shell-quote "a\"b")))))

    ;; env-prefix:cmd **完全不认** `K=v cmd`,必须 `set "K=v" && cmd`
    (env-prefix-windows-form
      (assert-string= "set \"K=v\" && "
                      (parameterize ([windows-shell? #t]) (env-prefix '(("K" . "v")))))
      ;; 多项串联,顺序保持
      (assert-string= "set \"A=1\" && set \"B=2\" && "
                      (parameterize ([windows-shell? #t])
                        (env-prefix '(("A" . "1") ("B" . "2")))))
      ;; 值含空格 / cmd 元字符 → 由引号兜住
      (assert-string= "set \"P=a b&c\" && "
                      (parameterize ([windows-shell? #t]) (env-prefix '(("P" . "a b&c"))))))

    ;; #f 值跳过 —— 两侧同一语义(native-build 的可选 CHEZ_INCLUDE 靠它)
    (env-prefix-skips-false-both-platforms
      (assert-string= "" (parameterize ([windows-shell? #t]) (env-prefix '(("K" . #f)))))
      (assert-string= "" (parameterize ([windows-shell? #f]) (env-prefix '(("K" . #f)))))
      (assert-string= "set \"B=2\" && "
                      (parameterize ([windows-shell? #t])
                        (env-prefix '(("A" . #f) ("B" . "2"))))))

    ;; POSIX 侧的 env-prefix 不受影响(回归)
    (env-prefix-posix-form
      (assert-string= "K='v' "
                      (parameterize ([windows-shell? #f]) (env-prefix '(("K" . "v"))))))

    ;; cd 前缀:**`/d` 不能少**。不带它时 cmd 遇到另一个盘符会静默不切过去,
    ;; 命令就在错误的目录里跑起来,而且不报错。
    (cd-prefix-windows-needs-slash-d
      (assert-string= "cd /d \"D:\\work\" && "
                      (parameterize ([windows-shell? #t]) (cd-prefix "D:\\work")))
      (assert-string= "cd '/tmp/x' && "
                      (parameterize ([windows-shell? #f]) (cd-prefix "/tmp/x"))))

    ;; real-path 在 Windows 上不 shell-out(没有 readlink),原样返回
    (real-path-windows-is-identity
      (assert-string= "C:\\x\\y"
                      (parameterize ([windows-shell? #t]) (real-path "C:\\x\\y"))))))
