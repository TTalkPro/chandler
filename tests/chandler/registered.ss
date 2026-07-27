#!chezscheme
;;; tests/chandler/registered.ss --- (chandler registered) 测试

(library (tests chandler registered)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler registered))

  (define-suite suite

    ;; ── 构造 ──

    (make-registered-defaults
      (let ([r (make-registered 'myapp 'app)])
        (assert-true (registered? r))
        (assert-equal 'myapp (registered-name r))
        (assert-equal 'app (registered-kind r))
        (assert-equal '() (registered-versions r))
        (assert-false (registered-active r))))

    (make-registered-with-versions
      (let ([e (make-version-entry "1.0.0" "2026-07-25T10:00:00" '(path "/proj") 'chandler)])
        (let ([r (make-registered 'lib 'lib (list (cons "1.0.0" e)))])
          (assert-equal 1 (length (registered-versions r)))
          (assert-true (registered-has-version? r "1.0.0")))))

    (make-registered-bad-name
      (assert-raises (lambda () (make-registered "myapp" 'app)))    ; string, not symbol
      (assert-raises (lambda () (make-registered 'myapp 'foo))))    ; bad kind

    (make-registered-bad-active
      (assert-raises (lambda () (make-registered 'myapp 'app '() "")))  ; empty
      (assert-raises (lambda () (make-registered 'myapp 'app '() 42)))  ; not string/#f

      ;; active 指向不存在的 version —— 构造允许(set-active 才校验);
      ;; 但 datum->registered 会校验,见下。
      (let ([r (make-registered 'myapp 'app '() "9.9.9")])
        (assert-equal "9.9.9" (registered-active r))))

    (make-version-entry-basic
      (let ([e (make-version-entry "1.0.0" "2026-07-25" '(path "/x") 'chandler)])
        (assert-true (version-entry? e))
        (assert-string= "1.0.0" (version-entry-version e))
        (assert-string= "2026-07-25" (version-entry-installed-at e))
        (assert-equal '(path "/x") (version-entry-source e))
        (assert-equal 'chandler (version-entry-installer e))))

    (make-version-entry-bad-source
      (assert-raises (lambda () (make-version-entry "1.0.0" "..." '(unknown "/x") 'chandler)))
      (assert-raises (lambda () (make-version-entry "1.0.0" "..." 'not-a-pair 'chandler)))
      (assert-raises (lambda () (make-version-entry "1.0.0" "..." '(path "/x") "chandler"))))

    (make-version-entry-empty-version
      (assert-raises (lambda () (make-version-entry "" "..." '(path "/x") 'chandler))))

    ;; ── 查询 ──

    (has-version-found-and-missing
      (let* ([e (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [r (make-registered 'myapp 'app (list (cons "1.0.0" e)))])
        (assert-true (registered-has-version? r "1.0.0"))
        (assert-false (registered-has-version? r "2.0.0"))))

    ;; ── 函数式更新:add ──

    (add-version-new-appends
      (let* ([r0 (make-registered 'myapp 'app)]
             [e1 (make-version-entry "1.0.0" "t1" '(path "/a") 'chandler)]
             [e2 (make-version-entry "2.0.0" "t2" '(path "/b") 'chandler)]
             [r1 (registered-add-version r0 e1)]
             [r2 (registered-add-version r1 e2)])
        (assert-equal 2 (length (registered-versions r2)))
        ;; 插入序:1.0.0 在前
        (assert-string= "1.0.0" (version-entry-version (cdar (registered-versions r2))))))

    (add-version-existing-replaces
      (let* ([e1 (make-version-entry "1.0.0" "old" '(path "/a") 'chandler)]
             [r0 (make-registered 'myapp 'app (list (cons "1.0.0" e1)))]
             [e2 (make-version-entry "1.0.0" "new" '(path "/b") 'chandler)]
             [r1 (registered-add-version r0 e2)])
        (assert-equal 1 (length (registered-versions r1)))
        (assert-string= "new" (version-entry-installed-at
                                (cdar (registered-versions r1))))))

    (add-version-preserves-active
      (let* ([e1 (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [r0 (make-registered 'myapp 'app (list (cons "1.0.0" e1)) "1.0.0")]
             [e2 (make-version-entry "2.0.0" "..." '(path "/y") 'chandler)]
             [r1 (registered-add-version r0 e2)])
        (assert-string= "1.0.0" (registered-active r1))))

    (add-version-bad-entry
      (assert-raises (lambda () (registered-add-version (make-registered 'a 'app) "not-an-entry"))))

    ;; ── 函数式更新:remove ──

    (remove-version-basic
      (let* ([e1 (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [e2 (make-version-entry "2.0.0" "..." '(path "/y") 'chandler)]
             [r0 (make-registered 'myapp 'app
                                  (list (cons "1.0.0" e1) (cons "2.0.0" e2)))])
        (let ([r1 (registered-remove-version r0 "1.0.0")])
          (assert-false (registered-has-version? r1 "1.0.0"))
          (assert-true (registered-has-version? r1 "2.0.0")))))

    (remove-active-clears-active
      ;; 删 active version → active 自动清空
      (let* ([e1 (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [r0 (make-registered 'myapp 'app (list (cons "1.0.0" e1)) "1.0.0")]
             [r1 (registered-remove-version r0 "1.0.0")])
        (assert-false (registered-active r1))))

    (remove-non-active-keeps-active
      (let* ([e1 (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [e2 (make-version-entry "2.0.0" "..." '(path "/y") 'chandler)]
             [r0 (make-registered 'myapp 'app
                                  (list (cons "1.0.0" e1) (cons "2.0.0" e2)) "1.0.0")]
             [r1 (registered-remove-version r0 "2.0.0")])
        (assert-string= "1.0.0" (registered-active r1))))

    (remove-missing-is-noop
      (let ([r0 (make-registered 'myapp 'app)])
        (let ([r1 (registered-remove-version r0 "9.9.9")])
          (assert-equal '() (registered-versions r1)))))

    ;; ── 函数式更新:set-active ──

    (set-active-basic
      (let* ([e1 (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [r0 (make-registered 'myapp 'app (list (cons "1.0.0" e1)))]
             [r1 (registered-set-active r0 "1.0.0")])
        (assert-string= "1.0.0" (registered-active r1))))

    (set-active-switch
      (let* ([e1 (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [e2 (make-version-entry "2.0.0" "..." '(path "/y") 'chandler)]
             [r0 (make-registered 'myapp 'app
                                  (list (cons "1.0.0" e1) (cons "2.0.0" e2)) "1.0.0")]
             [r1 (registered-set-active r0 "2.0.0")])
        (assert-string= "2.0.0" (registered-active r1))))

    (set-active-missing-errors
      (let ([r0 (make-registered 'myapp 'app)])
        (assert-raises (lambda () (registered-set-active r0 "9.9.9")))))

    (set-active-on-lib-errors
      (let* ([e (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [r0 (make-registered 'mylib 'lib (list (cons "1.0.0" e)))])
        (assert-raises (lambda () (registered-set-active r0 "1.0.0")))))

    ;; ── 序列化 ──

    (datum-roundtrip-app
      (let* ([e1 (make-version-entry "1.0.0" "2026-07-25T10:00:00" '(path "/proj/myapp") 'chandler)]
             [e2 (make-version-entry "2.0.0" "2026-07-26T11:00:00" '(git "https://github.com/x/myapp") 'chandler)]
             [r0 (make-registered 'myapp 'app
                                  (list (cons "1.0.0" e1) (cons "2.0.0" e2)) "1.0.0")])
        (let* ([d (registered->datum r0)]
               [r1 (datum->registered d)])
          (assert-true (registered? r1))
          (assert-equal 'myapp (registered-name r1))
          (assert-equal 'app (registered-kind r1))
          (assert-equal 2 (length (registered-versions r1)))
          (assert-true (registered-has-version? r1 "1.0.0"))
          (assert-true (registered-has-version? r1 "2.0.0"))
          (assert-string= "1.0.0" (registered-active r1)))))

    (datum-roundtrip-lib-no-active
      (let* ([e (make-version-entry "1.0.0" "..." '(path "/x") 'chandler)]
             [r0 (make-registered 'mylib 'lib (list (cons "1.0.0" e)))])
        (let* ([d (registered->datum r0)]
               [r1 (datum->registered d)])
          (assert-equal 'lib (registered-kind r1))
          (assert-false (registered-active r1)))))

    (datum-lib-with-active-errors
      ;; lib 不允许 (active ...),datum->registered 拒绝
      (let ([bad-datum '(registered (format 1) (name mylib) (kind lib)
                                    (versions ("1.0.0" (installed-at "x") (source (path "/y")) (installer chandler)))
                                    (active "1.0.0"))])
        (assert-raises (lambda () (datum->registered bad-datum)))))

    (datum-active-missing-errors
      ;; (active "9.9.9") 但 versions 里没有
      (let ([bad-datum '(registered (format 1) (name myapp) (kind app)
                                    (versions ("1.0.0" (installed-at "x") (source (path "/y")) (installer chandler)))
                                    (active "9.9.9"))])
        (assert-raises (lambda () (datum->registered bad-datum)))))

    (datum-bad-format-errors
      (let ([bad-datum '(registered (format 2) (name myapp) (kind app) (versions))])
        (assert-raises (lambda () (datum->registered bad-datum))))
      (let ([bad-datum '(registered (name myapp) (kind app) (versions))])  ; 缺 format
        (assert-raises (lambda () (datum->registered bad-datum)))))

    (datum-missing-name-errors
      (let ([bad-datum '(registered (format 1) (kind app) (versions))])
        (assert-raises (lambda () (datum->registered bad-datum)))))

    (datum-bad-tag-errors
      (assert-raises (lambda () (datum->registered '(not-registered))))
      (assert-raises (lambda () (datum->registered 42))))

    (datum-version-entry-bad
      ;; version 字符串不在首位
      (let ([bad-datum '(registered (format 1) (name myapp) (kind app)
                                    (versions (42 (installed-at "x") (source (path "/y")) (installer chandler))))])
        (assert-raises (lambda () (datum->registered bad-datum)))))

    (datum-source-kinds
      ;; 三种 source 形态都接受
      (for-each
        (lambda (src)
          (let* ([e (make-version-entry "1.0.0" "..." src 'chandler)]
                 [r (make-registered 'x 'app (list (cons "1.0.0" e)))])
            (let ([d (registered->datum r)])
              (assert-true (registered? (datum->registered d))))))
        (list '(path "/x") '(git "https://x") '(pack "/tmp/p.tar.gz"))))

    ;; ── format 校验(对齐 manifest 的友好模式)──

    (datum-format-too-new-raises
      ;; format > supported:仍拒绝(消息改为 "newer than ...; upgrade chandler",
      ;; 对齐 manifest.ss:175;此前是低级的 "unsupported format; want 1")
      (let ([bad-datum '(registered (format 99) (name myapp) (kind app) (versions))])
        (assert-raises (lambda () (datum->registered bad-datum)))))

    (datum-format-missing-raises
      ;; format 缺失:拒绝(registered datum 必须有 format 字段,序列化总写)
      (let ([bad-datum '(registered (name myapp) (kind app) (versions))])
        (assert-raises (lambda () (datum->registered bad-datum)))))

    ))
