#!chezscheme
;;; chandler/proc.ss --- 子进程封装(git / bake 调用复用)
;;;
;;; 约定:参数以**列表**传入并逐个 shell 引用(不拼裸串),避免 URL/路径里的元字符注入。
;;; 用 `system` + 临时文件重定向捕获 stdout/stderr 与**退出码**(open-process-ports 拿不到
;;; 退出码;system 返回码可靠)。纯 POSIX;Windows 适配留待跨平台阶段。

(library (chandler proc)
  (export run-capture run-check run-status run-foreground shell-quote
          proc-result-code proc-result-out proc-result-err)
  (import (chezscheme))

  (define-record-type proc-result
    (fields code out err))

  ;; shell 单引号引用:' → '\'' 包裹
  (define (shell-quote s)
    (let ([op (open-output-string)])
      (display #\' op)
      (string-for-each
        (lambda (c)
          (if (char=? c #\')
              (display "'\\''" op)
              (display c op)))
        s)
      (display #\' op)
      (get-output-string op)))

  (define (quote-command prog args)
    (let ([op (open-output-string)])
      (display (shell-quote prog) op)
      (for-each (lambda (a) (display #\space op) (display (shell-quote a) op)) args)
      (get-output-string op)))

  ;; ── 唯一临时目录(mkdir 原子性:已存在即抛,重试)──
  (define counter 0)
  (define (next-counter) (set! counter (+ counter 1)) counter)

  (define (temp-base)
    (or (getenv "TMPDIR") "/tmp"))

  (define (make-temp-dir)
    (let ([t (current-time 'time-utc)])
      (let loop ([n (+ (* (time-second t) 1000000)
                       (quotient (time-nanosecond t) 1000)
                       (next-counter))])
        (let ([d (string-append (temp-base) "/chandler-" (number->string n))])
          (if (guard (e [#t #f]) (mkdir d) #t)
              d
              (loop (+ n 1)))))))

  (define (rm-rf path)
    (system (string-append "rm -rf " (shell-quote path))))

  (define (read-file-string path)
    (if (file-exists? path)
        (let ([s (call-with-port (open-file-input-port path
                                   (file-options) (buffer-mode block) (native-transcoder))
                   (lambda (p) (get-string-all p)))])
          (if (eof-object? s) "" s))          ; 空文件 get-string-all 返回 eof,规整为 ""
        ""))

  ;; ── 主入口 ──
  ;; run-capture:(values code stdout stderr) 经 proc-result;opts: (cwd . dir) (env . ((k.v)…))
  (define run-capture
    (case-lambda
      [(prog args) (run-capture prog args '())]
      [(prog args opts)
       (let* ([dir (make-temp-dir)]
              [outf (string-append dir "/out")]
              [errf (string-append dir "/err")]
              [cwd (assq-val 'cwd opts)]
              [env (assq-val 'env opts)]
              [base (quote-command prog args)]
              [with-redir (string-append base " >" (shell-quote outf)
                                         " 2>" (shell-quote errf))]
              [with-cd (if cwd
                           (string-append "cd " (shell-quote cwd) " && " with-redir)
                           with-redir)]
              [with-env (if env (string-append (env-prefix env) with-cd) with-cd)])
         (let ([code (system with-env)])
           (let ([out (read-file-string outf)]
                 [err (read-file-string errf)])
             (rm-rf dir)
             (make-proc-result code out err))))]))

  (define (env-prefix env)
    (fold-left
      (lambda (acc kv)
        (string-append acc (car kv) "=" (shell-quote (cdr kv)) " "))
      "" env))

  ;; run-check:成功返回 stdout;失败抛(带 prog/args/退出码/stderr 上下文)
  (define run-check
    (case-lambda
      [(prog args) (run-check prog args '())]
      [(prog args opts)
       (let ([r (run-capture prog args opts)])
         (if (= 0 (proc-result-code r))
             (proc-result-out r)
             (error 'run-check
                    (format "命令失败(退出码 ~a):~a ~a~%stderr: ~a"
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
       (let* ([cwd (assq-val 'cwd opts)]
              [env (assq-val 'env opts)]
              [base (quote-command prog args)]
              [with-cd (if cwd (string-append "cd " (shell-quote cwd) " && " base) base)]
              [full (if env (string-append (env-prefix env) with-cd) with-cd)])
         (system full))]))

  (define (assq-val k alist)
    (let ([p (assq k alist)]) (and p (cdr p)))))
