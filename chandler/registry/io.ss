#!chezscheme
;;; chandler/registry/io.ss --- 中心注册表文件 I/O
;;;
;;; 读写 <libdir>/.registry/<name>.ss。**纯 I/O**,无业务逻辑(逻辑在 facade)。
;;;
;;; 文件路径约定:
;;;   <libdir>/.registry/<name>.ss
;;; 单文件 = 单 name 的全部 versions + active。
;;;
;;; 读:文件不存在 → 返回 #f(facade 决定是新建还是报错)。
;;; 写:目录不存在 → ensure-dir;用 canonical 写(同输入 → 同字节)。

(library (chandler registry io)
  (export registry-dir
          registry-file
          read-registered
          write-registered!
          remove-registered!
          list-registered-names
          list-registry-files
          registered-exists?)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler sexp)
          (chandler registered))

  ;; ── 路径 ──

  ;; <libdir>/.registry
  (define (registry-dir libdir)
    (join-paths libdir ".registry"))

  ;; <libdir>/.registry/<name>.ss
  ;; name: symbol | string(都接受,文件名取 string 形态)
  (define (registry-file libdir name)
    (let ([name-str (if (symbol? name) (symbol->string name) name)])
      (join-paths (registry-dir libdir) (string-append name-str ".ss"))))

  ;; ── 读 ──

  ;; read-registered : libdir name → registered | #f
  ;; 文件不存在 → #f。文件存在但格式非法 → 抛 datum->registered 的错误。
  (define (read-registered libdir name)
    (let ([path (registry-file libdir name)])
      (and (file-exists? path)
           (datum->registered (read-datum-file path)))))

  ;; registered-exists? : libdir name → bool
  (define (registered-exists? libdir name)
    (file-exists? (registry-file libdir name)))

  ;; ── 写 ──

  ;; write-registered! : libdir name registered → void
  ;; ensure 父目录,canonical 写。
  (define (write-registered! libdir name reg)
    (let ([path (registry-file libdir name)])
      (ensure-parent path)
      (write-canonical-file path (registered->datum reg))))

  ;; remove-registered! : libdir name → void
  ;; 文件不存在静默成功(幂等)。
  (define (remove-registered! libdir name)
    (let ([path (registry-file libdir name)])
      (when (file-exists? path)
        (delete-file path))))

  ;; ── 列举 ──

  ;; list-registered-names : libdir → list of (name-symbol . version-str-active|#f)
  ;; 扫 .registry/ 下所有 <name>.ss,读取 active(app)或首个 version(lib)。
  ;; 单次 list 调用就拿到所有 name 的概览。
  ;; 格式非法的文件跳过 + 写 stderr 警告(doctor 兜底硬错)。
  (define (list-registered-names libdir)
    (let ([d (registry-dir libdir)])
      (if (not (file-directory? d))
          '()
          (filter-map
            (lambda (entry)
              (let ([path (join-paths d entry)])
                (and (file-exists? path)
                     (string-suffix? ".ss" entry)
                     (let* ([name-str (substring entry 0 (- (string-length entry) 3))]
                            [name-sym (string->symbol name-str)])
                       (guard (e [#t
                                  (fprintf (current-error-port)
                                           "warning: skipping malformed registry: ~a~%" path)
                                  #f])
                         (let* ([reg (read-registered libdir name-sym)]
                                [active (and reg (registered-active reg))])
                           (and reg (cons name-sym active))))))))
            (dir-entries d)))))

  ;; list-registry-files : libdir → list of (name-symbol . path)
  ;; 只列 .registry/*.ss 文件,**不解析、不过滤坏文件** —— doctor 用它拿全量
  ;; 列表后自己逐个解析,坏文件才能变成 malformed-registry issue
  ;; (list-registered-names 会把坏文件从结果里剔除,doctor 绝不能走那条路)。
  (define (list-registry-files libdir)
    (let ([d (registry-dir libdir)])
      (if (not (file-directory? d))
          '()
          (filter-map
            (lambda (entry)
              (let ([path (join-paths d entry)])
                (and (string-suffix? ".ss" entry)
                     (file-exists? path)
                     (not (file-directory? path))
                     (cons (string->symbol
                             (substring entry 0 (- (string-length entry) 3)))
                            path))))
            (dir-entries d)))))
  )
