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
           windows-shell? sh-quote cmd-quote cd-prefix
           ;; 全仓唯一的 system 出口 + `cmd /c` 外层引号(D68)。
           ;; cmd-outer-quote 是纯函数,导出供往返验证(designs/14 §3.4)。
           shell-system shell-command-line cmd-outer-quote
           ;; §FFI:全仓唯一碰 FFI 的地方(D42/bake D74)。cli 判 broken pipe 时用。
           stdout-pipe-gone?)
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
  ;; §1b `cmd /c` 的外层引号 —— Windows 上解析的**第三层**
  ;;
  ;; §1 处理的是后两层(cmd 的元字符扫描 + 被调程序的 MSVCRT argv 解析)。
  ;; 但在它们之前还有一层:Chez 的 `system` 在 Windows 上走 `%COMSPEC%`,
  ;; 即 `cmd /c <命令行>`,而 **`cmd /c` 自己先对引号动一次手**(`cmd /?` 有载):
  ;;
  ;;   1. 若同时满足「恰好两个引号 + 中间无 `& < > ( ) @ ^ |` + 中间有空白
  ;;      + 中间那串是一个可执行文件名」,引号原样保留;
  ;;   2. 否则:**若首字符是引号,剥掉第一个引号与最后一个引号**,
  ;;      保留最后一个引号之后的文本,剩下的才交给解析器。
  ;;
  ;; 我们生成的命令行必然以引号开头(程序名被 cmd-quote 包了),参数一多就有
  ;; 四个以上引号 —— 条件 1 永远不成立,于是必然踩中条件 2:
  ;;
  ;;   生成  "where" "git" >"…\out" 2>"…\err"
  ;;   剥后  where" "git" >"…\out" 2>"…\err
  ;;   cmd 把 `where" "git"` 整个当命令名 → is not recognized
  ;;
  ;; 对策是**多包一层**:剥掉的正好是我们多加的那对,内层原封不动送进解析器。
  ;; 且包完之后引号数恒 ≥ 4,条件 1 再也不可能被触发 —— 行为是确定的,
  ;; 不依赖「中间那串是不是可执行文件」这种运行期判断。
  ;;
  ;; **只在首字符是引号时包**:不以引号开头的命令行(带 `cd /d …` 或
  ;; `set "K=v" …` 前缀的那些)根本不触发该规则,无差别包裹只会平添一层改写。
  ;;
  ;; **【必须作用在含重定向的最终整行上】**:`run-capture` 会在后面接
  ;; ` >"out" 2>"err"`。只包参数段的话,「最后一个引号」变成重定向路径的收尾
  ;; 引号,剥掉它反而把路径拆坏。所以全仓的 `system` 出口收敛成下面一个
  ;; `shell-system`,不允许各处直接调 `system`。
  ;;
  ;; 来源:这一层不是推出来的,是 bake 在真 Windows 上撞出来的(bake TASK.md
  ;; D68)。chandler 的 C5 只考虑了两层 —— 教训见 designs/14 §3.4。
  ;; ══════════════════════════════════════════════════════════════════

  ;; 纯函数,与当前平台无关(好让 POSIX 机器也能对这一支做往返验证)。
  (define (cmd-outer-quote line)
    (if (and (> (string-length line) 0) (char=? #\" (string-ref line 0)))
        (string-append "\"" line "\"")
        line))

  (define (shell-command-line line)
    (if (windows-shell?) (cmd-outer-quote line) line))

  ;; **全仓唯一的 `system` 出口。** 直接调 `system` 会绕过上面那层。
  (define (shell-system line) (system (shell-command-line line)))

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
         (let ([code (shell-system with-env)])
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
         (shell-system full))]))

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
          (if (= 0 (proc-result-code r)) (string-trim (proc-result-out r)) p))))

  ;; ══════════════════════════════════════════════════════════════════
  ;; §FFI —— 唯一一件必须问操作系统的事:stdout 的对端还在吗(D42)
  ;;
  ;; 【MUST】全仓**只有这一节**碰 FFI。放在 proc 而不是 util,是因为 designs/14 §5
  ;; 已把 proc 定为平台分派层,而 util 是纯字符串/列表助手。
  ;;
  ;; 为什么需要它:`chandler make -P | head` 这类用法里,下游读够就退出,chandler
  ;; 的 stdout 写失败 ⇒ 冒出一行假报错 + 退出码 65。根因在下面一层:Chez 把
  ;; SIGPIPE 设成 SIG_IGN(于是 EPIPE 变成异常而不是静默终止),而 fd port 又把
  ;; errno 丢了、只留 strerror 文本 —— 判别若只比文案,POSIX 上分不开 EPIPE 与
  ;; ENOSPC,Windows 上更是连管道措辞都看不到(MSVCRT 的 _dosmaperr 没收录
  ;; ERROR_BROKEN_PIPE 109,落到默认 EINVAL ⇒ "invalid argument")。
  ;; 所以判别改为**问 OS**,文案表降级为兜底。来源:bake D74(两平台实测)。
  ;;
  ;; 两平台问法不同,**不是偷懒,是 Windows 没有对应物**:
  ;;   POSIX  : poll(fd 1, POLLOUT),revents 含 POLLERR/POLLHUP ⇒ 对端没了。精确。
  ;;            bake 实测(ta6le):管道断 12(POLLOUT|POLLERR)、普通文件 4、
  ;;            控制台 4、**/dev/full 4 且确实抛 ENOSPC** —— 末一条是"真实写失败
  ;;            不得被当成断管道"的实测保证,且不受 locale 影响。
  ;;   Windows: GetFileType(GetStdHandle(-11)) == FILE_TYPE_PIPE(3)。只回答
  ;;            "是不是管道" —— Windows 没有可用于管道的 poll(WSAPoll 只吃 socket,
  ;;            PeekNamedPipe 只能用在读端,而我们手里是写端)。够用的理由:
  ;;            管道上的写不可能是 ENOSPC。bake 实测(a6nt):管道 3、普通文件 1、
  ;;            控制台 2 —— ① 与 ②③ 分得开,判据成立。
  ;;
  ;; 【MUST】建不起来(静态链接、pb 后端、沙箱挡 dlopen)时【MUST】降级为
  ;; 'unknown,调用方退回文案表 —— 降级后的行为 = 引入 FFI 之前的行为,不得更差。
  ;; 惰性:首次用到才建,建一次记住(**失败也记住**,不反复 dlopen)。正常路径上
  ;; 一次 dlopen/dlsym 都不做。
  ;; ══════════════════════════════════════════════════════════════════

  ;; 记忆化:build 抛异常 ⇒ 记住 #f(= 这台机器上不可用)。
  (define (ffi-once build)
    (let ([cache 'not-built])
      (lambda ()
        (when (eq? cache 'not-built)
          (set! cache (guard (e [#t #f]) (build))))
        cache)))

  ;; 【MUST】这里问的是**真实平台**,不是 windows-shell? 那个 parameter ——
  ;; 后者被平台参数化测试驱动来验另一侧的**串生成**,拿它决定 dlopen 谁,
  ;; 会在 Linux 上去开 kernel32.dll。同 harness 里 windows-host? 的那条理由。
  (define (real-windows?) (windows-mt? (current-machine-type)))

  (define pipe-probe
    (ffi-once
      (lambda ()
        (if (real-windows?)
            (begin
              (load-shared-object "kernel32.dll")
              (let ([get-std-handle (foreign-procedure "GetStdHandle" (int) void*)]
                    [get-file-type  (foreign-procedure "GetFileType" (void*) unsigned-32)])
                ;; 【已知限制】x64 只有一种调用约定,故用默认的 __cdecl。32 位 i3nt
                ;; 要 __stdcall,而那个词在 POSIX 的 Chez 上**展开期就报错**,写不进
                ;; 这个两平台共用的文件 —— 真要支持 i3nt,得把这段拆进平台分文件。
                (lambda () (= 3 (get-file-type (get-std-handle -11))))))
            (begin
              (load-shared-object #f)   ; 进程内已有的符号(含 libc),不写死 so 名
              (let ([c-poll (foreign-procedure "poll" (void* unsigned-long int) int)])
                (lambda ()
                  ;; struct pollfd { int fd; short events; short revents; } —— 8 字节。
                  ;; 布局是 POSIX 定死的,不像 struct stat 那样按 libc/架构漂,
                  ;; 所以这里敢手摆内存;换成 fstat 判 S_ISFIFO 就不敢了。
                  (let ([pfd (foreign-alloc 8)])
                    (foreign-set! 'int   pfd 0 1)   ; fd = 1 (stdout)
                    (foreign-set! 'short pfd 4 4)   ; events = POLLOUT
                    (foreign-set! 'short pfd 6 0)   ; revents 清零
                    (c-poll pfd 1 0)                ; timeout 0,不阻塞
                    (let ([revents (foreign-ref 'short pfd 6)])
                      (foreign-free pfd)
                      ;; POLLERR=8 / POLLHUP=16,对端没了两者必有其一
                      (not (zero? (bitwise-and revents 24))))))))))))

  ;; #t = 对端没了 / #f = 还在 / 'unknown = 这台机器上问不了(调用方自行退路)
  (define (stdout-pipe-gone?)
    (let ([p (pipe-probe)]) (if p (p) 'unknown))))
