#!chezscheme
;;; tests/chandler/proc.ss --- (chandler proc) 测试
;;;
;;; 三部分:
;;;   ① **跨平台**端到端 —— 真起子进程,验证引用后的参数原样进了 argv。探针程序
;;;      是 Scheme 运行时本身(harness 的 run-probe):`sh` / `echo` / `pwd` /
;;;      `true` 在 Windows 上都不存在,而批处理看不见真正的 argv(C9)。
;;;   ② POSIX 专属端到端 —— 那些**只**在 /bin/sh 语义下才有意义的断言
;;;      (单引号里 `$` `` ` `` `"` 都不展开)。
;;;   ③ **平台参数化**的串生成 —— `windows-shell?` 是个 parameter,于是 Windows
;;;      那半边(cmd 引用 / `set "K=v" &&` / `cd /d`)在 Linux 上就能逐字断言。
;;;      不这么做,那半边代码在 CI 里等于从来没被执行过(D33,designs/14 §5)。

(library (tests chandler proc)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler fs)               ; path-join* / write-text / normalize-seps / base-name
          (chandler util)             ; string-contains?
          (chandler proc))

  ;; 探针跑不起来(PATH 上一个 Scheme 运行时都找不到)时**当场失败**,
  ;; 而不是让整组端到端用例静默变成空转 —— 那正是 C9 要消灭的东西。
  (define (probe args opts)
    (or (run-probe args opts)
        (error 'probe "no Scheme runtime found on PATH; the e2e probe cannot run")))

  (define (probe-out r) (strip-cr (proc-result-out r)))

  (define (rt) (or (test-runtime)
                   (error 'rt "no Scheme runtime found on PATH; the e2e probe cannot run")))

  ;; ── `cmd /c` 的引号处理,**独立实现一遍**(D69 的静态验法)──
  ;;
  ;; 照 `cmd /?` 原文:
  ;;   1. 「恰好两个引号 + 中间无 & < > ( ) @ ^ | + 中间有空白 + 中间那串是一个
  ;;      可执行文件名」⇒ 引号原样保留;
  ;;   2. 否则,首字符是引号 ⇒ 剥掉第一个引号与最后一个引号,保留最后一个引号
  ;;      之后的文本。
  ;;
  ;; 「是不是可执行文件」在测试里判不了(要查文件系统),故这里**只实现规则 2**,
  ;; 并由 cmd-outer-quote-makes-behaviour-deterministic 单独钉住「包完之后引号数
  ;; 恒 ≥ 4 ⇒ 规则 1 永不成立」—— 于是规则 1 判不了这件事不影响结论。
  ;; 刻意与被测实现**反向**写(它加,这里减),两边同时写错成互补的错的概率
  ;; 远低于单边写错。
  (define (cmd-c-strip line)
    (let ([n (string-length line)])
      (if (or (= n 0) (not (char=? #\" (string-ref line 0))))
          line
          (let ([last (last-index-of line #\")])
            (if (<= last 0)
                line
                (string-append (substring line 1 last)
                               (substring line (+ last 1) n)))))))

  (define (last-index-of s c)
    (let loop ([i (- (string-length s) 1)])
      (cond [(< i 0) -1]
            [(char=? c (string-ref s i)) i]
            [else (loop (- i 1))])))

  (define (count-char s c)
    (let loop ([i 0] [n 0])
      (if (= i (string-length s))
          n
          (loop (+ i 1) (if (char=? c (string-ref s i)) (+ n 1) n)))))

  (define-suite suite
    (quote-plain
      (assert-string= "'abc'" (shell-quote "abc")))

    (quote-with-quote
      (assert-string= "'a'\\''b'" (shell-quote "a'b")))

    ;; ══════════════════════════════════════════════════════════════
    ;; ① 跨平台端到端(探针 = Scheme 运行时,两平台都跑)
    ;; ══════════════════════════════════════════════════════════════

    ;; 引用后的参数**逐个**原样进 argv:空格不拆词、shell 元字符不展开。
    ;; `"` 不在此列 —— cmd 侧无法安全传递,shell-quote 对它硬错(见下面
    ;; quote-rejects-embedded-quote-on-windows),故它只出现在 POSIX 专属用例里。
    (args-arrive-verbatim
      (let* ([args (list "a b" "$HOME" "`id`" "x&y" "50%" "a\\b\\")]
             [want (apply string-append
                          (map (lambda (a) (string-append "arg[" a "]\n")) args))]
             [r (probe args '())])
        (assert-equal 0 (proc-result-code r))
        ;; 探针先逐行打 argv,再打 cwd/env —— 故比较前缀
        (assert-string= want (substring (probe-out r) 0 (string-length want)))))

    (env-prefix-quotes-and-skips-false
      ;; 值经 shell-quote,故含空格/元字符的值不会被 sh 拆开或展开;
      ;; 值为 #f 的项整条跳过(调用方把可选环境变量直接写成 (cons "K" #f))。
      (assert-string= "A='x y' " (env-prefix '(("A" . "x y"))))
      (assert-string= "A='$HOME' " (env-prefix '(("A" . "$HOME"))))
      (assert-string= "B='2' " (env-prefix '(("A" . #f) ("B" . "2")))))

    ;; 环境注入端到端:含空格与元字符的值原样抵达子进程(POSIX 的 `K=v cmd`
    ;; 前缀与 Windows 的 `set "K=v" &&` 各走各的分支,断言同一条)
    (env-option
      (let ([r (probe '() '((env . (("CHANDLER_TEST_VAR" . "a b $HOME `id` 50%")))))])
        (assert-equal 0 (proc-result-code r))
        (assert-true (string-contains? (probe-out r) "env[a b $HOME `id` 50%]"))))

    ;; cwd 端到端:进程真的在指定目录里跑起来(Windows 上靠 `cd /d`,
    ;; 漏了 `/d` 会静默不切过去 —— 那正是这条要挡的)
    (cwd-option
      (let* ([d (mktmp)]
             [r (probe '() (list (cons 'cwd d)))])
        (assert-equal 0 (proc-result-code r))
        ;; 比较前归一分隔符:Windows 上 current-directory 返回 `\` 形
        (assert-true (string-contains? (normalize-seps (probe-out r))
                                       (normalize-seps (base-name d))))))

    ;; stderr 与退出码分别捕获(重定向 `2>` 两侧写法一致,但经过的 shell 不同)
    (capture-stderr-and-code
      (let ([r (probe '() '((env . (("CHANDLER_TEST_CODE" . "3")))))])
        (assert-equal 3 (proc-result-code r))
        (assert-string= "err\n" (strip-cr (proc-result-err r)))))

    ;; run-check / run-status 的成败语义(先前借 `true` / `false` / `echo`,
    ;; Windows 上三个都没有)
    (run-check-ok
      (let ([script (path-join* (mktmp) "ok.ss")])
        (write-text script "(display \"ok\")(newline)\n")
        (assert-string= "ok\n" (strip-cr (run-check (rt) (list "-q" "--script" script))))))

    (run-check-fails
      (let ([script (path-join* (mktmp) "bad.ss")])
        (write-text script "(exit 1)\n")
        (assert-raises (lambda () (run-check (rt) (list "-q" "--script" script))))))

    (run-status-bool
      (let ([ok (path-join* (mktmp) "ok.ss")]
            [bad (path-join* (mktmp) "bad.ss")])
        (write-text ok "(exit 0)\n")
        (write-text bad "(exit 1)\n")
        (assert-equal 0 (run-status (rt) (list "-q" "--script" ok)))
        (assert-equal 1 (run-status (rt) (list "-q" "--script" bad)))))

    ;; stdin 重定向真的接上了:给一个已知内容的文件,子进程必须读到它。
    ;; 断言用**文件**而不是空设备 —— 空设备那条若坏掉,子进程会挂住等输入
    ;; 而不是给出错答案,那样测试就成了「挂起」而非「变红」。空设备名本身
    ;; (`/dev/null` / `NUL`)由 fs 的 null-device-is-platform-native 守。
    (stdin-redirects-from-file
      (let* ([d (mktmp)]
             [script (path-join* d "readin.ss")]
             [input (path-join* d "in.txt")])
        (write-text script "(display (get-line (current-input-port)))\n")
        (write-text input "from-file\n")
        (let ([r (run-capture (rt) (list "-q" "--script" script) (list (cons 'stdin input)))])
          (assert-equal 0 (proc-result-code r))
          (assert-string= "from-file" (strip-cr (proc-result-out r))))))

    ;; `'null` 解析成本平台的空设备(而不是被当成一个叫 "null" 的文件名)
    (stdin-null-uses-platform-device
      (let* ([d (mktmp)]
             [script (path-join* d "readin.ss")])
        (write-text script "(display (if (eof-object? (read-char)) \"eof\" \"data\"))\n")
        (let ([r (run-capture (rt) (list "-q" "--script" script) '((stdin . null)))])
          (assert-equal 0 (proc-result-code r))
          (assert-string= "eof" (strip-cr (proc-result-out r)))
          ;; 没有在 cwd 里造出一个叫 "null" 的文件(拼错设备名的典型症状)
          (assert-false (file-exists? "null")))))

    ;; ══════════════════════════════════════════════════════════════
    ;; ② POSIX 专属端到端(断言的是 /bin/sh 的语义,换个 shell 就没意义)
    ;; ══════════════════════════════════════════════════════════════

    (env-prefix-round-trips-through-sh
      ;; 单引号内 sh 不做任何解释 —— `$` `` ` `` `"` 全部字面通过。
      ;; 字面 `"` 只有这一侧测得了:cmd 侧根本不接受(shell-quote 硬错)。
      (when-posix (lambda ()
        (let ([r (run-capture "sh" '("-c" "printf %s \"$V\"")
                              '((env . (("V" . "a b $HOME `id` \"q\"")))))])
          (assert-equal 0 (proc-result-code r))
          (assert-string= "a b $HOME `id` \"q\"" (proc-result-out r))))))

    (quote-metachars-through-sh
      ;; 空格与 $ 经 sh-quote 后原样,不被 /bin/sh 拆词或展开
      (when-posix (lambda ()
        (let ([r (run-capture "echo" (list "a b" "$HOME"))])
          (assert-equal 0 (proc-result-code r))
          (assert-string= "a b $HOME\n" (proc-result-out r))))))

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
                      (parameterize ([windows-shell? #t]) (real-path "C:\\x\\y"))))

    ;; ══════════════════════════════════════════════════════════════
    ;; `cmd /c` 的外层引号剥离(解析的**第三层**,D68)
    ;;
    ;; 验法照 designs/14 §3.4 的两条:这里是**静态往返** —— 把 cmd 的剥离规则
    ;; 独立实现一遍(`cmd-c-strip`,下方),验证「我们包的」被「它剥的」正好抵消。
    ;; 平台无关,Linux 上就能跑。动态那半(真过一遍 cmd)只有 Windows CI 给得了。
    ;;
    ;; 教训写在这:C5 只对 MSVCRT 那层做过交叉验证,漏了这一层,于是
    ;; **所有带参数、无 cwd/env 前缀的子进程调用在 Windows 上都是坏的**
    ;; ——「往返验证能证明转义符合我理解的规则,证明不了我理解的规则就是全部
    ;; 的规则」(bake D69)。
    ;; ══════════════════════════════════════════════════════════════

    ;; 我们生成的命令行,经 cmd 剥离后必须与包裹前逐字相同
    (cmd-outer-quote-round-trips-through-cmd-c
      (for-each
        (lambda (line)
          (assert-string= line (cmd-c-strip (cmd-outer-quote line))))
        (list
          ;; 无 cwd/env 前缀:以引号开头 —— 就是先前坏掉的那一类
          "\"where\" \"git\""
          "\"git\" \"-C\" \"C:\\proj\" \"rev-parse\" \"HEAD\""
          ;; run-capture 的最终形:后面接着重定向(包裹必须作用在整行上)
          "\"scheme\" \"-q\" \"--script\" \"C:\\T\\p.ss\" >\"C:\\T\\out\" 2>\"C:\\T\\err\""
          ;; 只有程序名的单 token
          "\"C:\\bin\\chandler.cmd\""
          ;; 含空格的程序名(cmd 的「保留」特例本来会命中,包完之后一律走剥离)
          "\"C:\\Program Files\\p.exe\" \"--version\"")))

    ;; 不以引号开头的行**不包** —— 那类根本不触发剥离规则,包了反而多一层改写
    (cmd-outer-quote-leaves-unquoted-lines-alone
      (for-each
        (lambda (line)
          (assert-string= line (cmd-outer-quote line))
          (assert-string= line (cmd-c-strip line)))
        (list "cd /d \"D:\\w\" && \"git\" \"status\""
              "set \"K=v\" && \"git\" \"status\""
              "where git"
              "")))

    ;; 包完之后引号数恒 ≥ 4 ⇒ cmd 的「恰好两个引号」保留特例**永不成立**,
    ;; 行为因此是确定的,不依赖「中间那串是不是一个可执行文件」这种运行期判断。
    (cmd-outer-quote-makes-behaviour-deterministic
      (for-each
        (lambda (line)
          (assert-true (>= (count-char (cmd-outer-quote line) #\") 4)))
        (list "\"C:\\bin\\p.exe\""
              "\"C:\\Program Files\\p.exe\"")))

    ;; POSIX 侧一概不动
    (shell-command-line-is-identity-on-posix
      (assert-string= "'git' 'status'"
                      (parameterize ([windows-shell? #f])
                        (shell-command-line "'git' 'status'"))))))
