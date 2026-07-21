#!chezscheme
;;; chandler/test/build.ss --- (chandler build) 排单/授权测试(mock bake)

(library (chandler test build)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler proc)
          (chandler fetch)
          (chandler install)
          (chandler build))

  (define (mock-bake)
    (string-append (current-directory) "/tests/mock-bake.sh"))

  (define (mktmp) (let ([r (run-capture "mktemp" '("-d"))]) (trim (proc-result-out r))))
  (define (write-file p s) (call-with-output-file p (lambda (o) (display s o)) 'truncate))
  (define (read-file p) (if (file-exists? p) (call-with-input-file p get-string-all) ""))
  (define (trim s) (let* ([cs (string->list s)] [cs (reverse (lt (reverse (lt cs))))]) (list->string cs)))
  (define (lt cs) (cond [(null? cs) cs] [(memv (car cs) '(#\space #\tab #\return #\newline)) (lt (cdr cs))] [else cs]))

  ;; 造带 native 声明的库仓
  (define (make-native-lib name soname)
    (let ([dir (mktmp)])
      (define (g . args) (run-check "git" (cons "-C" (cons dir args)) '()))
      (run-check "git" (list "init" "-q" "-b" "main" dir) '())
      (g "config" "user.email" "t@t") (g "config" "user.name" "t")
      (write-file (string-append dir "/manifest.ss")
        (format "(manifest (format 1) (name ~s) (version \"0.1.0\") (srcdir \".\") (native (~a (path \"native/~a\") (build make))))"
                name soname soname))
      (write-file (string-append dir "/" name ".ss")
        (format "#!chezscheme~%(library (~a) (export ok) (import (chezscheme)) (define ok #t))~%" name))
      (g "add" "-A") (g "commit" "-q" "-m" "c1")
      dir))

  (define (make-plain-lib name)
    (let ([dir (mktmp)])
      (define (g . args) (run-check "git" (cons "-C" (cons dir args)) '()))
      (run-check "git" (list "init" "-q" "-b" "main" dir) '())
      (g "config" "user.email" "t@t") (g "config" "user.name" "t")
      (write-file (string-append dir "/manifest.ss")
        (format "(manifest (format 1) (name ~s) (version \"0.1.0\") (srcdir \".\"))" name))
      (write-file (string-append dir "/" name ".ss")
        (format "#!chezscheme~%(library (~a) (export ok) (import (chezscheme)) (define ok #t))~%" name))
      (g "add" "-A") (g "commit" "-q" "-m" "c1")
      dir))

  (define (make-app deps)   ; deps=((name . url)…)
    (let ([dir (mktmp)] [op (open-output-string)])
      (fprintf op "(manifest (format 1) (name \"app\") (version \"0.1.0\") (srcdir \".\") (deps")
      (for-each (lambda (d) (fprintf op " (~a (git ~s) (branch \"main\"))" (car d) (cdr d))) deps)
      (fprintf op "))")
      (write-file (string-append dir "/manifest.ss") (get-output-string op))
      dir))

  (define (with-mock log thunk)
    (putenv "CHANDLER_BAKE" (mock-bake))
    (putenv "MOCK_BAKE_LOG" log)
    (thunk))

  (define-suite suite
    ;; 无 native 的依赖:build 直接排单,无需授权
    (build-plain-no-auth
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-plain-lib "b")]
               [app (make-app (list (cons 'b b)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (assert-equal 0 (build app '()))
              ;; mock 收到 compile-tree 调用
              (assert-true (substr? (read-file log) "compile-tree")))))))

    ;; 有 native 的依赖:无授权 → 报错(pending)
    (build-native-needs-auth
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (assert-raises (lambda () (build app '()))))))))

    ;; --allow-build → 执行 + 写 approvals + native 先于 compile-tree
    (build-native-authorized
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (assert-equal 0 (build app (list (cons 'allow-build #t))))
              (let ([l (read-file log)])
                (assert-true (substr? l "native"))
                (assert-true (substr? l "compile-tree")))
              ;; approvals 落盘
              (assert-true (file-exists? (string-append app "/.chandler-approvals")))
              ;; 再 build 无需 --allow-build(已授权且描述未变)
              (assert-equal 0 (build app '())))))))

    ;; 描述变更(掉包)→ 已有授权失效,重新需要 --allow-build
    (build-approval-invalidated-on-change
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))]
               [log (string-append (mktmp) "/log")])
          (install app '())
          (with-mock log
            (lambda ()
              (build app (list (cons 'allow-build #t)))
              ;; 改依赖 lib/n/manifest.ss 的 native 描述 → 哈希变
              (write-file (string-append (lib-dir app 'n) "/manifest.ss")
                "(manifest (format 1) (name \"n\") (version \"0.1.0\") (srcdir \".\") (native (libn (path \"native/libn\") (build (script \"evil.sh\")))))")
              ;; 未重新授权 → 报错
              (assert-raises (lambda () (build app '())))))))))

  (define (substr? s sub)
    (let ([ls (string-length s)] [lsub (string-length sub)])
      (let loop ([i 0])
        (cond [(> (+ i lsub) ls) #f]
              [(string=? sub (substring s i (+ i lsub))) #t]
              [else (loop (+ i 1))])))))
