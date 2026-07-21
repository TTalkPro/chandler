#!chezscheme
;;; chandler/lock.ss --- 读写 manifest.lock + 拓扑序(designs/02 §2, 03 §3-4)
;;;
;;; lock 是机器生成的可复现之源:每依赖记确切 rev + 来源 + pin + srcdir + deps + natives。
;;; canonical 写(字典序 + 固定缩进,来自 (chandler sexp))保证「同输入 → 同字节」。
;;; bake 反向依赖本库读 lock 排 native/编译序(designs/07 §5)。

(library (chandler lock)
  (export make-locked-dep locked-dep? locked-dep-name
          locked-dep-source-kind locked-dep-source-loc
          locked-dep-pin-kind locked-dep-pin-val
          locked-dep-rev locked-dep-srcdir locked-dep-deps locked-dep-natives
          locked-dep-scope
          make-lock lock? lock-format lock-manifest-sha256 lock-chandler lock-deps
          lock->datum datum->lock write-lock read-lock
          manifest-content-sha256 lock-fresh?
          topo-order lock-ref)
  (import (chezscheme)
          (chandler sexp)
          (chandler hash))

  (define lock-format-version 1)

  ;; 一条已锁依赖;scope ∈ {runtime, dev}
  (define-record-type locked-dep
    (fields name source-kind source-loc pin-kind pin-val rev srcdir deps natives scope))

  (define-record-type lock
    (fields format manifest-sha256 chandler deps))   ; deps = (locked-dep ...)

  ;; ── 序列化 ──
  (define (lock->datum lk)
    `(lock
       (format ,(lock-format lk))
       (manifest-sha256 ,(lock-manifest-sha256 lk))
       (chandler ,(lock-chandler lk))
       (resolved
         ,@(map locked-dep->datum
                (list-sort (lambda (a b) (string<? (name-str a) (name-str b)))
                           (lock-deps lk))))))

  (define (name-str d) (symbol->string (locked-dep-name d)))

  (define (locked-dep->datum d)
    `(,(locked-dep-name d)
       (source (,(locked-dep-source-kind d) ,(locked-dep-source-loc d)))
       (pin (,(locked-dep-pin-kind d) ,(locked-dep-pin-val d)))
       (rev ,(locked-dep-rev d))
       (srcdir ,(locked-dep-srcdir d))
       (deps ,@(locked-dep-deps d))
       (natives ,@(locked-dep-natives d))
       ,@(if (eq? 'dev (locked-dep-scope d)) '((scope dev)) '())))

  (define (datum->lock datum)
    (let ([body (expect-tag datum 'lock 'datum->lock)])
      (make-lock
        (or (field-ref body 'format) 1)
        (field-ref body 'manifest-sha256)
        (field-ref body 'chandler)
        (map datum->locked-dep (field-ref* body 'resolved)))))

  (define (datum->locked-dep item)
    (let* ([name (car item)]
           [b    (cdr item)]
           [src  (field-ref b 'source)]           ; (kind loc)
           [pin  (field-ref b 'pin)])             ; (kind val)
      (make-locked-dep
        name
        (and src (car src)) (and src (cadr src))
        (and pin (car pin)) (and pin (cadr pin))
        (field-ref b 'rev)
        (or (field-ref b 'srcdir) ".")
        (field-ref* b 'deps)
        (field-ref* b 'natives)
        (if (equal? '(dev) (field-ref* b 'scope)) 'dev 'runtime))))

  ;; ── 文件 I/O ──
  (define (write-lock path lk)
    (write-canonical-file path (lock->datum lk)))

  (define (read-lock path)
    (datum->lock (read-datum-file path)))

  ;; ── 新鲜度判定(designs/01 §install 判定):lock 记的 manifest 哈希是否 == 当前 ──
  (define (manifest-content-sha256 manifest-path)
    (sha256-file manifest-path))

  (define (lock-fresh? lk manifest-path)
    (and (lock-manifest-sha256 lk)
         (string=? (lock-manifest-sha256 lk)
                   (manifest-content-sha256 manifest-path))))

  (define (lock-ref lk name)
    (find (lambda (d) (eq? (locked-dep-name d) name)) (lock-deps lk)))

  ;; ── 拓扑序:被依赖者先(designs/03 §3);成环则任意一致断环 + 该实现返回可用序 ──
  ;; 返回 locked-dep 列表,依赖在前。图信息取 locked-dep-deps。
  (define (topo-order lk)
    (let* ([deps (lock-deps lk)]
           [by-name (make-eq-hashtable)])
      (for-each (lambda (d) (hashtable-set! by-name (locked-dep-name d) d)) deps)
      (let ([visited (make-eq-hashtable)]   ; name → 'done / 'active
            [out '()])
        (define (visit d)
          (let ([n (locked-dep-name d)])
            (case (hashtable-ref visited n #f)
              [(done) (void)]
              [(active) (void)]            ; 环:忽略回边(断环),留警告给 resolve 层
              [else
               (hashtable-set! visited n 'active)
               (for-each
                 (lambda (dn)
                   (let ([child (hashtable-ref by-name dn #f)])
                     (when child (visit child))))
                 (locked-dep-deps d))
               (hashtable-set! visited n 'done)
               (set! out (cons d out))])))
        ;; 稳定入口序:按名字典序
        (for-each visit
                  (list-sort (lambda (a b) (string<? (name-str a) (name-str b))) deps))
        (reverse out)))))
