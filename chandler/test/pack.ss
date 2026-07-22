#!chezscheme
;;; chandler/test/pack.ss --- (chandler pack) 组装/前置校验测试(designs/09)
;;;
;;; 不捆真运行时:那要求机器上有 skiff/scheme 且拷 8MB 二进制,与「组装逻辑对不对」
;;; 无关。这里钉的是 pack 自己负责的那几件事 —— 布局、依赖挑选、resources 约定、
;;; 启动器契约、清单、前置校验的报错路径 —— 运行时捆绑另由端到端手工验证覆盖。

(library (chandler test pack)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler util)
          (chandler fs)
          (chandler layout)
          (chandler fetch)
          (chandler install)
          (chandler pack))

  (define mt (current-machine-type))

  ;; fixtures' write-file does not create parents; every path here is nested.
  (define (put! path s) (ensure-parent path) (write-file path s))

  ;; 造一个「已经 bake build 过」的应用:_build/<mt>/ 里有 umbrella + 子库对象。
  ;; 内容不必是真 fasl —— pack 只搬运,不加载。
  (define (fake-build! root name)
    (let ([b (join-paths root "_build" mt)])
      (put! (join-paths b (string-append name ".so")) "app-umbrella")
      (put! (join-paths b name "core.so") "app-core")
      b))

  ;; 造一个「chandler build 过」的依赖对象树:lib/<mt>/<dep>{.so,/…}
  (define (fake-dep-objs! root dep)
    (let ([o (join-paths root "lib" mt)])
      (put! (join-paths o (string-append dep ".so")) "dep-umbrella")
      (put! (join-paths o dep "sub.so") "dep-sub")
      o))

  (define (pack-out root name version)
    (join-paths root "dist" (pack-dir-name name version)))

  ;; 组装到 out,不捆运行时:runtime 定位/版本探测要真二进制。故这些用例只调用
  ;; 到「对象树 + resources + 前置校验」这一层,用 assert-raises 兜住运行时那步。
  ;; 能这样切分,是因为 pack 先把对象树落盘、最后才碰运行时。
  (define (pack-until-runtime root opts)
    (guard (e [#t 'runtime-step-skipped]) (pack root opts)))

  (define-suite suite

    ;; ── 布局:每一样平台绑定物都在 <mt> 层下 ──
    (pack-layout-mt-partitioned
      (let* ([app (make-app '())]
             [_ (fake-build! app "myapp")])
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (runtime . petite)))
        (let ([d (pack-out app "myapp" "1.0")])
          (assert-true (file-exists? (join-paths d "lib" mt "myapp.so")))
          (assert-true (file-exists? (join-paths d "lib" mt "myapp" "core.so")))
          ;; 塌缩过的旧布局会把对象直接放 lib/ 下 —— 钉住不回退
          (assert-false (file-exists? (join-paths d "lib" "myapp.so"))))))

    ;; ── 依赖:按 lock 精确挑,不整棵拷 lib/<mt>/ ──
    ;; 那目录里可能留着上一轮 `chandler build` 同步进去的**旧应用产物**;整棵拷会让
    ;; 它覆盖掉刚 bake build 出来的新的,包能跑但跑的是旧代码。
    (pack-deps-picked-by-lock-not-whole-tree
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (fake-build! app "myapp")
          (fake-dep-objs! app "b")
          ;; lib/<mt>/ 里塞一份**同名的陈旧应用产物**:必须被新的覆盖,而不是反过来
          (put! (join-paths app "lib" mt "myapp.so") "STALE")
          (pack-until-runtime app '((name . "myapp") (version . "1.0") (runtime . petite)))
          (let ([d (pack-out app "myapp" "1.0")])
            (assert-string= "app-umbrella" (read-file (join-paths d "lib" mt "myapp.so")))
            (assert-true (file-exists? (join-paths d "lib" mt "b.so")))
            (assert-true (file-exists? (join-paths d "lib" mt "b" "sub.so")))))))

    ;; lib/<mt>/ 里没被 lock 声明的东西不进包(陈旧残留不该随包发出去)
    (pack-undeclared-namespace-not-shipped
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (fake-build! app "myapp")
          (fake-dep-objs! app "b")
          (put! (join-paths app "lib" mt "ghost.so") "leftover")
          (pack-until-runtime app '((name . "myapp") (version . "1.0") (runtime . petite)))
          (assert-false
            (file-exists? (join-paths (pack-out app "myapp" "1.0") "lib" mt "ghost.so"))))))

    ;; ── resources/:名字约定死,存在即打包,在 <mt> 层之上 ──
    (pack-resources-by-convention
      (let* ([app (make-app '())])
        (fake-build! app "myapp")
        (put! (join-paths app "resources" "greeting.txt") "res-hello")
        (put! (join-paths app "resources" "sub" "nested.txt") "nested")
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (runtime . petite)))
        (let ([d (pack-out app "myapp" "1.0")])
          (assert-string= "res-hello" (read-file (join-paths d "resources" "greeting.txt")))
          (assert-true (file-exists? (join-paths d "resources" "sub" "nested.txt")))
          ;; 数据不带 ABI → 不该落进 <mt> 层(也就不会进库搜索根)
          (assert-false (file-exists? (join-paths d "lib" mt "resources"))))))

    (pack-no-resources-dir-is-fine
      (let* ([app (make-app '())])
        (fake-build! app "myapp")
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (runtime . petite)))
        (assert-false (file-exists? (join-paths (pack-out app "myapp" "1.0") "resources")))))

    ;; ── 前置校验:pack 只组装,缺件必须当场说清该跑哪个命令 ──
    (pack-requires-app-build
      (let ([app (make-app '())])                 ; 没有 _build/<mt>/
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (runtime . petite)))))))

    (pack-requires-dep-objects
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (fake-build! app "myapp")
          (rm-rf (join-paths app "lib" mt))       ; 依赖没编译 → 该跑 chandler build
          (assert-raises
            (lambda () (pack app '((name . "myapp") (version . "1.0") (runtime . petite))))))))

    ;; 依赖声明了 native 却不在树里:native 无法在消费方现编,故必须当场停 ——
    ;; 否则打出的包一路正常,直到第一次 foreign call 才炸。
    (pack-missing-declared-native-stops
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))])
          (install app '())
          (fake-build! app "myapp")
          (fake-dep-objs! app "n")                ; 有对象,但没有 n/native/libn.<ext>
          (assert-raises
            (lambda () (pack app '((name . "myapp") (version . "1.0") (runtime . petite))))))))

    ;; ── 不支持的配置在**配置期**报,别让人跑完组装才发现 ──
    (pack-boot-mode-not-implemented
      (let ([app (make-app '())])
        (fake-build! app "myapp")
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (mode . boot)))))))

    (pack-unknown-runtime-rejected
      (let ([app (make-app '())])
        (fake-build! app "myapp")
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (runtime . guile)))))))

    ;; ── verify-pack:清单缺失即报错(完整路径由端到端覆盖)──
    (verify-pack-needs-a-manifest
      (assert-raises (lambda () (verify-pack (mktmp)))))))
