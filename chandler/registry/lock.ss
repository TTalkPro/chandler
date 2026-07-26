#!chezscheme
;;; chandler/registry/lock.ss --- per-prefix 进程锁(install/uninstall/switch 互斥)
;;;
;;; 锁 = 目录 <libdir>/.registry/.lock(mkdir 原子抢锁,并发下只一个赢家)。
;;; 持锁期间目录里写:
;;;   .pid      —— 持锁进程 pid
;;;   .started  —— 抢锁时刻(epoch 秒)
;;;
;;; staleness:锁年龄 > 10 分钟且持锁 pid 已死 → 视为残锁,强抢(rm-rf 后重抢)。
;;; pid 存活性走 Linux /proc 快路径;/proc 不存在的平台保守视为「活」(不强抢,
;;; 只等超时)。
;;;
;;; 超时:默认 30 秒抢不到 → 抛错。
;;;
;;; **不可重入**:同进程同 libdir 嵌套调用会自锁到超时。实际不会发生 —— 锁只包
;;; install-global / uninstall-global / switch-active 三个顶层入口,互不嵌套。

(library (chandler registry lock)
  (export with-registry-lock!)
  (import (chezscheme)
          (chandler fs)
          (chandler layout))

  (define stale-threshold-seconds 600)   ; 残锁阈值:10 分钟
  (define default-timeout-seconds 30)
  (define initial-delay-ms 50)           ; 退避初始 50ms
  (define max-delay-ms 500)              ; 退避上限 500ms

  (define (lock-dir libdir)
    (join-paths libdir ".registry" ".lock"))

  (define (sleep-ms ms)
    (sleep (make-time 'time-duration (exact (round (* ms 1000000))) 0)))

  ;; 尝试抢锁:成功 #t;锁已被占(mkdir 撞已存在)→ #f
  (define (try-acquire! ld)
    (guard (e (#t #f))
      (mkdir ld)
      ;; 元数据尽力写;失败不致命(缺 .pid/.started 的锁永不判 stale,保守方向)
      (guard (e (#t (void)))
        (write-text (join-paths ld ".pid") (number->string (get-process-id)))
        (write-text (join-paths ld ".started")
                    (number->string (time-second (current-time)))))
      #t))

  ;; pid 是否活:Linux 快路径 /proc/<pid>/;/proc 不在(非 Linux)→ 保守视为活
  (define (pid-alive? pid)
    (if (file-directory? "/proc")
        (file-exists? (string-append "/proc/" (number->string pid) "/"))
        #t))

  ;; 残锁判定:年龄超阈值 且 持锁 pid 已死
  (define (lock-stale? ld)
    (let ([pid (string->number (read-file-string (join-paths ld ".pid")))]
          [started (string->number (read-file-string (join-paths ld ".started")))])
      (and pid started
           (> (- (time-second (current-time)) started) stale-threshold-seconds)
           (not (pid-alive? pid)))))

  (define (acquire! ld timeout-seconds)
    (ensure-parent ld)
    (let ([deadline (+ (time-second (current-time)) timeout-seconds)])
      (let loop ([delay-ms initial-delay-ms])
        (cond
          [(try-acquire! ld) (void)]
          [(>= (time-second (current-time)) deadline)
           (error 'with-registry-lock! "timed out waiting for registry lock" ld)]
          [(lock-stale? ld)
           ;; 强抢残锁;mkdir 原子性兜底「双方同时强抢」的竞态(输家下一轮重试)
           (rm-rf ld)
           (loop delay-ms)]
          [else
           (sleep-ms delay-ms)
           (loop (min max-delay-ms (* delay-ms 2)))]))))

  ;; with-registry-lock! : libdir thunk [timeout-seconds] → thunk 的值
  (define with-registry-lock!
    (case-lambda
      [(libdir thunk) (with-registry-lock! libdir thunk default-timeout-seconds)]
      [(libdir thunk timeout-seconds)
       (let ([ld (lock-dir libdir)])
         (acquire! ld timeout-seconds)
         (dynamic-wind
           (lambda () (void))
           thunk
           (lambda () (rm-rf ld))))]))
  )
