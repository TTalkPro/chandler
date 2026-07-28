#!chezscheme
;;; tests/chandler/cli-broken-pipe.ss --- broken pipe 判别(D42;来源 bake D74)
;;;
;;; 被测的是 `chandler make -P | head` 这类用法:下游读够就退出,chandler 的
;;; stdout 写失败。修之前的症状是一行假报错 + 退出码 65。
;;;
;;; 三部分,分工明确:
;;;   ① **平台参数化**的文案表 —— 那张表是**兜底**(探针不可用时才生效),但兜底
;;;      同样要验,而且 Windows-only 那半边只能靠 parameterize `windows-shell?`
;;;      在 Linux 上驱动。
;;;   ② **认人** —— D42 相对「只比文案」的实质收紧:确定是别的 fd 就不静默。
;;;      不起子进程,直接造条件对象。
;;;   ③ **端到端** —— 真起 CLI 子进程 + 真管道。夹具是 Scheme 运行时本身
;;;      (`head` 在 Windows 上不存在;bake D70/D72:缺的是命令不是能力)。
;;;
;;; 【MUST】②③ 两组都带**反面**断言。绿色本身不能区分「判别在承重」与
;;; 「判别空转、恰好没触发」—— 这两者在 "N passed" 里长得一模一样。

(library (tests chandler cli-broken-pipe)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler fs)                 ; path-join* / write-text / file-byte-size
          (chandler util)               ; string-contains?
          (only (chandler proc) windows-shell? shell-system shell-quote
                                stdout-pipe-gone?)
          (chandler cli main))          ; broken-pipe? / pipe-phrase-match?

  ;; ── 造一个「写失败」条件对象 ──
  ;; 形状照 Chez 实测的那条:message 带格式指令,irritants = (port 原因串)。
  (define (write-error-on port reason)
    (condition (make-i/o-write-error)
               (make-i/o-port-error port)
               (make-message-condition "failed on ~s: ~(~a~)")
               (make-irritants-condition (list port reason))))

  ;; 大输出 recipe:5000 个长名任务 ⇒ `-P` 打 5000 行 / 约 170KB,
  ;; **远超**管道缓冲(Linux 64KB)。规模要确定 —— 靠「大概够大」会做出随机绿的测试。
  (define (write-big-recipe! dir)
    (let ([p (path-join* dir "chandler-tasks.ss")]
          [op (open-output-string)])
      (do ([i 0 (+ i 1)]) ((= i 5000))
        (fprintf op "(task 'task-with-a-fairly-long-name-~4,'0d (lambda () (void)))~%" i))
      (fprintf op "(default-task 'task-with-a-fairly-long-name-0000)~%")
      (write-text p (get-output-string op))
      p))

  ;; 只读 N 行就退出的下游 —— 即 `head -N`,但用 Scheme 写,两平台都在。
  (define (write-pipe-head! dir)
    (let ([p (path-join* dir "pipe-head.ss")])
      (write-text p
        (string-append
          "(let ([n (string->number (car (command-line-arguments)))])\n"
          "  (let loop ([i 0])\n"
          "    (if (>= i n)\n"
          "        (exit 0)\n"
          "        (let ([l (get-line (current-input-port))])\n"
          "          (if (eof-object? l)\n"
          "              (exit 0)\n"
          "              (begin (display l) (newline) (loop (+ i 1))))))))\n"))
      p))

  (define (rt) (or (test-runtime)
                   (error 'rt "no Scheme runtime found on PATH; the e2e cannot run")))

  ;; 仓库根 —— run-tests.sps 从这里跑。取不到 main.sps 就当场失败,
  ;; 而不是让端到端组静默退化成空转。
  (define (cli-program)
    (let ([p (path-join* (path-join* (path-join* (current-directory) "chandler")
                                     "cli")
                         "main.sps")])
      (unless (file-exists? p)
        (error 'cli-program "chandler/cli/main.sps not found; e2e must run from repo root" p))
      p))

  (define-suite suite

    ;; ══════════════════════════════════════════════════════════════
    ;; ① 兜底文案表(平台参数化)
    ;; ══════════════════════════════════════════════════════════════

    ;; 自证型:句子本身说明对端没了 ⇒ 两个平台都认
    (phrase-self-evident-matches-on-both-platforms
      (for-each
        (lambda (win?)
          (parameterize ([windows-shell? win?])
            (assert-true (pipe-phrase-match? "broken pipe"))
            (assert-true (pipe-phrase-match? "the pipe has been ended"))))
        '(#f #t)))

    ;; 大小写不敏感 —— Chez 给的是 "Broken pipe"(大写 B),而 report-error 的
    ;; `~(~a~)` 会折叠成小写。同一件事两处写法不同,比较前必须降格。
    (phrase-match-is-case-insensitive
      (assert-true (pipe-phrase-match? "Broken pipe"))
      (assert-true (pipe-phrase-match? "BROKEN PIPE")))

    ;; 非自证型(`invalid argument`)【MUST】只在 Windows 生效。
    ;; POSIX 侧放松没有理由 —— 那边 EPIPE 自证,松了会把真实写失败一起吞掉。
    (phrase-windows-only-is-gated
      (parameterize ([windows-shell? #f])
        (assert-false (pipe-phrase-match? "invalid argument")))
      (parameterize ([windows-shell? #t])
        (assert-true (pipe-phrase-match? "invalid argument"))))

    ;; 无关文案两边都不认 —— 免得上面两条靠「什么都返回 #t」蒙混
    (phrase-unrelated-never-matches
      (for-each
        (lambda (win?)
          (parameterize ([windows-shell? win?])
            (assert-false (pipe-phrase-match? "no space left on device"))
            (assert-false (pipe-phrase-match? "permission denied"))))
        '(#f #t)))

    ;; ══════════════════════════════════════════════════════════════
    ;; ② 认人(D42 相对「只比文案」的收紧)
    ;; ══════════════════════════════════════════════════════════════

    ;; **反面**:别的 fd 上的写失败,即使文案撞上表里的句子,也【MUST】不静默。
    ;; 老判别(只比文案)在这条上是红的。
    (non-stdout-port-is-not-silenced
      (let* ([d (mktmp)]
             [p (open-file-output-port (path-join* d "f.bin"))]
             [fd (ignore-errors (port-file-descriptor p))])
        ;; 前置断言:这个 port 必须真能问出 fd,且不是 1。问不出的话
        ;; stdout-error? 会返回 'unknown 退回文案表,本条就验不到想验的东西了。
        (assert-true (and (number? fd) (not (= fd 1))))
        (assert-false (broken-pipe? (write-error-on p "Broken pipe")))
        (close-port p)))

    ;; 不是写错误的一律不静默(判别的第一道闸)
    (non-write-error-is-not-silenced
      (assert-false (broken-pipe? (make-message-condition "broken pipe")))
      (assert-false (broken-pipe?
                      (condition (make-error)
                                 (make-message-condition "boom")
                                 (make-irritants-condition '("broken pipe"))))))

    ;; 探针本身:不接管道时【MUST】答"对端还在"。若它恒答 #t,上面那条
    ;; /dev/full 反面用例与整个判别就都废了。
    (probe-says-peer-alive-when-not-piped
      (let ([ans (stdout-pipe-gone?)])
        ;; 'unknown = 这台机器上 dlopen 不了(静态链接/沙箱),属允许的降级
        (assert-true (or (eq? ans #f) (eq? ans 'unknown)))))

    ;; ══════════════════════════════════════════════════════════════
    ;; ③ 端到端 —— 真 CLI + 真管道
    ;; ══════════════════════════════════════════════════════════════

    ;; 判据用 **stderr 为空**而非退出码:管道里取上游退出码在 cmd 侧要 delayed
    ;; expansion(`%errorlevel%` 解析期就展开,取到旧值),为一条断言不值得。
    ;; 而 chandler 走错误路径时**必定**先 fprintf 到 stderr 再返回非零码
    ;; (cli/main.ss 的 report-error),故 stderr 为空 ⟺ 未走错误路径。
    ;;
    ;; 【MUST】同时断言下游确实收到了 5 行 —— 命令根本没跑起来时 stderr 也是空的,
    ;; 只看 stderr 会让「没跑」和「跑了且没报错」长得一样。
    (truncating-downstream-exits-clean
      (let* ([d (mktmp)]
             [recipe (write-big-recipe! d)]
             [head (write-pipe-head! d)]
             [err (path-join* d "e.err")]
             [out (path-join* d "e.out")]
             [q shell-quote])
        (shell-system
          (string-append
            (q (rt)) " -q --libdirs " (q (current-directory))
            " --program " (q (cli-program)) " make -P -f " (q recipe)
            " 2> " (q err)
            " | " (q (rt)) " -q --script " (q head) " 5"
            " > " (q out)))
        (assert-equal 0 (file-byte-size err))
        (assert-equal 5 (length (read-lines out)))))

    ;; **反面(POSIX 专属)**:真实的写失败【MUST】仍照常报错。
    ;; `/dev/full` 是"可打开但写必失败"的设备 —— poll 的 revents 仍是 4(无 POLLERR),
    ;; 于是探针答"对端还在",错误照报。这条是"不得把真实写失败当成断管道"的实测保证,
    ;; 比比对 "no space left on device" 这句英文强,且不受 locale 影响。
    ;;
    ;; Windows 侧没有等价设备(NUL 写必成功;只读/被独占的文件是在**打开**时失败,
    ;; 另一条路径),故只在 POSIX 跑 —— 按 D41 会被报进跳过清单。
    (real-write-failure-is-still-reported
      (when-posix
        (lambda ()
          (let* ([d (mktmp)]
                 [recipe (write-big-recipe! d)]
                 [err (path-join* d "full.err")]
                 [q shell-quote])
            (let ([code (shell-system
                          (string-append
                            (q (rt)) " -q --libdirs " (q (current-directory))
                            " --program " (q (cli-program)) " make -P -f " (q recipe)
                            " > /dev/full 2> " (q err)))])
              (assert-false (= 0 code))
              (assert-true (string-contains? (read-file-string err) "no space")))))))))
