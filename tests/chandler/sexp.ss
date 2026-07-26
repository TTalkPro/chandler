#!chezscheme
;;; tests/chandler/sexp.ss --- (chandler sexp) 测试

(library (tests chandler sexp)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler sexp))

  (define tmp "/tmp/chandler-test-sexp.tmp")

  (define (with-datum-file datum thunk)
    (write-canonical-file tmp datum)
    (thunk))

  ;; 每用例独立临时目录,harness 统一清
  (define tmp-counter 0)
  (define (tmp-dir)
    (set! tmp-counter (+ tmp-counter 1))
    (register-test-tmp!
      (string-append "/tmp/chandler-test-sexp-atomic-"
                     (number->string (get-process-id)) "-"
                     (number->string tmp-counter))))

  (define-suite suite
    (roundtrip-simple
      (with-datum-file '(manifest (name "x") (version "0.1.0"))
        (lambda ()
          (assert-equal '(manifest (name "x") (version "0.1.0"))
                        (read-datum-file tmp)))))

    (canonical-stable
      ;; 同输入两次输出必字节相同
      (let ([d '(lock (format 1) (resolved (a (rev "abc")) (b (rev "def"))))])
        (assert-string= (canonical-string d) (canonical-string d))))

    (canonical-inline-short
      ;; 短叶子列表内联为一行
      (assert-string= "(name \"x\")\n" (canonical-string '(name "x"))))

    (read-rejects-empty
      (call-with-output-file tmp (lambda (p) (display "" p)) 'truncate)
      (assert-raises (lambda () (read-datum-file tmp))))

    (read-rejects-multi
      (call-with-output-file tmp (lambda (p) (display "(a) (b)" p)) 'truncate)
      (assert-raises (lambda () (read-datum-file tmp))))

    (tagged-list
      (assert-true (tagged-list? '(foo 1 2) 'foo))
      (assert-false (tagged-list? '(bar) 'foo))
      (assert-false (tagged-list? 'foo 'foo)))

    (expect-tag-ok
      (assert-equal '((name "x")) (expect-tag '(manifest (name "x")) 'manifest 'test))
      (assert-raises (lambda () (expect-tag '(other) 'manifest 'test))))

    (field-access
      (let ([body '((name "x") (version "0.1.0") (deps (a) (b)))])
        (assert-equal '(name "x") (field body 'name))
        (assert-string= "x" (field-ref body 'name))
        (assert-equal #f (field-ref body 'missing))
        (assert-equal 'fallback (field-ref body 'missing 'fallback))
        (assert-equal '("0.1.0") (field-ref* body 'version))))

    (alist-sorted
      (assert-equal '((a . 1) (b . 2) (c . 3))
                    (alist->sorted '((c . 3) (a . 1) (b . 2)))))

    ;; ── 原子写(temp + rename)──
    (atomic-write-roundtrip
      (let* ([d (tmp-dir)] [f (string-append d "/manifest.ss")]
             [datum '(manifest (name "x") (version "1.0.0") (deps (a (rev "abc"))))])
        (write-canonical-file f datum)
        (assert-equal datum (read-datum-file f))
        ;; 成功后不留 temp 残件
        (assert-equal '("manifest.ss") (directory-list d))))

    (atomic-write-missing-parent
      ;; 父目录不存在时 ensure-parent 生效
      (let* ([d (tmp-dir)] [f (string-append d "/a/b/lock.ss")]
             [datum '(lock (format 1) (resolved (a (rev "abc"))))])
        (write-canonical-file f datum)
        (assert-equal datum (read-datum-file f))))

    (atomic-write-overwrite
      ;; 目标已存在时覆盖写
      (let* ([d (tmp-dir)] [f (string-append d "/registry.ss")])
        (write-canonical-file f '(registry (version 1)))
        (write-canonical-file f '(registry (version 2) (extra "y")))
        (assert-equal '(registry (version 2) (extra "y")) (read-datum-file f))
        (assert-equal '("registry.ss") (directory-list d))))

    (atomic-write-failure-keeps-target
      ;; 写失败(temp 父路径不可建)时抛错,既有目标内容不受影响
      (let* ([d (tmp-dir)] [blocker (string-append d "/blocker")]
             [f (string-append blocker "/x.ss")])
        (write-canonical-file blocker '(registry (version 1)))
        (assert-raises (lambda () (write-canonical-file f '(lock (format 1)))))
        (assert-equal '(registry (version 1)) (read-datum-file blocker))))))
