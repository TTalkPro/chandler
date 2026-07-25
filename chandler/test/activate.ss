#!chezscheme
;;; chandler/test/activate.ss --- (chandler runtime) 单测 + (chandler activate) 端到端

(library (chandler test activate)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler proc)
          (chandler fetch)
          (chandler install)
          (chandler runtime-detector))

  (define repo-root (current-directory))   ; 跑 run-tests 时 = chandler 仓库根

  (define-suite suite
    ;; ── runtime(双运行时:scheme→chez / skiff→skiff)──
    (runtime-detection
      ;; current-runtime ∈ {chez, skiff},且 skiff ⟺ 顶层绑定 skiff-version
      (assert-true (memq (current-runtime) '(chez skiff)))
      (assert-equal (if (top-level-bound? 'skiff-version) 'skiff 'chez)
                    (current-runtime)))

    (runtime-version-format
      ;; 非空,以数字打头(chez 如 10.4.1;skiff 如 0.1.1)
      (let ([v (runtime-version)]
            [chez-v (call-with-values scheme-version-number
                      (lambda (a b c) (format "~a.~a.~a" a b c)))])
        (assert-true (> (string-length v) 0))
        (assert-true (char-numeric? (string-ref v 0)))
        ;; 跑在 skiff 上时须报 **skiff 自己的**版本,不得回落到 Chez 版本 ——
        ;; skiff 把 skiff-version 绑为过程(0.1.1 起)而非字符串,只认字符串会误判。
        (assert-equal (eq? 'skiff (current-runtime))
                      (not (string=? v chez-v)))))

    (verify-runtime-pass
      (assert-true (verify-runtime! (list (cons 'chez ">=10.0") (cons 'skiff #f)))))

    (verify-runtime-fail
      (assert-raises
        (lambda () (verify-runtime! (list (cons 'chez ">=99.0") (cons 'skiff #f))))))

    ;; ── 显式指定运行时:CHANDLER_RUNTIME=skiff|chez(启动器 / run / exec / repl 共用)──
    (preferred-runtime-env
      (let ([old (getenv runtime-env-var)])
        (dynamic-wind
          void
          (lambda ()
            ;; 解析:合法值 → 符号;空/未设 → #f;非法值 → 报错(静默忽略会误以为生效)
            (assert-equal 'skiff (parse-runtime-kind "skiff"))
            (assert-equal 'chez  (parse-runtime-kind "chez"))
            (assert-false (parse-runtime-kind #f))
            (assert-raises (lambda () (parse-runtime-kind "bogus")))
            ;; 经环境变量读取
            (putenv runtime-env-var "skiff")
            (assert-equal 'skiff (preferred-runtime))
            (putenv runtime-env-var "chez")
            (assert-equal 'chez (preferred-runtime))
            (putenv runtime-env-var "")            ; 空串视为未设(getenv* 语义)
            (assert-false (preferred-runtime))
            (putenv runtime-env-var "nope")
            (assert-raises (lambda () (preferred-runtime))))
          (lambda () (putenv runtime-env-var (or old ""))))))

    ;; ── activate 端到端(子进程脚本顶层)──
    (activate-mounts-and-imports
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (write-file (string-append app "/main.ss")
            "(import (chandler)) (activate) (import (b)) (display b-ok)")
          ;; 从 app 目录跑;--libdirs 指向 chandler 仓库根,(chandler) 可解析;
          ;; activate 读 ./chandler-manifest.lock 把 lib/b prepend,(import (b)) 随后解析成功
          (let ([r (run-capture "scheme"
                     (list "-q" "--libdirs" repo-root "--script" "main.ss")
                     (list (cons 'cwd app)))])
            (assert-string= "#t" (trim (proc-result-out r)))))))

    (activate-runtime-gate-blocks
      ;; app manifest 要求 chez >=99 → activate 的 gate-runtime! 抛错,脚本非零退出
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (mktmp)])
          (write-file (string-append app "/chandler-manifest.ss")
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
