#!chezscheme
;;; chandler/test/lock.ss --- (chandler lock) 与 (chandler hash) 测试

(library (chandler test lock)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler hash)
          (chandler lock))

  (define (ld name deps natives . scope)
    (make-locked-dep name 'git (string-append "https://x/" (symbol->string name))
                     'tag "v1.0.0" "abcdef0123456789" deps natives
                     (if (null? scope) 'runtime (car scope))
                     #f        ; resources:测试套件按需显式提供
                     #f))      ; v2 provenance

  (define (ldr name deps natives resources . scope)
    (make-locked-dep name 'git (string-append "https://x/" (symbol->string name))
                     'tag "v1.0.0" "abcdef0123456789" deps natives
                     (if (null? scope) 'runtime (car scope))
                     resources
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

    ;; ── resources 字段(designs/11 §6.3 标准化快照)──
    (resources-roundtrip
      (let* ([rs (list (cons '(http) "resources")
                       (cons '(http server) "resources/server"))]
             [lk (make-lock 1 "x" "0.1.0"
                   (list (ldr 'http '() '() rs)))]
             [back (datum->lock (lock->datum lk))])
        (assert-equal rs (locked-dep-resources (lock-ref back 'http)))))

    (resources-absent-roundtrip
      ;; 无 resources 字段的 lock(老文件) → 读回 #f(向后兼容)
      (let* ([lk (make-lock 1 "x" "0.1.0" (list (ld 'http '() '())))]
             [back (datum->lock (lock->datum lk))])
        (assert-false (locked-dep-resources (lock-ref back 'http)))))

    (resources-accessor
      (let ([rs (list (cons '(http) "resources"))])
        (assert-equal rs (locked-dep-resources
                          (ldr 'http '() '() rs)))))))
