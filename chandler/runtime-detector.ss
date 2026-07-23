#!chezscheme
;;; chandler/runtime.ss --- chez/skiff 运行时探测 + 版本门(designs/06 §3-4)
;;;
;;; Chandler 双运行时:标准 Chez 与 Skiff 都是一等公民。差异仅「选哪个可执行文件」与
;;; 「版本门」;库/展开机制两者相同(Skiff 不改),故 activate 代码路径一致(见 activate.ss)。

(library (chandler runtime-detector)
  (export current-runtime runtime-version chez-version-string verify-runtime!
          runtime-env-var preferred-runtime parse-runtime-kind)
  (import (chezscheme)
          (chandler util)
          (chandler version))

  ;; ── 显式指定运行时(env)────────────────────────────────────────────────
  ;; CHANDLER_RUNTIME=skiff|chez —— 选**哪一种**运行时;与之配套的
  ;; CHANDLER_SKIFF / CHANDLER_SCHEME 则指定**哪个可执行文件**(名或路径)。
  ;; 三处一致遵循:启动器(sh/ps1 发现顺序)、run/exec、repl。
  ;; 优先级:--runtime 旗标 > CHANDLER_RUNTIME > manifest 声明 > 当前所在运行时。
  (define runtime-env-var "CHANDLER_RUNTIME")

  ;; 值 → 'skiff | 'chez;非法值即报错(静默忽略会让人以为生效了)
  (define (parse-runtime-kind v)
    (cond
      [(not v) #f]
      [(string=? v "skiff") 'skiff]
      [(string=? v "chez") 'chez]
      [else (error 'runtime
                   (format "invalid ~a=~a (want: skiff | chez)" runtime-env-var v))]))

  (define (preferred-runtime)
    (parse-runtime-kind (getenv* runtime-env-var)))

  ;; 探测:Skiff 运行时约定暴露顶层 skiff-version;否则标准 Chez
  (define (current-runtime)
    (if (skiff?) 'skiff 'chez))

  (define (skiff?)
    (and (skiff-version-string) #t))

  ;; skiff 可能把 skiff-version 绑为**字符串**,也可能绑为**返回字符串的过程**
  ;; (skiff 0.1.1 起为过程)——只认其一会把 skiff 误判成 Chez,进而错挂版本门、
  ;; repl 选错运行时。两种绑法都认;取不到字符串则 #f(非 skiff)。
  (define (skiff-version-string)
    (guard (e [#t #f])
      (and (top-level-bound? 'skiff-version)
           (let ([v (top-level-value 'skiff-version)])
             (cond
               [(string? v) v]
               [(procedure? v) (let ([r (v)]) (and (string? r) r))]
               [else #f])))))

  ;; 当前运行时版本字符串
  (define (runtime-version)
    (or (and (eq? 'skiff (current-runtime)) (skiff-version-string))
        (chez-version-string)))

  (define (chez-version-string)
    (call-with-values scheme-version-number
      (lambda (a b c) (format "~a.~a.~a" a b c))))

  ;; 版本门:manifest 的 chez/skiff 约束是否被当前运行时满足;不符 fail fast + 可执行诊断
  ;; constraints: alist ((chez . range-or-#f) (skiff . range-or-#f))
  (define (verify-runtime! constraints)
    (let ([rt (current-runtime)]
          [chez-c (alist-ref constraints 'chez)]
          [skiff-c (alist-ref constraints 'skiff)])
      (case rt
        [(chez)
         (when skiff-c
           ;; 项目要求 Skiff,当前是标准 Chez → 警告(依赖可能 import (skiff …) 而硬错)
           (fprintf (current-error-port)
                    "warning: project requires (skiff ~s) but the current runtime is stock Chez; dependencies using Skiff facilities will fail~%"
                    skiff-c))
         (when chez-c (gate! "Chez" chez-c (chez-version-string)))]
        [(skiff)
         (when chez-c (gate! "Chez (via Skiff)" chez-c (chez-version-string)))
         (when skiff-c (gate! "Skiff" skiff-c (runtime-version)))])
      #t))

  (define (gate! what range actual)
    (unless (version-match? range actual)
      (error 'verify-runtime!
             (format "runtime requirement not met: need ~a ~a, have ~a; install a matching runtime or adjust the manifest"
                     what range actual)))))
