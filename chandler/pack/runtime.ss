#!chezscheme
;;; chandler/pack/runtime.ss --- 运行时定位 + 版本探测(原 pack.ss §1)
;;;
;;; 捆进包里的那一份 runtime 的发现:skiff/chez 可执行文件、boot 目录、
;;; 版本探测(skiff --script probe、scheme --version)。
;;; which / real-path 已收入 (chandler proc),直接复用。

(library (chandler pack runtime)
  (export skiff-exe-path chez-exe-path skiff-boot-dir chez-csv-dir
          version-token has-digit? skiff-probe-src
          probe-skiff-version probe-chez-version)
  (import (chezscheme)
          (chandler proc)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler runtime-detector))

  (define (skiff-exe-path)
    (let ([e (which "skiff")])
      (unless e (error 'pack "runtime skiff: no `skiff` on PATH (install skiff first)"))
      (real-path e)))

  (define (chez-exe-path)
    (let ([e (which "scheme")])
      (unless e (error 'pack "runtime scheme: no `scheme` on PATH"))
      (real-path e)))

  ;; skiff 自己的 boot 发现顺序(src/shell/main.cpp):$SKIFF_BOOT_DIR →
  ;; <exedir>/../lib/skiff/boot(安装布局)→ <exedir>/../boot(构建树)。
  (define (skiff-boot-dir exe)
    (define (ok? d) (and d (file-exists? (join-paths d "skiff.boot")) d))
    (let ([up (parent-dir (parent-dir exe))])
      (or (ok? (getenv* "SKIFF_BOOT_DIR"))
          (ok? (join-paths up "lib/skiff/boot"))
          (ok? (join-paths up "boot"))
          (error 'pack
                 (format "runtime skiff: cannot locate skiff.boot near ~a (set SKIFF_BOOT_DIR)" exe)))))

  ;; <root>/lib/csv<ver>/<mt>/ —— 装着 petite.boot / scheme.boot 的目录。
  ;; 由 PATH 上的 `scheme` 推导;mise 式布局把二进制直接放在 csv 目录里,故回退到
  ;; 解引用后的真身所在目录。CHEZ_BOOT_DIR 覆盖。
  (define (chez-csv-dir exe ver)
    (define (ok? d) (and d (file-exists? (join-paths d "petite.boot")) d))
    (let* ([bin  (parent-dir exe)]
           [root (parent-dir bin)]
           [std  (join-paths root (string-append "lib/csv" ver) (current-machine-type))])
      (or (ok? (getenv* "CHEZ_BOOT_DIR"))
          (ok? std)
          (ok? (parent-dir (real-path exe)))
          (error 'pack
                 (format "cannot locate petite.boot (looked near ~a; set CHEZ_BOOT_DIR)" std)))))

  ;; ── 版本探测:清单的 target 三元组必须描述**被捆的那一份**,不是跑 chandler 的这一份 ──

  ;; 保留版本串开头那段合法字符,丢掉后面的 banner/提示符残渣。第二道保险:这类失败
  ;; 是「静默产出坏 manifest、到部署期才被 verify-target! 拒」型,值得留验证。
  (define (version-token s)
    (let* ([s (string-trim s)] [n (string-length s)])
      (let loop ([i 0])
        (if (and (< i n)
                 (let ([c (string-ref s i)])
                   (or (char-numeric? c) (char-alphabetic? c) (memv c '(#\. #\- #\+ #\_)))))
            (loop (+ i 1))
            (substring s 0 i)))))

  (define (has-digit? s)
    (let ([n (string-length s)])
      (let loop ([i 0]) (and (< i n) (or (char-numeric? (string-ref s i)) (loop (+ i 1)))))))

  ;; 探测被捆 skiff 的版本。两条硬约束(bake 踩过,原样继承):
  ;;   ① 必须走 `skiff --script <probe>` —— 裸 `skiff <file>` 是 load + REPL(skiff 刻意
  ;;      对齐 stock scheme 的 CLI 语义,不该改),提示符 `>` 会漏进 stdout 被吃进版本串
  ;;      (曾使 manifest 记成 "0.1.1>");--script 另有出错即非零退出的好处。
  ;;   ② 取值走 skiff boot 在顶层绑定的 skiff-version(procedure 或 string 两形都认),
  ;;      无需 (import (skiff app))。不解析 --version banner:verify-target! 比的是
  ;;      --app 时 (skiff-version) 的返回值,只有探同一个值才不会与 banner 排版漂移。
  (define skiff-probe-src
    "(display (let ((v (top-level-value 'skiff-version))) (if (procedure? v) (v) v)))")

  (define (probe-skiff-version exe)
    (let* ([dir (join-paths (or (getenv* "TMPDIR") "/tmp")
                            (string-append "chandler-pack-" (number->string (get-process-id))))]
           [probe (join-paths dir "probe.ss")])
      (ensure-dir dir)
      (write-text probe skiff-probe-src)
      (let* ([r (run-capture "sh"
                             (list "-c"
                                   (string-append "SKIFF_QUIET=1 " (shell-quote exe)
                                                  " --script " (shell-quote probe)
                                                  " < /dev/null")))]
             [v (version-token (proc-result-out r))])
        (rm-rf dir)
        (unless (has-digit? v)
          (error 'pack
                 (format "runtime skiff: version probe failed for ~a (got ~s; too old to bind skiff-version at top level?)"
                         exe v)))
        v)))

  ;; 被捆 Chez 的版本号(不是跑 chandler 的那一份 —— chandler 可能跑在 skiff 上,
  ;; 而 PATH 上的 `scheme` 未必同版本)。`scheme --version` 把版本印到 stderr。
  (define (probe-chez-version exe)
    (let* ([r (run-capture "sh"
                           (list "-c" (string-append (shell-quote exe) " --version 2>&1 < /dev/null")))]
           [v (version-token (proc-result-out r))])
      (if (has-digit? v) v (chez-version-string))))
  )
