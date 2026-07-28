#!chezscheme
;;; chandler/proc.ss --- 子进程封装(git 等调用复用)
;;;
;;; 约定:参数以**列表**传入并逐个引用(不拼裸串),避免 URL/路径里的元字符注入。
;;; 用 `system` + 临时文件重定向捕获 stdout/stderr 与**退出码**(open-process-ports
;;; 拿不到退出码;system 返回码可靠)。
;;;
;;; ══════════════════════════════════════════════════════════════════════
;;; 为什么是「把 shell 的引用规则做对」而不是「绕开 shell」(D33)
;;;
;;; stock Chez **没有** argv 数组式的进程创建。实测(Chez 10.4.1):
;;;
;;;     (open-process-ports "echo a && echo b" …)   ; → 依次读出 "a" "b"
;;;
;;; 即 `open-process-ports` 与 `system` 一样只收**一条 shell 命令串**,`&&` 被
;;; shell 解释了。绕不开,只能把引用做对。
;;;
;;; 而 Windows 上 Chez 的 `system` 走 `%COMSPEC%`,也就是 **cmd.exe,不是
;;; PowerShell** —— 开发机装没装 PowerShell 与本文件一行代码都无关。
;;; ══════════════════════════════════════════════════════════════════════

(library (chandler proc)
  (export run-capture run-check run-status run-foreground shell-quote env-prefix
           proc-result-code proc-result-out proc-result-err
           which real-path
           ;; 平台开关 + 两侧引用实现:导出供**平台参数化测试**。
           ;; 生成的命令串是纯字符串逻辑,值得逐字断言;而 CI 跑在 Linux 上,
           ;; 不参数化就等于 Windows 这半边代码从来没被执行过。
           windows-shell? sh-quote cmd-quote cd-prefix)
  (import (chezscheme)
          (chandler util)
          (chandler layout)      ; windows-mt?(layout 不依赖 proc,无环)
          (chandler fs))

  (define-record-type proc-result
    (fields code out err))

  ;; ── 平台判别 ──
  ;; 默认取当前 machine-type;做成 parameter 只为让测试能驱动另一侧分支。
  (define windows-shell?
    (make-parameter (windows-mt? (current-machine-type))))

  ;; ══════════════════════════════════════════════════════════════════
  ;; §1 参数引用
  ;; ══════════════════════════════════════════════════════════════════

  ;; POSIX:单引号包裹,内部的 ' → '\''。单引号内 sh 不做任何解释,
  ;; 故 $ ` \ " 空格 换行 全部字面通过。
  (define (sh-quote s)
    (let ([op (open-output-string)])
      (display #\' op)
      (string-for-each
        (lambda (c) (if (char=? c #\') (display "'\\''" op) (display c op)))
        s)
      (display #\' op)
      (get-output-string op)))

  ;; Windows(cmd.exe)。**两层**,必须分开想:
  ;;
  ;;   ① 目标程序的 argv 解析(MSVCRT 规则):整个参数用 `"` 包;`"` 之前的连续
  ;;      反斜杠要加倍;**结尾**的连续反斜杠也要加倍(否则会转义掉收尾的引号)。
  ;;   ② cmd.exe 自己的命令行解析:`& | < > ^ ( )` 在**引号外**特殊。
  ;;      既然整个参数都在引号内,这一层自动安全。
  ;;
  ;; 于是「包引号 + MSVCRT 反斜杠规则」同时满足两层 —— 空格、反斜杠、cmd 元字符
  ;; 全部正确通过。剩下的洞由 assert-cmd-safe! 拦(见下)。
  (define (cmd-quote s)
    (assert-cmd-safe! s)
    (let ([op (open-output-string)]
          [n (string-length s)])
      (display #\" op)
      (let loop ([i 0] [pending 0])       ; pending = 尚未输出的连续反斜杠数
        (if (= i n)
            ;; 收尾:结尾的反斜杠加倍,否则最后那个 \ 会转义掉我们的收尾引号
            (do ([k 0 (+ k 1)]) ((= k (* 2 pending))) (display #\\ op))
            (let ([c (string-ref s i)])
              (if (char=? c #\\)
                  (loop (+ i 1) (+ pending 1))
                  ;; 普通字符前的反斜杠原样输出(MSVCRT 只在 `"` 前才做加倍)
                  (begin
                    (do ([k 0 (+ k 1)]) ((= k pending)) (display #\\ op))
                    (display c op)
                    (loop (+ i 1) 0))))))
      (display #\" op)
      (get-output-string op)))

  ;; cmd 下**无法**正确传递的两类字符 —— 与其悄悄传错,不如当场说清。
  ;;
  ;;   • `"`  —— MSVCRT 那层要写成 `\"`,但 cmd **不认识反斜杠转义**,它看到的是一个
  ;;             裸引号,引号配对就此错位:后面的 `& | > ^` 全部落到引号外,变成
  ;;             cmd 的控制字符。那不只是「路径传错」,是**命令注入面**。
  ;;   • 换行 / 回车 —— cmd 按行解析,嵌进去等于凭空多一条命令。
  ;;
  ;; chandler 传的是文件路径、git URL、ref、cmake define,没有一类会合法含这些。
  ;; 硬错的诊断远好过「命令跑了,但跑的不是你写的那条」。
  ;;
  ;; **`%` 刻意不在此列**:cmd 只展开**已定义**的 `%VAR%`,而 URL 编码(`%20`)
  ;; 这类在实践中随处可见,一律拒会造出大量假阳性。真撞上同名变量时,git 会拿着
  ;; 一个变形的 URL 明确报错,不是静默走错。这条限制记在 designs/14 §3.3。
  (define (assert-cmd-safe! s)
    (let ([bad (find-char s (lambda (c)
                              (or (char=? c #\")
                                  (char=? c #\newline)
                                  (char=? c #\return))))])
      (when bad
        (error 'shell-quote
               (format "cannot pass this argument through cmd.exe safely: ~s~%  (a literal ~s breaks quote pairing and turns the rest of the line into cmd control characters)"
                       s (string bad))))))

  (define (find-char s pred)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (cond [(>= i n) #f]
              [(pred (string-ref s i)) (string-ref s i)]
              [else (loop (+ i 1))]))))

  ;; 全仓唯一的「引用一个参数」入口。
  (define (shell-quote s)
    (if (windows-shell?) (cmd-quote s) (sh-quote s)))

  (define (quote-command prog args)
    (string-join (map shell-quote (cons prog args)) " "))

  ;; ══════════════════════════════════════════════════════════════════
  ;; §2 环境注入 / 工作目录前缀
  ;; ══════════════════════════════════════════════════════════════════

  ;; ("K" . "v") 表 → 命令前缀。Chez 的 `system` 只收一条命令串,故环境靠前缀注入。
  ;; **值为 #f 的项跳过** —— 调用方常把「可选环境变量」直接写成
  ;; (cons "K" 或许是 #f 的东西)(native-build 的 CHEZ_INCLUDE 正是如此)。
  ;;
  ;; POSIX:`K='v' cmd`(sh 的变量赋值前缀)。
  ;; cmd:  `set "K=v" && cmd` —— cmd **完全不认** `K=v cmd` 这种语法,会把整串当成
  ;;       要执行的程序名。`set "K=v"` 的引号形还顺带避免了值尾随空格的老坑。
  ;;       每次 `system` 都是一个新的 cmd 进程,故不必担心污染后续调用。
  (define (env-prefix env)
    (if (windows-shell?)
        (fold-left
          (lambda (acc kv)
            (if (cdr kv)
                (string-append acc "set "
                               (cmd-quote (string-append (car kv) "=" (cdr kv)))
                               " && ")
                acc))
          "" env)
        (fold-left
          (lambda (acc kv)
            (if (cdr kv)
                (string-append acc (car kv) "=" (sh-quote (cdr kv)) " ")
                acc))
          "" env)))

  ;; 切工作目录的前缀。**Windows 上 `/d` 不能少** —— 不带它时 `cd` 遇到另一个盘符
  ;; 会静默不生效(只改那个盘各自记的当前目录,不切过去),于是命令在错误的目录里
  ;; 跑起来,而且不报错。
  (define (cd-prefix dir)
    (if (windows-shell?)
        (string-append "cd /d " (cmd-quote dir) " && ")
        (string-append "cd " (sh-quote dir) " && ")))

  ;; 唯一临时目录:`make-temp-dir` 现住 (chandler fs) —— 它不起子进程,
  ;; 而测试 harness 也要用它(去掉 `mktemp -d` 这个 shell 依赖),
  ;; 让 harness 为了 mkdir 去 import 整个 proc 没有道理。

  ;; ══════════════════════════════════════════════════════════════════
  ;; §4 主入口
  ;; ══════════════════════════════════════════════════════════════════

  ;; run-capture:(values code stdout stderr) 经 proc-result;
  ;; opts: (cwd . dir) (env . ((k.v)…)) (stdin . 'null)
  ;;
  ;; `stdin` 收 `'null`(接到空设备)或一个路径串。**空设备名两平台不同**
  ;; (`/dev/null` vs `NUL`),故由这里统一给出 —— 调用方不再自己拼
  ;; `sh -c "… < /dev/null"`(pack 的两个版本探针先前正是这么写的,C9)。
  ;; 探针类命令用它避免「对方想读 stdin 于是挂住」。
  (define run-capture
    (case-lambda
      [(prog args) (run-capture prog args '())]
      [(prog args opts)
       (let* ([dir (make-temp-dir)]
              [outf (path-join* dir "out")]
              [errf (path-join* dir "err")]
              [cwd (alist-ref opts 'cwd)]
              [env (alist-ref opts 'env)]
              [base0 (quote-command prog args)]
              [in (alist-ref opts 'stdin)]
              [base (if in
                        (string-append base0 " <"
                                       (shell-quote (if (eq? in 'null) (null-device) in)))
                        base0)]
              [with-redir (string-append base " >" (shell-quote outf) " 2>" (shell-quote errf))]
              [with-cd (if cwd (string-append (cd-prefix cwd) with-redir) with-redir)]
              [with-env (if env (string-append (env-prefix env) with-cd) with-cd)])
         (let ([code (system with-env)])
           (let ([out (read-file-string outf)] [err (read-file-string errf)])
             (rm-rf dir)
             (make-proc-result code out err))))]))

  ;; run-check:成功返回 stdout;失败抛(带 prog/args/退出码/stderr 上下文)
  (define run-check
    (case-lambda
      [(prog args) (run-check prog args '())]
      [(prog args opts)
       (let ([r (run-capture prog args opts)])
         (if (= 0 (proc-result-code r))
             (proc-result-out r)
             (error 'run-check
                    (format "command failed (exit ~a): ~a ~a~%stderr: ~a"
                            (proc-result-code r) prog args (proc-result-err r)))))]))

  ;; run-status:只要退出码(用于 has-rev? 等布尔探测)
  (define run-status
    (case-lambda
      [(prog args) (run-status prog args '())]
      [(prog args opts) (proc-result-code (run-capture prog args opts))]))

  ;; run-foreground:继承 stdio 跑命令(run/exec 用),返回退出码。不捕获输出。
  (define run-foreground
    (case-lambda
      [(prog args) (run-foreground prog args '())]
      [(prog args opts)
       (let* ([cwd (alist-ref opts 'cwd)]
              [env (alist-ref opts 'env)]
              [base (quote-command prog args)]
              [with-cd (if cwd (string-append (cd-prefix cwd) base) base)]
              [full (if env (string-append (env-prefix env) with-cd) with-cd)])
         (system full))]))

  ;; ══════════════════════════════════════════════════════════════════
  ;; §5 PATH 查找 / 符号链接解引用
  ;; ══════════════════════════════════════════════════════════════════

  ;; which:在 PATH 上找程序,返回绝对路径或 #f。
  ;; POSIX 走 `sh -c "command -v"`;Windows 走 `where.exe`(Win7+ 自带)。
  ;; `where` 可能输出多行(同名程序在多个 PATH 条目下),取**首行** = PATH 序第一个,
  ;; 与 `command -v` 的语义对齐。
  (define (which prog)
    (let ([r (if (windows-shell?)
                 (run-capture "where" (list prog))
                 (run-capture "sh" (list "-c" (string-append "command -v " (sh-quote prog)))))])
      (and (= 0 (proc-result-code r))
           (let ([s (string-trim (first-line (proc-result-out r)))])
             (and (> (string-length s) 0) s)))))

  (define (first-line s)
    (let ([i (char-index s #\newline)])
      (if i (substring s 0 i) s)))

  ;; real-path:解引用符号链接;失败返回原路径。
  ;; Windows 上**直接返回原路径** —— 没有 readlink,而三个调用点
  ;; (pack/runtime.ss:22,27,50)只是为了定位宿主 skiff/scheme 好随包捆绑,
  ;; 那条路径上不涉及符号链接。
  (define (real-path p)
    (if (windows-shell?)
        p
        (let ([r (run-capture "sh" (list "-c" (string-append "readlink -f " (sh-quote p))))])
          (if (= 0 (proc-result-code r)) (string-trim (proc-result-out r)) p)))))
