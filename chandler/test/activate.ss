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
          (chandler runtime))

  (define repo-root (current-directory))   ; 跑 run-tests 时 = chandler 仓库根

  (define-suite suite
    ;; ── runtime(双运行时:scheme→chez / skiff→skiff)──
    (runtime-detection
      ;; current-runtime ∈ {chez, skiff},且 skiff ⟺ 顶层绑定 skiff-version
      (assert-true (memq (current-runtime) '(chez skiff)))
      (assert-equal (if (top-level-bound? 'skiff-version) 'skiff 'chez)
                    (current-runtime)))

    (runtime-version-format
      ;; 非空,以数字打头(chez 如 10.4.1;skiff 如 0.0.0-dev)
      (let ([v (runtime-version)])
        (assert-true (> (string-length v) 0))
        (assert-true (char-numeric? (string-ref v 0)))))

    (verify-runtime-pass
      (assert-true (verify-runtime! (list (cons 'chez ">=10.0") (cons 'skiff #f)))))

    (verify-runtime-fail
      (assert-raises
        (lambda () (verify-runtime! (list (cons 'chez ">=99.0") (cons 'skiff #f))))))

    ;; ── activate 端到端(子进程脚本顶层)──
    (activate-mounts-and-imports
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
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
