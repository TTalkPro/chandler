#!chezscheme
;;; chandler/test/runtime-paths.ss --- (chandler runtime-paths) 测试
;;;
;;; 2026-07-24:资源定位改为**扫 (library-directories) 的 src/obj 两侧**,不再
;;; 依赖 APP_ROOT。四个旧 API(app-/lib- × 严格/可选)合并为 resource-path /
;;; find-resource-path —— app 就是一个库,不再特殊。

(library (chandler test runtime-paths)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler runtime-paths)
          (chandler layout)
          (chandler util)
          (chandler fs))

  ;; Chez 的 putenv 不能删除变量,清理时以空值恢复未设置状态。
  (define (with-env name val thunk)
    (let ([old (getenv name)])
      (dynamic-wind
        (lambda () (putenv name val))
        thunk
        (lambda () (putenv name (or old ""))))))

  (define (with-app-root root thunk) (with-env "APP_ROOT" root thunk))
  (define (with-app-name name thunk) (with-env "APP_NAME" name thunk))

  ;; 造一个前缀:<root>/src/resources/<ns>/<rel> 写入 content,返回该文件路径
  (define (put-resource! root ns rel content)
    (let ([p (join-paths (prefix-resource-dir root ns) rel)])
      (ensure-parent p)
      (write-file p content)
      p))

  (define (with-temp-dirs n proc)
    (let ([ds (map (lambda (i) (mktmp)) (iota n))])
      (dynamic-wind
        (lambda () (void))
        (lambda () (apply proc ds))
        (lambda () (for-each rm-rf ds)))))

  ;; 把若干前缀挂成 library-directories 的 (src . obj) 对
  (define (with-prefixes prefixes thunk)
    (parameterize ([library-directories (map split-pair prefixes)])
      (thunk)))

  (define-suite suite

    ;; ── 扫 library-directories:src 侧 ──
    (resource-found-on-src-side
      (with-temp-dirs 1
        (lambda (p)
          (let ([f (put-resource! p "myapp" "hello.txt" "hi")])
            (with-prefixes (list p)
              (lambda ()
                (assert-string= f (resource-path '(myapp) "hello.txt"))
                (assert-string= f (find-resource-path '(myapp) "hello.txt"))))))))

    ;; 多段库名 → resources/<a>/<b>/
    (resource-multi-segment-libref
      (with-temp-dirs 1
        (lambda (p)
          (let ([f (put-resource! p "mylib/sub" "schema.json" "{}")])
            (with-prefixes (list p)
              (lambda ()
                (assert-string= f (resource-path '(mylib sub) "schema.json"))))))))

    ;; ── 扫 obj 侧 ──
    ;; 只挂了对象目录的前缀(字符串条目 = src 与 obj 同一)照样命中。
    (resource-found-on-obj-side
      (with-temp-dirs 1
        (lambda (p)
          (let* ([objdir (join-paths p (current-machine-type))]
                 [f (join-paths objdir "resources" "mylib" "data.bin")])
            (ensure-parent f)
            (write-file f "x")
            ;; 条目是 (src . obj) 且两侧不同 —— src 侧没有,必须落到 obj 侧才找得到
            (parameterize ([library-directories (list (split-pair p))])
              (assert-string= f (resource-path '(mylib) "data.bin")))))))

    ;; 字符串条目(src = obj)也要扫到,且不重复尝试同一路径
    (resource-string-entry
      (with-temp-dirs 1
        (lambda (p)
          (let ([f (join-paths p "resources" "mylib" "a.txt")])
            (ensure-parent f)
            (write-file f "x")
            (parameterize ([library-directories (list p)])
              (assert-string= f (resource-path '(mylib) "a.txt")))))))

    ;; ── 条目序即优先级:项目前缀在前,遮蔽全局装的同名库 ──
    (entry-order-is-priority
      (with-temp-dirs 2
        (lambda (proj glob)
          (let ([a (put-resource! proj "mylib" "conf.txt" "project")]
                [b (put-resource! glob "mylib" "conf.txt" "global")])
            (with-prefixes (list proj glob)
              (lambda ()
                (assert-string= a (resource-path '(mylib) "conf.txt"))))
            ;; 反过来挂 → 命中另一个,证明是顺序决定而不是别的
            (with-prefixes (list glob proj)
              (lambda ()
                (assert-string= b (resource-path '(mylib) "conf.txt"))))))))

    ;; 前一个前缀没有就继续找下一个(不是「第一个前缀说了算」)
    (falls-through-to-later-prefix
      (with-temp-dirs 2
        (lambda (empty p)
          (let ([f (put-resource! p "mylib" "only.txt" "x")])
            (with-prefixes (list empty p)
              (lambda ()
                (assert-string= f (resource-path '(mylib) "only.txt"))))))))

    ;; 零 segment → 资源目录本身
    (zero-segments-returns-directory
      (with-temp-dirs 1
        (lambda (p)
          (let ([dir (prefix-resource-dir p "myapp")])
            (ensure-dir dir)
            (with-prefixes (list p)
              (lambda ()
                (assert-string= dir (resource-path '(myapp)))))))))

    ;; ── 不依赖 APP_ROOT ──
    ;; 这是本次改动的要点:APP_ROOT 指向别处、甚至指向一个没有该资源的目录,
    ;; 只要前缀在 library-directories 上就照样命中。
    (does-not-depend-on-app-root
      (with-temp-dirs 2
        (lambda (p elsewhere)
          (let ([f (put-resource! p "myapp" "hello.txt" "hi")])
            (with-app-root elsewhere
              (lambda ()
                (with-prefixes (list p)
                  (lambda ()
                    (assert-string= f (resource-path '(myapp) "hello.txt"))))))))))

    ;; ── 找不到 ──
    (missing-raises-with-search-list
      (with-temp-dirs 1
        (lambda (p)
          (with-prefixes (list p)
            (lambda ()
              (let ([msg (guard (e (#t (condition-message e)))
                           (resource-path '(mylib) "nope.txt")
                           "no error")])
                ;; 报的是「哪个 namespace、搜过哪些前缀」,而不是一句 not found
                (assert-true (string-contains? msg "resources/mylib"))
                (assert-true (string-contains? msg "searched"))))))))

    (missing-find-returns-false
      (with-temp-dirs 1
        (lambda (p)
          (with-prefixes (list p)
            (lambda ()
              (assert-false (find-resource-path '(mylib) "nope.txt")))))))

    ;; ── segment 校验:两个 API 都当场拒,不因「可选」而降级成 #f ──
    (rejects-path-traversal
      (assert-raises (lambda () (resource-path '(mylib) ".." "secret")))
      (assert-raises (lambda () (find-resource-path '(mylib) ".." "secret"))))

    (rejects-absolute-segment
      (assert-raises (lambda () (resource-path '(mylib) "/etc" "passwd")))
      (assert-raises (lambda () (find-resource-path '(mylib) "/etc" "passwd"))))

    (rejects-separator-in-segment
      (assert-raises (lambda () (resource-path '(mylib) "a/b")))
      (assert-raises (lambda () (find-resource-path '(mylib) "a/b"))))

    (rejects-empty-and-dot-segment
      (assert-raises (lambda () (resource-path '(mylib) "")))
      (assert-raises (lambda () (resource-path '(mylib) "."))))

    ;; libref 必须是符号列表 —— 传字符串是最容易犯的错,当场说清
    (rejects-bad-libref
      (assert-raises (lambda () (resource-path "mylib" "a.txt")))
      (assert-raises (lambda () (resource-path '("mylib") "a.txt")))
      (assert-raises (lambda () (find-resource-path 'mylib "a.txt"))))

    ;; ── app-root / app-name:仍在,但**不再参与资源定位** ──
    (app-root-env-set
      (with-app-root "/tmp/some-test-dir"
        (lambda () (assert-string= "/tmp/some-test-dir" (app-root)))))

    (app-root-env-empty
      (with-app-root ""
        (lambda () (assert-true (string? (app-root))))))

    ;; app-name 认「这个前缀属于谁」:.chandler/ 下唯一条目
    (app-name-from-sole-chandler-entry
      (with-temp-dirs 1
        (lambda (root)
          (let ([m (join-paths root ".chandler" "myapp" "manifest.ss")])
            (ensure-parent m)
            (write-file m "(manifest (format 1))")
            (with-app-root root
              (lambda ()
                (with-app-name ""
                  (lambda () (assert-string= "myapp" (app-name))))))))))

    ;; 多个条目(共享前缀装了多个应用)→ 认不出,返回 #f,不猜
    (app-name-ambiguous-when-multiple-entries
      (with-temp-dirs 1
        (lambda (root)
          (for-each
            (lambda (app)
              (let ([m (join-paths root ".chandler" app "manifest.ss")])
                (ensure-parent m)
                (write-file m "(manifest (format 1))")))
            '("a" "b"))
          (with-app-root root
            (lambda ()
              (with-app-name "" (lambda () (assert-false (app-name)))))))))

    (app-name-env-wins
      (with-temp-dirs 1
        (lambda (root)
          (with-app-root root
            (lambda ()
              (with-app-name "explicit"
                (lambda () (assert-string= "explicit" (app-name)))))))))

    ))
