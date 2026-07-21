#!chezscheme
;;; chandler/runtime.ss --- chez/skiff 运行时探测 + 版本门(designs/06 §3-4)
;;;
;;; Chandler 双运行时:标准 Chez 与 Skiff 都是一等公民。差异仅「选哪个可执行文件」与
;;; 「版本门」;库/展开机制两者相同(Skiff 不改),故 activate 代码路径一致(见 activate.ss)。

(library (chandler runtime)
  (export current-runtime runtime-version verify-runtime!)
  (import (chezscheme)
          (chandler version))

  ;; 探测:Skiff 运行时约定暴露顶层 skiff-version(字符串);否则标准 Chez
  (define (current-runtime)
    (if (skiff?) 'skiff 'chez))

  (define (skiff?)
    (guard (e [#t #f])
      (and (top-level-bound? 'skiff-version)
           (string? (top-level-value 'skiff-version)))))

  ;; 当前运行时版本字符串
  (define (runtime-version)
    (case (current-runtime)
      [(skiff) (top-level-value 'skiff-version)]
      [else (chez-version-string)]))

  (define (chez-version-string)
    (call-with-values scheme-version-number
      (lambda (a b c) (format "~a.~a.~a" a b c))))

  ;; 版本门:manifest 的 chez/skiff 约束是否被当前运行时满足;不符 fail fast + 可执行诊断
  ;; constraints: alist ((chez . range-or-#f) (skiff . range-or-#f))
  (define (verify-runtime! constraints)
    (let ([rt (current-runtime)]
          [chez-c (assq-val 'chez constraints)]
          [skiff-c (assq-val 'skiff constraints)])
      (case rt
        [(chez)
         (when skiff-c
           ;; 项目要求 Skiff,当前是标准 Chez → 警告(依赖可能 import (skiff …) 而硬错)
           (fprintf (current-error-port)
                    "warning: 项目声明 (skiff ~s) 但当前运行时是标准 Chez;若依赖用到 Skiff 设施将失败~%"
                    skiff-c))
         (when chez-c (gate! "Chez" chez-c (chez-version-string)))]
        [(skiff)
         (when chez-c (gate! "Chez(经 Skiff)" chez-c (chez-version-string)))
         (when skiff-c (gate! "Skiff" skiff-c (runtime-version)))])
      #t))

  (define (gate! what range actual)
    (unless (version-match? range actual)
      (error 'verify-runtime!
             (format "运行时不满足要求:需 ~a ~a,当前 ~a。请安装匹配运行时或调整 manifest。"
                     what range actual))))

  (define (assq-val k alist)
    (let ([p (assq k alist)]) (and p (cdr p)))))
