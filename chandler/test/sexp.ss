#!chezscheme
;;; chandler/test/sexp.ss --- (chandler sexp) 测试

(library (chandler test sexp)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler sexp))

  (define tmp "/tmp/chandler-test-sexp.tmp")

  (define (with-datum-file datum thunk)
    (write-canonical-file tmp datum)
    (thunk))

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
                    (alist->sorted '((c . 3) (a . 1) (b . 2)))))))
