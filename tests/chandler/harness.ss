#!chezscheme
;;; tests/chandler/harness.ss --- 极简测试框架:define-suite / assert-* / run-suites
;;;
;;; 设计:每个测试库用 (define-suite name (test body ...) ...) 导出一份 suite(纯值,
;;; 不靠实例化副作用注册——空导出库不保证被实例化,故不用全局注册表)。
;;; run-tests.sps 以 prefix import 收齐各 suite,交 run-suites 运行。

(library (tests chandler harness)
  (export define-suite run-suites
          assert-true assert-false assert-equal assert-raises assert-string=
          register-test-tmp! mktmp
          windows-host? when-posix when-windows skip!
          test-runtime run-probe strip-cr)
  (import (chezscheme)
          (chandler fs)
          (chandler layout)           ; windows-mt?
          (chandler proc))            ; which / run-capture:端到端探针

  ;; ══════════════════════════════════════════════════════════════════
  ;; 跳过 —— **必须报出来**
  ;;
  ;; 「这条用例验的是本平台的 shell / 文件系统语义」时跳过另一侧,而不是放宽
  ;; 断言 —— 放宽等于不验。但**静默跳过同样是骗人**:Windows CI 上打一行
  ;; 「593 passed」,读的人没法知道其中 N 条根本没跑。故 run-suites 结尾逐条
  ;; 列出跳过的用例与原因。
  ;;
  ;; 判据与 (chandler proc) 的 windows-shell? 同源(machine-type 以 nt 结尾),
  ;; 但这里**不**用那个 parameter:它被平台参数化测试 parameterize 来驱动另一侧
  ;; 分支,拿它当「我现在在哪」会在那些用例里读到假答案。
  ;;
  ;; 归组之前先找夹具 —— 缺的往往不是**平台能力**,只是某个具体命令/手段
  ;; (bake D72:broken pipe 一度被判为 Windows 不适用,实际缺的只是 `head`)。
  ;; 平台组该尽量小。
  ;; ══════════════════════════════════════════════════════════════════

  (define (windows-host?) (windows-mt? (current-machine-type)))

  (define skipped '())                  ; ((label . name) . reason) …
  (define current-test (make-parameter '(? . ?)))

  (define (skip! reason)
    (set! skipped (cons (cons (current-test) reason) skipped)))

  (define (when-posix proc)
    (if (windows-host?) (skip! "posix-only") (proc)))
  (define (when-windows proc)
    (if (windows-host?) (proc) (skip! "windows-only")))

  ;; 每个测试临时目录登记在此,run-suites 在**每条用例之后**统一清 —— 夹具的 mktmp
  ;; 从前谁造谁清、大多没清,一轮下来 /tmp 攒上万个目录直到 tmpfs 撑满,mktemp 返回
  ;; 空串、测试大面积假失败(2026-07-24 亲历)。清理集中到 harness,夹具只管登记。
  (define test-tmp-dirs '())
  (define (register-test-tmp! dir)
    (when (and (string? dir) (> (string-length dir) 0))
      (set! test-tmp-dirs (cons dir test-tmp-dirs)))
    dir)
  ;; 新建一个临时目录并登记。**不再 shell-out `mktemp -d`** —— 那是 Windows 上
  ;; 没有的程序,而 fs 的 make-temp-dir 是纯 Chez 且失败即抛(先前 mktemp 返回
  ;; 空串时夹具会把内容写进 cwd = 仓库根,污染工作区;现在这条路径不存在了)。
  (define (mktmp) (register-test-tmp! (make-temp-dir)))

  (define (clear-test-tmps!)
    (for-each (lambda (d) (guard (e (#t (void))) (rm-rf d))) test-tmp-dirs)
    (set! test-tmp-dirs '()))

  ;; ══════════════════════════════════════════════════════════════════
  ;; 端到端子进程探针(C9)
  ;;
  ;; 要验的是「引用后的参数**原样进了子进程的 argv**」。先前用 `sh -c` +
  ;; `echo` / `pwd` / `true` / `false` —— 这些在 Windows 上一个都没有;
  ;; 而换成批处理也不行:cmd 的 `%*` 给的是**原始命令行尾部**(我们加的引号
  ;; 还在),`%1` 又会脱一层引号,两者都证明不了 argv 里到底是什么。
  ;;
  ;; 于是探针程序取 **Scheme 运行时本身**:它在两个平台上都按各自的规则
  ;; (Windows 是 MSVCRT,正是 cmd-quote 对着写的那套)解析 argv,而且一定
  ;; 存在 —— 测试套件就跑在它上面。
  ;; ══════════════════════════════════════════════════════════════════

  (define runtime-cache 'unset)
  (define (test-runtime)
    (when (eq? runtime-cache 'unset)
      (set! runtime-cache
        (let loop ([cs (list (getenv "CHANDLER_SCHEME") "scheme" "chez" "petite" "skiff")])
          (cond
            [(null? cs) #f]
            [(and (car cs) (> (string-length (car cs)) 0) (which (car cs)))]
            [else (loop (cdr cs))]))))
    runtime-cache)

  (define probe-source
    (string-append
      "(for-each (lambda (s) (display \"arg[\") (display s) (display \"]\") (newline))\n"
      "          (command-line-arguments))\n"
      "(display \"cwd[\") (display (current-directory)) (display \"]\") (newline)\n"
      "(display \"env[\") (display (or (getenv \"CHANDLER_TEST_VAR\") \"\")) (display \"]\") (newline)\n"
      "(display \"err\" (current-error-port)) (newline (current-error-port))\n"
      "(exit (string->number (or (getenv \"CHANDLER_TEST_CODE\") \"0\")))\n"))

  ;; 用当前运行时跑探针,args 原样透传。opts 同 run-capture((cwd . d) / (env . …))。
  ;; 返回 proc-result;找不到运行时返回 #f(调用方跳过 —— 与其假绿,不如明说)。
  (define (run-probe args opts)
    (let ([rt (test-runtime)])
      (and rt
           (let ([script (path-join* (mktmp) "probe.ss")])
             (write-text script probe-source)
             (run-capture rt (append (list "-q" "--script" script) args) opts)))))

  ;; Windows 上文本端口按 native eol 写出 → 断言前统一去掉 CR。
  ;; (被测的是参数传递,不是换行风格;换行风格由 C4 的字节级用例守。)
  (define (strip-cr s)
    (list->string (filter (lambda (c) (not (char=? c #\return))) (string->list s))))

  ;; (define-suite name (test-name body ...) ...) → name 绑定为 ((sym . thunk) ...)
  (define-syntax define-suite
    (syntax-rules ()
      [(_ suite-name (test-name body ...) ...)
       (define suite-name
         (list (cons 'test-name (lambda () body ...)) ...))]))

  (define (fail msg . irritants)
    (raise (condition (make-error)
                      (make-message-condition msg)
                      (make-irritants-condition irritants))))

  (define (assert-true x)
    (unless x (fail "assert-true failed" x)))

  (define (assert-false x)
    (when x (fail "assert-false failed" x)))

  (define (assert-equal expected actual)
    (unless (equal? expected actual)
      (fail "assert-equal failed" 'expected expected 'actual actual)))

  (define (assert-string= expected actual)
    (unless (and (string? actual) (string=? expected actual))
      (fail "assert-string= failed" 'expected expected 'actual actual)))

  ;; (assert-raises thunk) —— thunk 必须抛异常,否则失败
  ;; 实现注:set! flag + call/cc 逃逸;flag 检查与 fail 必须在 handler 作用域**之外**,
  ;; 否则 fail 自己 raise 的 condition 会被同一个 handler 捕获 → 不抛也 pass(假绿)。
  (define (assert-raises thunk)
    (let ([raised? #f])
      (call/cc
        (lambda (k)
          (with-exception-handler
            (lambda (e) (set! raised? #t) (k #t))
            (lambda () (thunk) (k #f)))))
      (unless raised?
        (fail "assert-raises: expected exception, none raised"))))

  ;; suites = ((label . ((test-name . thunk) ...)) ...);返回是否全绿
  (define (run-suites suites)
    (let ([pass 0] [failn 0])
      (for-each
        (lambda (labeled)
          (let ([label (car labeled)] [suite (cdr labeled)])
            (for-each
              (lambda (t)
                (let ([name (car t)] [thunk (cdr t)])
                  (call/cc
                    (lambda (k)
                      (with-exception-handler
                        (lambda (e)
                          (set! failn (+ failn 1))
                          (printf "  FAIL ~a / ~a: " label name)
                          (show-condition e)
                          (newline)
                          (k #f))
                        (lambda ()
                          ;; 用例名进 parameter,好让 skip! 报得出是谁跳了
                          (parameterize ([current-test (cons label name)])
                            (thunk))
                          (set! pass (+ pass 1))
                          (k #t)))))
                  ;; 无论过失,清掉这条用例造的临时目录(k 逃逸回到此处后仍会跑)。
                  (clear-test-tmps!)))
              suite)))
        suites)
      (report-skips)
      (printf "~%tests: ~a passed, ~a failed, ~a skipped~%" pass failn (length skipped))
      (= failn 0)))

  ;; 跳过的逐条列出来。**没有这段,「N passed」在另一个平台上就是个假象** ——
  ;; 一条用例被平台门挡掉与它跑过并通过,在汇总数字上长得一模一样。
  ;; 按原因分组,组内保持声明顺序。
  (define (report-skips)
    (unless (null? skipped)
      (let ([items (reverse skipped)])
        (printf "~%skipped ~a test(s) on ~a:~%"
                (length items)
                (if (windows-host?) "windows" "posix"))
        (for-each
          (lambda (reason)
            (let ([of-reason (filter (lambda (s) (string=? reason (cdr s))) items)])
              (unless (null? of-reason)
                (printf "  [~a]~%" reason)
                (for-each (lambda (s)
                            (printf "    ~a / ~a~%" (car (car s)) (cdr (car s))))
                          of-reason))))
          (reasons-of items)))))

  ;; 出现过的 reason,按首次出现顺序去重
  (define (reasons-of items)
    (let loop ([xs items] [acc '()])
      (cond [(null? xs) (reverse acc)]
            [(member (cdr (car xs)) acc) (loop (cdr xs) acc)]
            [else (loop (cdr xs) (cons (cdr (car xs)) acc))])))

  (define (show-condition e)
    (cond
      [(condition? e)
       (when (message-condition? e) (display (condition-message e)))
       (when (irritants-condition? e)
         (for-each (lambda (x) (display " ") (write x)) (condition-irritants e)))]
      [else (write e)])))
