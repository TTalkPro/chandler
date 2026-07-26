#!chezscheme
;;; tests/chandler/cli-runtime-env.ss --- (chandler cli runtime-env) 共享运行时环境装配测试
;;;
;;; 覆盖 v3 抽出来的共享层:choose-interp 的优先级链、make-preamble 的产物结构、
;;; collect-dotenv 的 .env + .env.tests + --env-file 三级覆盖。这些是 cmd-run /
;;; cmd-repl / cmd-exec / cmd-test 共用的核心,故单独成 suite(端到端在 cli.ss)。

(library (tests chandler cli-runtime-env)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler cli args)
          (chandler cli runtime-env))

  ;; 写 .env / .env.tests / 任一文件到临时项目根
  (define (proj-with-files files)
    (let ([d (mktmp)])
      (for-each (lambda (f)
                  (let ([p (join-paths d (car f))])
                    (ensure-parent p)
                    (write-file p (cdr f))))
                files)
      d))

  ;; parse-args 返回 4 值;collect-dotenv 只取 flags。包一层方便用。
  (define (test-flags . argv)
    (let-values ([(sub pos flags rest) (parse-args argv)])
      flags))

  ;; assoc 取首匹配;collect-dotenv 的 alist 末位优先(shell export 语义:后到者胜)。
  ;; 故覆盖测试要看末匹配。
  (define (val alist key) (cond [(assoc key alist) => cdr] [else #f]))
  (define (last-val alist key)
    (let loop ([a alist] [found #f])
      (cond
        [(null? a) found]
        [(equal? (caar a) key) (loop (cdr a) (cdar a))]
        [else (loop (cdr a) found)])))

  (define-suite suite

    ;; ── collect-dotenv:基础(只有 .env 时行为同 cmd-run 老版)──
    (collect-dotenv-env-only
      (let ([root (proj-with-files '((".env" . "FOO=bar\nBAZ=qux\n")))])
        (let ([e (collect-dotenv root (test-flags "run"))])
          (assert-string= "bar" (val e "FOO"))
          (assert-string= "qux" (val e "BAZ"))
          (assert-equal 2 (length e)))))

    ;; .env 不存在 → 空
    (collect-dotenv-no-env-empty
      (let ([root (mktmp)])
        (assert-equal '() (collect-dotenv root (test-flags "run")))))

    ;; ── .env.tests 覆盖 .env(同键后者胜 —— 末位 export 在 shell 里生效)──
    (collect-dotenv-env-tests-overrides-env
      (let ([root (proj-with-files
                    '((".env"       . "MODE=base\nKEEP=keep\n")
                      (".env.tests" . "MODE=override\n")))])
        (let ([e (collect-dotenv root (test-flags "test"))])
          ;; 末匹配 = override(覆盖语义由 shell export 后到者胜实现)
          (assert-string= "override" (last-val e "MODE"))
          ;; .env.tests 没声明的键,.env 的保留
          (assert-string= "keep" (val e "KEEP"))
          ;; alist 末尾追加(不就地改):两条 MODE 都在(末位的覆盖靠 shell export 序)
          (let ([modes (filter (lambda (kv) (equal? (car kv) "MODE")) e)])
            (assert-equal 2 (length modes))))))

    ;; 仅有 .env.tests(无 .env)也能用(cmd-test 不必先有 .env)
    (collect-dotenv-env-tests-without-env
      (let ([root (proj-with-files '((".env.tests" . "X=1\n")))])
        (let ([e (collect-dotenv root (test-flags "test"))])
          (assert-string= "1" (val e "X"))
          (assert-equal 1 (length e)))))

    ;; --env-file 仍能覆盖 .env.tests(显式优先于约定)
    (collect-dotenv-env-file-overrides-env-tests
      (let ([root (proj-with-files
                    '((".env"       . "MODE=base\n")
                      (".env.tests" . "MODE=tests\n")
                      ("custom.env" . "MODE=cli\n")))])
        (let ([e (collect-dotenv root (test-flags "run" "--env-file" "custom.env"))])
          ;; 三者都在,cli 末位 → env-prefix 时覆盖前面
          (let ([modes (filter (lambda (kv) (equal? (car kv) "MODE")) e)])
            (assert-equal 3 (length modes))))))

    ;; ── choose-interp:--runtime 旗标优先级 ──
    (choose-interp-runtime-flag-skiff
      (let ([root (mktmp)])
        ;; --runtime=skiff → 'skiff kind → skiff-exe 默认 "skiff"
        (let-values ([(sub pos flags rest) (parse-args '("run" "--runtime=skiff"))])
          (assert-string= "skiff" (choose-interp root flags)))))

    (choose-interp-runtime-flag-chez
      (let ([root (mktmp)])
        (let-values ([(sub pos flags rest) (parse-args '("run" "--runtime=chez"))])
          (assert-string= "scheme" (choose-interp root flags)))))

    ;; CHANDLER_SKIFF / CHANDLER_SCHEME 覆盖默认可执行文件名
    (choose-interp-honors-chandler-skiff-env
      (let ([old (getenv "CHANDLER_SKIFF")]
            [root (mktmp)])
        (dynamic-wind
          (lambda () (putenv "CHANDLER_SKIFF" "/custom/skiff"))
          (lambda ()
            (let-values ([(sub pos flags rest) (parse-args '("run" "--runtime=skiff"))])
              (assert-string= "/custom/skiff" (choose-interp root flags))))
          (lambda () (putenv "CHANDLER_SKIFF" (or old ""))))))

    ;; ── make-preamble:native .so + (load script) 顺序 ──
    (make-preamble-loads-natives-then-script
      (let* ([root (mktmp)]
             [dummy-so (join-paths root "fake.so")]
             [_ (write-file dummy-so "")]            ; 存在即触发 load-shared-object
             [target (join-paths root "app.ss")]
             [_ (write-file target "")]
             [preamble (make-preamble root (list dummy-so) target)])
        (assert-true (file-exists? preamble))
        (let ([txt (read-file preamble)])
          ;; native 在前
          (assert-true (substr? txt "(load-shared-object"))
          (assert-true (substr? txt "fake.so"))
          ;; script load 在后
          (assert-true (substr? txt "(load"))
          (assert-true (substr? txt "app.ss"))
          ;; 顺序:native 的 load-shared-object 必须在 (load script) 之前
          (let ([so-pos (string-search txt "(load-shared-object")]
                [load-pos (string-search txt "(load \"")])
            (assert-true (and so-pos load-pos))
            (assert-true (< so-pos load-pos))))))

    ;; make-preamble 落点固定(<root>/.chandler-run.ss),与 .gitignore 一致
    (make-preamble-path-fixed
      (let* ([root (mktmp)]
             [target (join-paths root "x.ss")]
             [_ (write-file target "")]
             [preamble (make-preamble root '() target)])
        (assert-true (substr? preamble ".chandler-run.ss"))))

    ))
