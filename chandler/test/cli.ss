#!chezscheme
;;; chandler/test/cli.ss --- (chandler cli args) 单测 + CLI 端到端(经 main)

(library (chandler test cli)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler proc)
          (chandler fetch)
          (chandler cli args)
          (chandler cli main))

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

  (define-suite suite
    ;; ── args ──
    (parse-subcommand
      (let-values ([(sub pos flags rest) (parse-args '("install" "--production"))])
        (assert-string= "install" sub)
        (assert-true (flag? flags 'production))
        (assert-false rest)))

    (parse-long-value-space
      (let-values ([(sub pos flags rest) (parse-args '("add" "greet" "url" "--branch" "main"))])
        (assert-string= "add" sub)
        (assert-equal '("greet" "url") pos)
        (assert-string= "main" (flag flags 'branch))))

    (parse-long-value-eq
      (let-values ([(sub pos flags rest) (parse-args '("add" "x" "u" "--tag=v1.2.0"))])
        (assert-string= "v1.2.0" (flag flags 'tag))))

    (parse-short-C
      (let-values ([(sub pos flags rest) (parse-args '("-C" "/proj" "install"))])
        (assert-string= "/proj" (flag flags 'C))
        (assert-string= "install" sub)))

    (parse-double-dash-rest
      (let-values ([(sub pos flags rest) (parse-args '("exec" "--" "scheme" "-q"))])
        (assert-string= "exec" sub)
        (assert-equal '("scheme" "-q") rest)))

    (parse-boolean-long
      (let-values ([(sub pos flags rest) (parse-args '("install" "--offline" "--force"))])
        (assert-true (flag? flags 'offline))
        (assert-true (flag? flags 'force))))

    ;; ── main dispatch ──
    (main-version
      (assert-equal 0 (main '("--version"))))

    (main-unknown-command
      (assert-equal 64 (main '("bogus"))))

    (main-help-no-args
      (assert-equal 0 (main '())))

    ;; ── 端到端:init→add→install→verify→list 全经 main ──
    (main-full-workflow
      (parameterize ([cache-root (mktmp)])
        (let* ([greet (make-lib-repo "greet")]
               [app (mktmp)])
          (assert-equal 0 (main (list "-C" app "init" "--name=app")))
          (assert-equal 0 (main (list "-C" app "add" "greet" greet "--branch" "main")))
          (assert-equal 0 (main (list "-C" app "install")))
          (assert-equal 0 (main (list "-C" app "verify")))
          (assert-equal 0 (main (list "-C" app "list")))
          ;; lib/greet 物化
          (assert-true (file-exists? (string-append app "/lib/greet/greet.ss")))))))
  )
