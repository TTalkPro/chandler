#!chezscheme
;;; tests/chandler/lock.ss --- (chandler lock) 与 (chandler hash) 测试

(library (tests chandler lock)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler hash)
          (chandler sexp)
          (chandler lock))

  (define (ld name deps natives . scope)
    (make-locked-dep name 'git (string-append "https://x/" (symbol->string name))
                     'tag "v1.0.0" "abcdef0123456789" deps natives
                     (if (null? scope) 'runtime (car scope))
                     #f))      ; v2 provenance

  (define sample
    (make-lock 1 "deadbeef" "0.1.0"
      (list (ld 'http '(json uri) '(llhttp))
            (ld 'json '() '())
            (ld 'uri '(json) '()))))

  (define (index-of lst x)
    (let loop ([lst lst] [i 0])
      (cond [(null? lst) -1]
            [(eq? (car lst) x) i]
            [else (loop (cdr lst) (+ i 1))])))

  (define-suite suite
    ;; ── hash ──
    (sha256-empty
      (assert-string= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                      (sha256-string "")))
    (sha256-abc
      (assert-string= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                      (sha256-string "abc")))
    (sha256-fox
      (assert-string= "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
                      (sha256-string "The quick brown fox jumps over the lazy dog")))

    ;; ── lock round-trip ──
    (lock-roundtrip
      (let* ([datum (lock->datum sample)]
             [back  (datum->lock datum)])
        (assert-equal 3 (length (lock-deps back)))
        (let ([h (lock-ref back 'http)])
          (assert-equal 'http (locked-dep-name h))
          (assert-equal '(json uri) (locked-dep-deps h))
          (assert-equal '(llhttp) (locked-dep-natives h))
          (assert-string= "abcdef0123456789" (locked-dep-rev h)))))

    ;; ── canonical 字节稳定 ──
    (lock-write-stable
      (let ([p1 "/tmp/chandler-lock-1.tmp"] [p2 "/tmp/chandler-lock-2.tmp"])
        (write-lock p1 sample)
        (write-lock p2 sample)
        (assert-string= (sha256-file p1) (sha256-file p2))))

    ;; resolved 项按名字典序输出(http < json < uri;此处验证首个是 http)
    (lock-sorted-output
      (let ([datum (lock->datum sample)])
        (let ([resolved (cdr (assq 'resolved (cdr datum)))])
          (assert-equal 'http (caar resolved)))))

    ;; ── 拓扑序:被依赖先(json 在 http/uri 之前;uri 在 http 之前)──
    (topo-basic
      (let ([order (map locked-dep-name (topo-order sample))])
        (assert-true (< (index-of order 'json) (index-of order 'http)))
        (assert-true (< (index-of order 'json) (index-of order 'uri)))
        (assert-true (< (index-of order 'uri) (index-of order 'http)))))

    ;; ── 成环不死循环 ──
    (topo-cycle-terminates
      (let ([cyclic (make-lock 1 "x" "0.1.0"
                      (list (ld 'a '(b) '()) (ld 'b '(a) '())))])
        (assert-equal 2 (length (topo-order cyclic)))))

    (dev-scope-preserved
      (let* ([lk (make-lock 1 "x" "0.1.0" (list (ld 'test '() '() 'dev)))]
             [back (datum->lock (lock->datum lk))])
        (assert-equal 'dev (locked-dep-scope (lock-ref back 'test)))))

    ;; ── resources 字段已删(designs/09 §6)──
    ;; v3 的资源靠 method B 目录约定定位,lock 里没有可记的东西。
    ;; 契约是**旧 lock 的 (resources …) 读取时静默忽略**(降低升级摩擦):
    ;; 既不报错,也不影响其余字段。
    (old-lock-resources-field-silently-ignored
      (let ([back (datum->lock
                    '(lock (format 1) (manifest-sha256 "x") (chandler "0.1.0")
                       (resolved
                         (http (source (git "https://x/http")) (pin (tag "v1.0.0"))
                               (rev "abcdef0123456789") (deps) (natives)
                               (resources ((http) "resources")
                                          ((http server) "resources/server"))))))])
        (let ([d (lock-ref back 'http)])
          ;; 其余字段照常解析,不被那个陌生字段带偏
          (assert-equal 'http (locked-dep-name d))
          (assert-string= "abcdef0123456789" (locked-dep-rev d))
          (assert-string= "https://x/http" (locked-dep-source-loc d))
          (assert-equal 'runtime (locked-dep-scope d)))))

    ;; 畸形的旧 resources 同样不该炸 —— 现在根本不解析它。
    ;; (先前 parse-locked-resources 会对形状不符的项报错,而这个字段永远不由我们写出。)
    (old-lock-malformed-resources-does-not-raise
      (let ([back (datum->lock
                    '(lock (format 1) (manifest-sha256 "x") (chandler "0.1.0")
                       (resolved
                         (http (source (git "https://x/http")) (pin (tag "v1.0.0"))
                               (rev "abcdef0123456789") (deps) (natives)
                               (resources "not-a-pair" 42)))))])
        (assert-string= "abcdef0123456789" (locked-dep-rev (lock-ref back 'http)))))

    ;; 我们自己写出的 lock 里不再出现 (resources …)
    (written-lock-has-no-resources-field
      (let ([txt (canonical-string
                   (lock->datum (make-lock 1 "x" "0.1.0" (list (ld 'http '() '())))))])
        (assert-false (substr? txt "resources"))))

    ;; ── v3 files 字段(D15)──

    (files-default-empty
      ;; 4-arg make-lock → files 缺省为 '()
      (let ([lk (make-lock 1 "x" "0.1.0" '())])
        (assert-equal '() (lock-files lk))))

    (files-explicit
      (let* ([fls (list (cons "src/a.ss" "h1") (cons "ta6le/a.so" "h2"))]
             [lk (make-lock 1 "x" "0.1.0" '() fls)])
        (assert-equal 2 (length (lock-files lk)))
        (assert-equal fls (lock-files lk))))

    (files-with-files
      (let* ([lk0 (make-lock 1 "x" "0.1.0" '())]
             [fls (list (cons "src/a.ss" "h1"))]
             [lk1 (with-files lk0 fls)])
        (assert-equal fls (lock-files lk1))))

    (files-sha256-lookup
      (let* ([fls (list (cons "src/a.ss" "h1") (cons "ta6le/a.so" "h2"))]
             [lk (make-lock 1 "x" "0.1.0" '() fls)])
        (assert-string= "h1" (lock-file-sha256 lk "src/a.ss"))
        (assert-string= "h2" (lock-file-sha256 lk "ta6le/a.so"))
        (assert-false (lock-file-sha256 lk "missing"))))

    (files-roundtrip
      (let* ([fls (list (cons "src/myapp.ss" "deadbeef")
                          (cons "ta6le/myapp.so" "cafebabe")
                          (cons "src/myapp/resources/hello.txt" "1234abcd"))]
             [lk0 (make-lock 1 "abcdef" ">=0.1.4" '() fls)]
             [d (lock->datum lk0)]
             [lk1 (datum->lock d)])
        (assert-equal fls (lock-files lk1))))

    (files-empty-not-in-datum
      ;; 空 files → datum 里不写 (files ...)
      (let* ([lk (make-lock 1 "x" "0.1.0" '())]
             [d (lock->datum lk)])
        (assert-false (and (pair? d) (memq 'files (map car (cdr d)))))))

    (files-v2-backcompat
      ;; v2 lock 无 files 字段 → 读回 '()
      (let* ([v2-datum '(lock (format 1) (manifest-sha256 "abc") (chandler ">=0.1")
                              (resolved (mylib (source (git "https://x"))
                                               (pin (tag "v1")) (rev "abc")
                                               (deps) (natives))))]
             [lk (datum->lock v2-datum)])
        (assert-equal '() (lock-files lk))))

    (files-bad-entry
      (let ([bad-datum '(lock (format 1) (manifest-sha256 "x") (chandler "x")
                              (resolved)
                              (files (not-a-string (sha256 "x"))))])
        (assert-raises (lambda () (datum->lock bad-datum))))
       (let ([bad-datum '(lock (format 1) (manifest-sha256 "x") (chandler "x")
                               (resolved)
                               (files ("a.ss" (not-sha256 "x"))))])
        (assert-raises (lambda () (datum->lock bad-datum)))))

    ;; ── format 校验(对齐 manifest/registered 的友好模式)──

    (lock-format-too-new-raises
      ;; format > supported:拒绝(此前 datum->lock 完全不校验 —— format 99 静默通过,
      ;; lock-format 返回 99,下游无感知。这是 bug fix)
      (let ([bad-datum '(lock (format 99) (manifest-sha256 "x") (chandler "0.1.0") (resolved))])
        (assert-raises (lambda () (datum->lock bad-datum)))))

    (lock-format-missing-defaults-to-1
      ;; format 缺失:向后兼容,回 1(老 lock 文件没有 format 字段)
      (let ([d '(lock (manifest-sha256 "x") (chandler "0.1.0") (resolved))])
        (let ([lk (datum->lock d)])
          (assert-true (lock? lk))
          (assert-equal 1 (lock-format lk)))))))

