#!chezscheme
;;; chandler/registered.ss --- 中心注册表数据类型(designs/06 §5)
;;;
;;; 纯数据:record + 函数式更新 + datum 序列化。**无 I/O**(读写 `.registry/<name>.ss
;;; 在 (chandler registry io))。本库被 registry facade、commands、tests 复用。
;;;
;;; registered 记录一个 name 在中心 registry 里的全部信息:
;;;   - kind:app | lib(从 manifest 推导)
;;;   - versions:version 字符串 → version-entry(installed-at、source、installer)
;;;   - active:当前 bin/<name> 指向的 version(仅 app;lib 没有)
;;;
;;; 序列化形态(datum):
;;;   (registered
;;;     (format 1)
;;;     (name <symbol>)
;;;     (kind app|lib)
;;;     (versions ("<v>" (installed-at "...") (source ...) (installer ...)) ...)
;;;     (active "<v>"))   ; 仅 app

(library (chandler registered)
  (export
    ;; 构造
    make-registered
    make-version-entry
    ;; 谓词
    registered?
    version-entry?
    ;; registered accessors
    registered-name
    registered-kind
    registered-versions
    registered-active
    registered-has-version?
    ;; version-entry accessors
    version-entry-version
    version-entry-installed-at
    version-entry-source
    version-entry-installer
    ;; 函数式更新
    registered-add-version
    registered-remove-version
    registered-set-active
    ;; 序列化
    registered->datum
    datum->registered)
  (import (chezscheme)
          (chandler sexp))

  ;; 当前 registry 文件格式版本(序列化总写 (format 1))。
  ;; datum->registered 接受 ≤ 此版本的格式(前瞻性:允许老格式);更高则报
  ;; "newer than supported; upgrade chandler"(对齐 manifest.ss:175 的模式)。
  (define registered-format-version 1)

;; ══════════════════════════════════════════════════════════════════
;; record types(immutable,函数式更新靠重建)
;; ══════════════════════════════════════════════════════════════════
;; 用 Chez define-record-type,但隐藏自动 make- / ?-pred,改成我们自己的带校验包装。

  (define-record-type registered-rec
    (fields (immutable name)      ; symbol
            (immutable kind)      ; 'app | 'lib
            (immutable versions)  ; alist: ((version-str . version-entry) ...)
            (immutable active))   ; version-str | #f
    (sealed #t))

  (define-record-type version-entry-rec
    (fields (immutable version)       ; string
            (immutable installed-at)  ; string (ISO-8601)
            (immutable source)        ; datum: (path "...") | (git "...") | (pack "...")
            (immutable installer))    ; symbol
    (sealed #t))

  ;; 公开谓词:转发到自动生成的
  (define (registered? x) (registered-rec? x))
  (define (version-entry? x) (version-entry-rec? x))

  ;; 公开 accessors
  (define registered-name registered-rec-name)
  (define registered-kind registered-rec-kind)
  (define registered-versions registered-rec-versions)
  (define registered-active registered-rec-active)

  (define version-entry-version version-entry-rec-version)
  (define version-entry-installed-at version-entry-rec-installed-at)
  (define version-entry-source version-entry-rec-source)
  (define version-entry-installer version-entry-rec-installer)

  ;; ══════════════════════════════════════════════════════════════════
  ;; 构造
  ;; ══════════════════════════════════════════════════════════════════

  ;; make-registered 支持 0/1/2 个 optional args,便于测试与 facade 简化构造。
  (define make-registered
    (case-lambda
      [(name kind)                 (make-registered* name kind '() #f)]
      [(name kind versions)        (make-registered* name kind versions #f)]
      [(name kind versions active) (make-registered* name kind versions active)]))

  (define (make-registered* name kind versions active)
    (unless (symbol? name)
      (error 'make-registered "name must be a symbol" name))
    (unless (memq kind '(app lib))
      (error 'make-registered "kind must be 'app or 'lib" kind))
    (unless (list? versions)
      (error 'make-registered "versions must be a list" versions))
    (unless (or (not active) (and (string? active) (> (string-length active) 0)))
      (error 'make-registered "active must be #f or a non-empty string" active))
    (make-registered-rec name kind versions active))

  (define (make-version-entry version installed-at source installer)
    (unless (and (string? version) (> (string-length version) 0))
      (error 'make-version-entry "version must be a non-empty string" version))
    (unless (string? installed-at)
      (error 'make-version-entry "installed-at must be a string" installed-at))
    (unless (and (pair? source) (memq (car source) '(path git pack)))
      (error 'make-version-entry
             "source must be (path \"...\") | (git \"...\") | (pack \"...\")" source))
    (unless (symbol? installer)
      (error 'make-version-entry "installer must be a symbol" installer))
    (make-version-entry-rec version installed-at source installer))

  ;; ══════════════════════════════════════════════════════════════════
  ;; 查询
  ;; ══════════════════════════════════════════════════════════════════

  ;; registered-has-version? : reg string → bool
  (define (registered-has-version? reg version-str)
    (and (find-version-entry reg version-str) #t))

  (define (find-version-entry reg version-str)
    (let loop ([vs (registered-versions reg)])
      (cond
        [(null? vs) #f]
        [(and (pair? (car vs)) (string=? (caar vs) version-str))
         (cdar vs)]
        [else (loop (cdr vs))])))

  ;; ══════════════════════════════════════════════════════════════════
  ;; 函数式更新(immutable record → 新 record)
  ;; ══════════════════════════════════════════════════════════════════

  ;; 同 version 已存在 → 替换 entry(允许重装);新 version → 追加到末尾(保持插入序)。
  (define (registered-add-version reg entry)
    (unless (version-entry? entry)
      (error 'registered-add-version "entry must be a version-entry" entry))
    (let* ([ver (version-entry-version entry)]
           [old (registered-versions reg)]
           [new (alist-set old ver entry)])
      (make-registered-rec (registered-rec-name reg)
                  (registered-kind reg)
                  new
                  (registered-active reg))))

  ;; 删除 version。如果删的是 active,active 清空(D16 不变量)。
  (define (registered-remove-version reg version-str)
    (let* ([old (registered-versions reg)]
           [new (alist-remove old version-str)]
           [was-active (and (registered-active reg)
                            (string=? (registered-active reg) version-str))]
           [new-active (if was-active #f (registered-active reg))])
      (make-registered-rec (registered-rec-name reg)
                  (registered-kind reg)
                  new
                  new-active)))

  ;; 设 active = version-str。version 不存在 → 报错。lib → 报错。
  (define (registered-set-active reg version-str)
    (unless (eq? 'app (registered-kind reg))
      (error 'registered-set-active
             "only apps have an active version; this is a library" (registered-name reg)))
    (unless (registered-has-version? reg version-str)
      (error 'registered-set-active
             "version not installed; install it first"
             (registered-name reg) version-str))
    (make-registered-rec (registered-rec-name reg)
                (registered-kind reg)
                (registered-versions reg)
                version-str))

  ;; alist 助手:string key
  (define (alist-set alist k v)
    (let loop ([xs alist] [acc '()])
      (cond
        [(null? xs) (reverse (cons (cons k v) acc))]   ; 追加到末尾
        [(and (pair? (car xs)) (string=? (caar xs) k))
         (append (reverse acc) (list (cons k v)) (cdr xs))]  ; 替换,保持位置
        [else (loop (cdr xs) (cons (car xs) acc))])))

  (define (alist-remove alist k)
    (let loop ([xs alist] [acc '()])
      (cond
        [(null? xs) (reverse acc)]
        [(and (pair? (car xs)) (string=? (caar xs) k)) (append (reverse acc) (cdr xs))]
        [else (loop (cdr xs) (cons (car xs) acc))])))

  ;; ══════════════════════════════════════════════════════════════════
  ;; 序列化
  ;; ══════════════════════════════════════════════════════════════════

  ;; registered -> datum
  ;;   (registered (format 1)
  ;;               (name <sym>)
  ;;               (kind app|lib)
  ;;               (versions ("<v>" (installed-at "...") (source ...) (installer ...)) ...)
  ;;               [(active "<v>")])
  ;; active=#f 或 lib → 不输出 (active ...)。
  (define (registered->datum reg)
    (let ([base `(registered
                   (format 1)
                   (name ,(registered-name reg))
                   (kind ,(registered-kind reg))
                   (versions ,@(map (lambda (p) (version-entry->datum (cdr p)))
                                    (registered-versions reg))))])
      (if (and (registered-active reg) (eq? 'app (registered-kind reg)))
          (append base (list `(active ,(registered-active reg))))
          base)))

  (define (version-entry->datum ve)
    (let ([ver (version-entry-version ve)])
      `(,ver
         (installed-at ,(version-entry-installed-at ve))
         (source ,(version-entry-source ve))
         (installer ,(version-entry-installer ve)))))

  ;; datum -> registered(严格校验,非法 datum 报错)
  (define (datum->registered d)
    (let* ([body (expect-tag d 'registered 'datum->registered)]
           [fmt (field-ref body 'format #f)]
           [_ (unless (and (integer? fmt) (exact? fmt))
                (error 'datum->registered "missing or non-integer (format N)" fmt))]
           [_ (check-format! 'datum->registered fmt registered-format-version)]
           [name (field-ref body 'name #f)]
           [_ (unless (symbol? name)
                (error 'datum->registered "missing or invalid (name <symbol>)" name))]
           [kind (field-ref body 'kind #f)]
           [_ (unless (memq kind '(app lib))
                (error 'datum->registered "missing or invalid (kind app|lib)" kind))]
           [versions-datum (field-ref* body 'versions)]
           [_ (unless (list? versions-datum)
                (error 'datum->registered "(versions ...) must be a list"))]
           [entries (map datum->version-entry versions-datum)]
           [active (field-ref body 'active #f)])
      (when (and active (eq? kind 'lib))
        (error 'datum->registered
               "libraries must not have (active ...); only apps do"))
      (when (and active
                 (not (member active (map version-entry-version entries))))
        (error 'datum->registered
               "(active ...) points to unknown version" active))
      (let ([alist (map (lambda (e) (cons (version-entry-version e) e)) entries)])
        (make-registered-rec name kind alist active))))

  (define (datum->version-entry d)
    (unless (and (pair? d) (string? (car d)))
      (error 'datum->version-entry "version entry must start with a version string" d))
    (let ([ver (car d)]
          [body (cdr d)])
      (let ([installed-at (field-ref body 'installed-at #f)]
            [source (field-ref body 'source #f)]
            [installer (field-ref body 'installer #f)])
        (unless (and installed-at (string? installed-at))
          (error 'datum->version-entry "missing or invalid (installed-at \"...\")"))
        (unless (and source (pair? source) (memq (car source) '(path git pack)))
          (error 'datum->version-entry "missing or invalid (source ...)"))
        (unless (and installer (symbol? installer))
          (error 'datum->version-entry "missing or invalid (installer <symbol>)"))
        (make-version-entry-rec ver installed-at source installer))))

  )
