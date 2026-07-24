#!chezscheme
;;; chandler/test/resolve.ss --- (chandler resolve) 测试:mock provider 单测算法 + 真 git 集成

(library (chandler test resolve)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler manifest)
          (chandler lock)
          (chandler fetch)
          (chandler resolve))

  ;; ── mock provider ──
  ;; graph: alist name → (rev (dep-sexpr…) (native-name…))
  (define (make-provider graph)
    (lambda (name sk sl pk pv)
      (if (eq? sk 'path)
          (values #f '() '() #t #f)
          (let ([e (assq name graph)])
            (if e
                (let ([info (cdr e)])
                  (values (list-ref info 0)
                          (deps-from-sexprs (list-ref info 1)) (list-ref info 2) #f #f))
                (values "rev-unknown" '() '() #f #f))))))

  (define (deps-from-sexprs sexprs)
    (manifest-deps (parse-manifest `(manifest (name "x") (version "0") (deps ,@sexprs)))))

  (define (root-mf deps)
    (parse-manifest `(manifest (name "root") (version "0.1.0") (deps ,@deps))))

  (define (root-mf* form) (parse-manifest form))

  (define (names lk) (map locked-dep-name (lock-deps lk)))
  (define (topo-names lk) (map locked-dep-name (topo-order lk)))
  (define (idx lst x)
    (let loop ([lst lst] [i 0])
      (cond [(null? lst) -1] [(eq? (car lst) x) i] [else (loop (cdr lst) (+ i 1))])))

  (define-suite suite
    (linear
      (let* ([g '((a "ra" ((b (git "https://h/b"))) ())
                  (b "rb" () ()))]
             [r (resolve/provider (root-mf '((a (git "https://h/a")))) (make-provider g) '())]
             [lk (resolution-lock r)])
        (assert-equal 2 (length (lock-deps lk)))
        (assert-true (member 'a (names lk)))
        (assert-true (member 'b (names lk)))
        ;; b 被 a 依赖 → topo 中 b 在 a 前
        (assert-true (< (idx (topo-names lk) 'b) (idx (topo-names lk) 'a)))))

    (diamond
      (let* ([g '((a "ra" ((c (git "https://h/c"))) ())
                  (b "rb" ((c (git "https://h/c"))) ())
                  (c "rc" () ()))]
             [r (resolve/provider (root-mf '((a (git "https://h/a")) (b (git "https://h/b"))))
                                  (make-provider g) '())]
             [lk (resolution-lock r)])
        ;; c 只出现一次
        (assert-equal 3 (length (lock-deps lk)))
        (assert-equal 1 (length (filter (lambda (n) (eq? n 'c)) (names lk))))))

    (conflict-same-host-warns
      ;; a 与 b 都依赖 dep,但 pin 不同(同 host)→ 首见胜 + 警告
      (let* ([g '((a "ra" ((dep (git "https://h/dep") (tag "v1"))) ())
                  (b "rb" ((dep (git "https://h/dep") (tag "v2"))) ())
                  (dep "rdep" () ()))]
             [r (resolve/provider (root-mf '((a (git "https://h/a")) (b (git "https://h/b"))))
                                  (make-provider g) '())]
             [lk (resolution-lock r)])
        (assert-equal 1 (length (filter (lambda (n) (eq? n 'dep)) (names lk))))
        (assert-true (> (length (resolution-warnings r)) 0))))

    (conflict-different-host-errors
      (let ([g '((a "ra" ((dep (git "https://h1/dep") (tag "v1"))) ())
                 (b "rb" ((dep (git "https://h2/dep") (tag "v2"))) ())
                 (dep "rdep" () ()))])
        (assert-raises
          (lambda ()
            (resolve/provider (root-mf '((a (git "https://h/a")) (b (git "https://h/b"))))
                              (make-provider g) '())))))

    (root-overrides-transitive-win
      ;; root 直接声明 dep(depth1)→ 压过 a 引入的 dep(depth2)
      (let* ([g '((a "ra" ((dep (git "https://h/dep") (tag "v2"))) ())
                  (dep "rdep-root" () ()))]
             [r (resolve/provider
                  (root-mf '((a (git "https://h/a")) (dep (git "https://h/dep") (tag "v1"))))
                  (make-provider g) '())]
             [lk (resolution-lock r)])
        ;; dep 采用 root 的 pin v1(rev 由 provider 给 dep 键 = rdep-root)
        (let ([d (lock-ref lk 'dep)])
          (assert-equal 'tag (locked-dep-pin-kind d))
          (assert-string= "v1" (locked-dep-pin-val d)))))

    (overrides-metadata-for-bare
      ;; 上游 thunder 无 manifest(provider 返回默认),root override 补 deps
      (let* ([g '((thunder "rt" () ()))]   ; 无子依赖
             [mf (root-mf* '(manifest (name "root") (version "0.1.0")
                              (deps (thunder (git "https://h/thunder")))
                              (overrides (thunder (deps (extra (git "https://h/extra")))))))]
             [g2 (cons '(extra "re" () ()) g)]
             [r (resolve/provider mf (make-provider g2) '())]
             [lk (resolution-lock r)])
        ;; override 注入的 extra 进入闭包
        (assert-true (member 'extra (names lk)))))

    (production-excludes-dev
      (let* ([mf (root-mf* '(manifest (name "root") (version "0.1.0")
                              (deps (a (git "https://h/a")))
                              (dev-deps (t (git "https://h/t")))))]
             [g '((a "ra" () ()) (t "rt" () ()))]
             [prod (resolve/provider mf (make-provider g) '((production . #t)))]
             [dev  (resolve/provider mf (make-provider g) '())])
        (assert-false (member 't (names (resolution-lock prod))))
        (assert-true (member 't (names (resolution-lock dev))))
        ;; dev scope 标注
        (assert-equal 'dev (locked-dep-scope (lock-ref (resolution-lock dev) 't)))))

    (path-excluded-children-included
      ;; path 依赖 mylib 不入 lock,但其子依赖(经 override 提供)入
      (let* ([mf (root-mf* '(manifest (name "root") (version "0.1.0")
                              (deps (mylib (path "../mylib")))
                              (overrides (mylib (deps (sub (git "https://h/sub")))))))]
             [g '((sub "rs" () ()))]
             [r (resolve/provider mf (make-provider g) '())]
             [lk (resolution-lock r)])
        (assert-false (member 'mylib (names lk)))    ; path 不入 lock
        (assert-true (member 'sub (names lk)))))

    (cycle-warns
      (let* ([g '((a "ra" ((b (git "https://h/b"))) ())
                  (b "rb" ((a (git "https://h/a"))) ()))]
             [r (resolve/provider (root-mf '((a (git "https://h/a")))) (make-provider g) '())])
        (assert-true (> (length (resolution-warnings r)) 0))
        (assert-equal 2 (length (lock-deps (resolution-lock r))))))

    ;; ── 真实 git 集成:两级依赖 ──
    (git-integration
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [a (make-lib-repo "a" (list (cons 'b b)))]   ; a 依赖 b
               [mf (root-mf* `(manifest (name "root") (version "0.1.0")
                                (deps (a (git ,a) (branch "main")))))]
               [r (resolve mf)]
               [lk (resolution-lock r)])
          (assert-equal 2 (length (lock-deps lk)))
          (assert-true (member 'a (names lk)))
          (assert-true (member 'b (names lk)))
          ;; rev 是 40 位 hex
          (assert-equal 40 (string-length (locked-dep-rev (lock-ref lk 'a))))))))

  )   ; suite 结束(git 集成 helpers 来自 (chandler test fixtures))
