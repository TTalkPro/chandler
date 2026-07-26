#!chezscheme
;;; chandler/lock.ss --- 读写 chandler-manifest.lock + 拓扑序(designs/06 §6)
;;;
;;; lock 是机器生成的可复现之源:每依赖记确切 rev + 来源 + pin + deps + natives。
;;; v3 起新增 (files ...) 字段(D15):此 version 自身的文件清单 + sha256,取代
;;; v2 的 per-version `.chandler/registry/<name>.ss`。
;;; canonical 写(字典序 + 固定缩进,来自 (chandler sexp))保证「同输入 → 同字节」。

(library (chandler lock)
  (export make-locked-dep locked-dep? locked-dep-name
          locked-dep-source-kind locked-dep-source-loc
          locked-dep-pin-kind locked-dep-pin-val
          locked-dep-rev locked-dep-deps locked-dep-natives
          locked-dep-scope locked-dep-resources
          make-lock lock? lock-format lock-manifest-sha256 lock-chandler lock-deps
          lock-files with-files lock-file-sha256
          lock->datum datum->lock write-lock read-lock
          manifest-content-sha256 lock-fresh?
          topo-order lock-ref)
  (import (chezscheme)
          (chandler sexp)
          (chandler hash))

  (define lock-format-version 1)

  ;; 一条已锁依赖;scope ∈ {runtime, dev}
  ;; resources:designs/11 §6 标准化快照 —— #f 表示无声明,否则为 ((libref-list . path) ...)
  ;; M1/M2 才会从 manifest resources 字段填入,目前 resolve 路径传 #f。
  (define-record-type locked-dep
    (fields name source-kind source-loc pin-kind pin-val rev
            deps natives scope resources
            provenance))   ; v2:记录来源详情(git rev 字符串 | prebuilt 列表 | #f)

  ;; 用 3-arg 形:lock 是类型名,make-lock-rec 是自动构造,lock? 是谓词。
  ;; make-lock 留给我们 case-lambda(支持 files 缺省)。
  (define-record-type (lock make-lock-rec lock?)
    (fields format manifest-sha256 chandler deps files))   ; v3:files = (rel . sha256) list;() 表空

  (define make-lock
    (case-lambda
      [(fmt sha ch deps)            (make-lock-rec fmt sha ch deps '())]
      [(fmt sha ch deps files)      (make-lock-rec fmt sha ch deps files)]))

  ;; ── files 字段访问(辅助) ──
  (define (with-files lk files)
    (make-lock-rec (lock-format lk) (lock-manifest-sha256 lk) (lock-chandler lk)
                   (lock-deps lk) files))

  (define (lock-file-sha256 lk rel)
    (let loop ([fs (lock-files lk)])
      (cond
        [(null? fs) #f]
        [(string=? (caar fs) rel) (cdar fs)]
        [else (loop (cdr fs))])))

  ;; ── 序列化 ──
  (define (lock->datum lk)
    (let ([base `(lock
                   (format ,(lock-format lk))
                   (manifest-sha256 ,(lock-manifest-sha256 lk))
                   (chandler ,(lock-chandler lk))
                   (resolved
                     ,@(map locked-dep->datum
                            (list-sort (lambda (a b) (string<? (name-str a) (name-str b)))
                                       (lock-deps lk)))))]
          [files (lock-files lk)])
      (if (null? files)
          base
          (append base
                  (list `(files
                           ,@(map (lambda (f)
                                    `(,(car f) (sha256 ,(cdr f))))
                                  files)))))))

  (define (name-str d) (symbol->string (locked-dep-name d)))

  (define (locked-dep->datum d)
    `(,(locked-dep-name d)
       (source (,(locked-dep-source-kind d) ,(locked-dep-source-loc d)))
       (pin (,(locked-dep-pin-kind d) ,(locked-dep-pin-val d)))
       (rev ,(locked-dep-rev d))
       (deps ,@(locked-dep-deps d))
       (natives ,@(locked-dep-natives d))
       ,@(if (eq? 'dev (locked-dep-scope d)) '((scope dev)) '())
       ,@(let ([rs (locked-dep-resources d)])
           (if rs
               (list `(resources ,@(map (lambda (p)
                                          `(,(car p) ,(cdr p)))
                                        rs)))
               '()))
       ,@(let ([pv (locked-dep-provenance d)])      ; v2:provenance
           (if pv (list `(provenance ,pv)) '()))))

  (define (datum->lock datum)
    (let ([body (expect-tag datum 'lock 'datum->lock)])
      ;; format 校验(对齐 manifest/registered):缺省回 1(向后兼容老 lock);
      ;; 高于支持版本 → 友好报错。此前完全不校验 —— format 99 静默通过。
      (let ([fmt (or (field-ref body 'format) lock-format-version)])
        (when (> fmt lock-format-version)
          (error 'datum->lock
                 (format "lock format ~a is newer than the supported ~a; upgrade chandler"
                         fmt lock-format-version)))
        (make-lock-rec
          fmt
          (field-ref body 'manifest-sha256)
          (field-ref body 'chandler)
          (map datum->locked-dep (field-ref* body 'resolved))
          ;; v3:files 字段缺省为 '()(向后兼容 v2 lock)
          (map datum->file-entry (field-ref* body 'files))))))

  ;; file entry datum 形:("<rel>" (sha256 "<hex>"))
  (define (datum->file-entry d)
    (unless (and (pair? d) (string? (car d))
                 (pair? (cdr d)) (pair? (cadr d)) (eq? (caadr d) 'sha256)
                 (pair? (cdadr d)) (string? (cadadr d)))
      (error 'datum->file-entry
             "file entry must be (\"<rel>\" (sha256 \"<hex>\"))" d))
    (cons (car d) (cadadr d)))

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
        (field-ref* b 'deps)
        (field-ref* b 'natives)
        (if (equal? '(dev) (field-ref* b 'scope)) 'dev 'runtime)
        (parse-locked-resources (field-ref* b 'resources))
        (field-ref b 'provenance))))   ; v2:#f 若缺省(向后兼容老 lock)

  ;; lock 里的 resources 已标准化(designs/11 §6.3):((libref-list "path") ...)
  ;; 字段缺省 → #f(向后兼容老 lock 文件)
  (define (parse-locked-resources items)
    (and (not (null? items))
         (map (lambda (it)
                (unless (and (pair? it) (= 2 (length it))
                             (pair? (car it)) (string? (cadr it)))
                  (error 'datum->locked-dep
                         "lock resources entry must be ((libref …) \"path\")" it))
                (cons (car it) (cadr it)))
              items)))

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
