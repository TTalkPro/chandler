#!chezscheme
;;; chandler/test/activate.ss --- (chandler runtime) 单测 + (chandler activate) 端到端

(library (chandler test activate)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler proc)
          (chandler layout)
          (chandler fetch)
          (chandler install)
          (chandler runtime))

  (define repo-root (current-directory))   ; 跑 run-tests 时 = chandler 仓库根

  (define (mktmp) (let ([r (run-capture "mktemp" '("-d"))]) (trim (proc-result-out r))))
  (define (write-file p s) (call-with-output-file p (lambda (o) (display s o)) 'truncate))
  (define (trim s) (let* ([cs (string->list s)] [cs (reverse (lt (reverse (lt cs))))]) (list->string cs)))
  (define (lt cs) (cond [(null? cs) cs] [(memv (car cs) '(#\space #\tab #\return #\newline)) (lt (cdr cs))] [else cs]))

  (define (make-lib-repo name)
    (let ([dir (mktmp)])
      (define (g . args) (run-check "git" (cons "-C" (cons dir args)) '()))
      (run-check "git" (list "init" "-q" "-b" "main" dir) '())
      (g "config" "user.email" "t@t") (g "config" "user.name" "t")
      (write-file (string-append dir "/manifest.ss")
        (format "(manifest (format 1) (name ~s) (version \"0.1.0\") (srcdir \".\"))" name))
      (write-file (string-append dir "/" name ".ss")
        (format "#!chezscheme~%(library (~a) (export ~a-ok) (import (chezscheme)) (define ~a-ok #t))~%" name name name))
      (g "add" "-A") (g "commit" "-q" "-m" "c1")
      dir))

  (define (make-app dep-name dep-url)
    (let ([dir (mktmp)])
      (write-file (string-append dir "/manifest.ss")
        (format "(manifest (format 1) (name \"app\") (version \"0.1.0\") (srcdir \".\") (deps (~a (git ~s) (branch \"main\"))))"
                dep-name dep-url))
      dir))

  (define-suite suite
    ;; ── runtime ──
    (runtime-is-chez
      (assert-equal 'chez (current-runtime)))

    (runtime-version-format
      ;; 形如 10.4.1
      (let ([v (runtime-version)])
        (assert-true (> (string-length v) 0))
        (assert-true (for-all char-numeric?
                              (filter (lambda (c) (not (char=? c #\.))) (string->list v))))))

    (verify-runtime-pass
      (assert-true (verify-runtime! (list (cons 'chez ">=10.0") (cons 'skiff #f)))))

    (verify-runtime-fail
      (assert-raises
        (lambda () (verify-runtime! (list (cons 'chez ">=99.0") (cons 'skiff #f))))))

    ;; ── activate 端到端(子进程脚本顶层)──
    (activate-mounts-and-imports
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app 'b b)])
          (install app '())
          (write-file (string-append app "/main.ss")
            "(import (chandler)) (activate) (import (b)) (display b-ok)")
          ;; 从 app 目录跑;--libdirs 指向 chandler 仓库根,(chandler) 可解析;
          ;; activate 读 ./manifest.lock 把 lib/b prepend,(import (b)) 随后解析成功
          (let ([r (run-capture "scheme"
                     (list "-q" "--libdirs" repo-root "--script" "main.ss")
                     (list (cons 'cwd app)))])
            (assert-string= "#t" (trim (proc-result-out r)))))))

    (activate-runtime-gate-blocks
      ;; app manifest 要求 chez >=99 → activate 的 gate-runtime! 抛错,脚本非零退出
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (mktmp)])
          (write-file (string-append app "/manifest.ss")
            (format "(manifest (format 1) (name \"app\") (version \"0.1.0\") (chez \">=99.0\") (deps (b (git ~s) (branch \"main\"))))" b))
          (install app '())
          (write-file (string-append app "/main.ss")
            "(import (chandler)) (activate) (display 'reached)")
          (let ([r (run-capture "scheme"
                     (list "-q" "--libdirs" repo-root "--script" "main.ss")
                     (list (cons 'cwd app)))])
            ;; 版本门失败 → 非零退出且未打印 reached
            (assert-false (= 0 (proc-result-code r)))
            (assert-false (member #\r (string->list (proc-result-out r))))))))))
