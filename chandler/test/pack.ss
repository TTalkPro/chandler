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
          (chandler lock)
          (chandler runtime-detector)
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
  ;; C0:依赖的对象在**它自己的** _vendor/<dep>/_build/<mt>/,不再有汇总的 lib/<mt>/
  (define (fake-dep-objs! root dep)
    (let ([o (join-paths root "_vendor" dep "_build" mt)])
      (put! (join-paths o (string-append dep ".so")) "dep-umbrella")
      (put! (join-paths o dep "sub.so") "dep-sub")
      o))

  (define (pack-out root name version)
    (join-paths root "dist" (pack-dir-name name version)))

  ;; v2 nested layout:app 载荷在 <pack>/<name>/<version>/ 下;
  ;; dep 在 <pack>/<dep>/<pin>/ 下(pin = lock 里的 pin-val,fixture 依赖走 (branch "main"))。
  (define (app-vroot app name version)
    (join-paths (pack-out app name version) name version))

  (define (dep-pin app dep)
    (locked-dep-pin-val (lock-ref (read-lock (project-lock-path app)) dep)))

  (define (dep-vroot app d dep)
    (join-paths d (symbol->string dep) (dep-pin app dep)))

  ;; 组装到 out,不捆运行时:runtime 定位/版本探测要真二进制。故这些用例只调用
  ;; 到「对象树 + resources + 前置校验」这一层,用 assert-raises 兜住运行时那步。
  ;; 能这样切分,是因为 pack 先把对象树落盘、最后才碰运行时。
  (define (pack-until-runtime root opts)
    (guard (e [#t 'runtime-step-skipped]) (pack root opts)))

  (define-suite suite

    ;; ── 布局:v2 nested —— 应用对象树落 <pack>/<name>/<version>/<mt>/
    ;; (与全局安装前缀 <prefix>/<name>/<version>/{src,<mt>} 逐层同构)──
    (pack-layout-mt-partitioned
      (let* ([app (make-app '())]
             [_ (fake-build! app "myapp")])
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (let ([d (pack-out app "myapp" "1.0")]
              [vr (app-vroot app "myapp" "1.0")])
          (assert-true (file-exists? (join-paths vr mt "myapp.so")))
          (assert-true (file-exists? (join-paths vr mt "myapp" "core.so")))
          ;; 塌缩过的旧布局:<pack>/<mt>/ 直接挂包根 —— 钉住不回退
          (assert-false (file-exists? (join-paths d mt "myapp.so")))
          (assert-false (file-exists? (join-paths d "myapp.so")))
          ;; 旧的 lib/ 前缀已去掉 —— 钉住不回潮
          (assert-false (file-exists? (join-paths d "lib" mt "myapp.so"))))))

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
          (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
          (let ([d (pack-out app "myapp" "1.0")]
                [bvr (dep-vroot app (pack-out app "myapp" "1.0") 'b)])
            (assert-string= "app-umbrella" (read-file (join-paths d "myapp" "1.0" mt "myapp.so")))
            (assert-true (file-exists? (join-paths bvr mt "b.so")))
            (assert-true (file-exists? (join-paths bvr mt "b" "sub.so")))))))

    ;; lib/<mt>/ 里没被 lock 声明的东西不进包(陈旧残留不该随包发出去)
    (pack-undeclared-namespace-not-shipped
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (fake-build! app "myapp")
          (fake-dep-objs! app "b")
          (put! (join-paths app "lib" mt "ghost.so") "leftover")
          (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
          (assert-false
            (file-exists? (join-paths (pack-out app "myapp" "1.0") "myapp" "1.0" mt "ghost.so"))))))

    ;; ── 应用资源:源目录名约定死(<project>/resources/),**原样**搬进
    ;; <pack>/<name>/<version>/src/resources/ —— <libpath>/ 那层已在 resources/ 里
    ;; (与依赖资源、与 dev 期 resource-path 扫描同一约定);数据不带 ABI,落 src/ 层不进 <mt>。──
    (pack-resources-by-convention
      (let* ([app (make-app '())])
        (fake-build! app "myapp")
        ;; 项目自己的库 (myapp) 的资源摆在 resources/myapp/(与 dev 期读的路径一致)
        (put! (join-paths app "resources" "myapp" "greeting.txt") "res-hello")
        (put! (join-paths app "resources" "myapp" "sub" "nested.txt") "nested")
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (let ([vr (app-vroot app "myapp" "1.0")])
          ;; verbatim:resources/myapp/… → <name>/<version>/src/resources/myapp/…(不再多套一层 <app>)
          (assert-string= "res-hello" (read-file (join-paths vr "src" "resources" "myapp" "greeting.txt")))
          (assert-true (file-exists? (join-paths vr "src" "resources" "myapp" "sub" "nested.txt")))
          ;; 不该出现 dev 期读不到的双层 src/resources/myapp/myapp/
          (assert-false (file-exists? (join-paths vr "src" "resources" "myapp" "myapp")))
          ;; 数据不带 ABI → 不该落进 <mt> 层(也就不会进库搜索根)
          (assert-false (file-exists? (join-paths vr mt "resources"))))))

    (pack-no-resources-dir-is-fine
      (let* ([app (make-app '())])
        (fake-build! app "myapp")
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (let ([vr (app-vroot app "myapp" "1.0")])
          (assert-false (file-exists? (join-paths vr "resources")))
          (assert-false (file-exists? (join-paths vr "src" "resources"))))))

    ;; ── <name>/<version>/.chandler/chandler-manifest.ss:清单快照,与全局 install 落点
    ;; 同构;也是 app-resource-path 认出应用名的依据(包里恒只有一个条目)──
    (pack-writes-app-manifest-snapshot
      (let* ([app (make-app '())])
        (fake-build! app "myapp")
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (let* ([vr (app-vroot app "myapp" "1.0")]
               [m (join-paths vr ".chandler" "chandler-manifest.ss")])
          (assert-true (file-exists? m))
          (assert-true (has? (read-file m) "(manifest")))))

    ;; 源项目没有 chandler-manifest.ss(--name/--entry 临时打包)→ 合成一份最小清单,
    ;; 应用名照样可解析
    (pack-app-manifest-synthesized-without-source-manifest
      (let ([app (make-app '())])
        (fake-build! app "myapp")
        (delete-file (join-paths app "chandler-manifest.ss"))
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (let ([m (join-paths (app-vroot app "myapp" "1.0") ".chandler" "chandler-manifest.ss")])
          (assert-true (file-exists? m))
          (assert-true (has? (read-file m) "(name \"myapp\")")))))

    ;; ── pack.manifest:路径字段跟随 P1 布局(去 lib/ 前缀)──
    ;; 清单在**运行时捆绑之后**才写,没有 scheme/skiff 的机器上 pack-until-runtime
    ;; 会在那一步 bail —— 那时无清单可查,故断言挂在「清单已生成」之下。
    (pack-manifest-lib-dirs-without-lib-prefix
      (let* ([app (make-app '())]
             [_ (fake-build! app "myapp")])
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (let ([m (join-paths (pack-out app "myapp" "1.0") "pack.manifest")])
          (when (file-exists? m)
            (let ([s (read-file m)])
              (assert-true (has? s (string-append "(lib-dirs \"" mt "\")")))
              (assert-false (has? s "(lib-dirs \"lib/")))))))

    ;; native 落点同样去掉 lib/ 前缀:清单里的相对路径必须指得到包里那个文件
    ;; (v2 nested:<pack>/<dep>/<pin>/<mt>/<lib>/native/<soname>)
    (pack-manifest-native-paths-without-lib-prefix
      (parameterize ([cache-root (mktmp)])
        (let* ([n (make-native-lib "n" "libn")]
               [app (make-app (list (cons 'n n)))])
          (install app '())
          (fake-build! app "myapp")
          (fake-dep-objs! app "n")
          (put! (join-paths app "_vendor" "n" "_build" mt "n" "native" (string-append "libn." (so-ext))) "ELF")
          (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
          (let* ([d (pack-out app "myapp" "1.0")]
                 [nvr (dep-vroot app d 'n)]
                 [m (join-paths d "pack.manifest")])
            (assert-true (file-exists? (join-paths nvr mt "n" "native" (string-append "libn." (so-ext)))))
            (when (file-exists? m)
              (let ([s (read-file m)])
                (assert-true (has? s (string-append "(libn \"n/" (dep-pin app 'n) "/" mt "/n/native/libn." (so-ext) "\")")))
                (assert-false (has? s "\"lib/"))))))))

    ;; ── 前置校验:pack 只组装,缺件必须当场说清该跑哪个命令 ──
    (pack-requires-app-build
      (let ([app (make-app '())])                 ; 没有 _build/<mt>/
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))))))

    (pack-requires-dep-objects
      (parameterize ([cache-root (mktmp)])
        (let* ([b (make-lib-repo "b")]
               [app (make-app (list (cons 'b b)))])
          (install app '())
          (fake-build! app "myapp")
          (rm-rf (join-paths app "_vendor" "b" "_build" mt))       ; 依赖没编译 → 该跑 chandler build
          (assert-raises
            (lambda () (pack app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite))))))))

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
            (lambda () (pack app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite))))))))

    (pack-unknown-runtime-rejected
      (let ([app (make-app '())])
        (fake-build! app "myapp")
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . guile)))))))

    ;; ── 入口库:必须在**打包期**校验,不能等到启动 ──
    ;; 曾经的 bug:`chandler pack` 把 manifest 的 `name`(包名)当入口库名,而 skiff-demo
    ;; 的包名是 skiff-demo、入口库是 (mdserver) —— 打包"成功",跑起来才
    ;; `library (skiff-demo) not found`。
    (pack-wrong-entry-fails-at-pack-time
      (let ([app (make-app '())])
        (fake-build! app "myapp")
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (runtime . petite)
                                 (entry . (nosuch))))))
        ;; 半成品包不许留下
        (assert-false (file-exists? (pack-out app "myapp" "1.0")))))

    ;; 包名 ≠ 入口库名:--entry 显式覆盖 manifest 默认;入口库的对象必须真的进包
    (pack-entry-from-explicit-flag
      (let ([app (make-app '())])
        (fake-build! app "notthename")
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (notthename)) (runtime . petite)))
        (assert-true
          (file-exists? (join-paths (pack-out app "myapp" "1.0") "myapp" "1.0" mt "notthename.so")))))

    ;; 无 (app ...) 声明 + 未传 --entry → 拒绝(防止 lib 被悄声打成 app 包)
    (pack-rejects-lib-without-entry
      (let ([app (make-app '())])
        (fake-build! app "myapp")
        (assert-raises
          (lambda () (pack app '((name . "myapp") (version . "1.0") (runtime . petite)))))))

    ;; ── verify-pack:清单缺失即报错(完整路径由端到端覆盖)──
    (verify-pack-needs-a-manifest
      (assert-raises (lambda () (verify-pack (mktmp)))))

    ;; ── verify-pack L1(designs/10 §7):verify-format! / --target / sysexits ──
    ;; fixture 是最小 pack 目录:只有 pack.manifest(files 为空 → 完整性恒过),
    ;; target 三元组按用例拼;运行 verify-pack 时捕获 stderr 以钉诊断文案。

    ;; (format 99) > pack-format-supported(=1)→ 70 EX_SOFTWARE + format-too-new
    (verify-pack-format-too-new
      (let ([d (make-verify-pack-fixture! "(pack (format 99) (files))")])
        (let-values ([(rc err) (run-verify-pack d)])
          (assert-equal 70 rc)
          (assert-true (has? err "pack format 99 is newer than supported (1)"))
          (assert-true (has? err "(chandler-pack-error (format-too-new (pack 99) (supported 1)))")))))

    ;; 缺 (format …) 视为 0(designs/10 §7a:与 bootstrap 缺省一致)→ 不拦
    (verify-pack-format-default-0
      (let ([d (make-verify-pack-fixture! "(pack (files))")])
        (let-values ([(rc err) (run-verify-pack d)])
          (assert-equal 0 rc))))

    ;; 完整性错:70 → 65 EX_DATAERR(designs/10 §7c,对齐 skiff/app.ss)
    (verify-pack-integrity-failure-is-65
      (let* ([d (make-verify-pack-fixture!
                  "(pack (format 1) (files (\"a.txt\" (sha256 \"0000\") (size 3))))")]
             [_ (put! (join-paths d "a.txt") "xyz")])
        (let-values ([(rc err) (run-verify-pack d)])
          (assert-equal 65 rc)
          (assert-true (has? err "CHANGED a.txt (sha256 mismatch)")))))

    ;; --target:machine-type 不符 → 78 EX_CONFIG + target-mismatch s-expr
    (verify-pack-target-machine-type-mismatch
      (let ([d (make-verify-pack-fixture!
                 (format "(pack (format 1) (target (machine-type bogus-mt) (chez-version \"~a\") (skiff-compat \">=0.0.0\")) (files))"
                         (chez-version-string)))])
        (let-values ([(rc err) (run-verify-pack d #t)])
          (assert-equal 78 rc)
          (assert-true (has? err "machine-type"))
          (assert-true (has? err "(chandler-pack-error (target-mismatch")))))

    ;; --target:chez-version 不符 → 78(fasl ABI 绑版本,永不放宽)
    (verify-pack-target-chez-version-mismatch
      (let ([d (make-verify-pack-fixture!
                 (format "(pack (format 1) (target (machine-type ~a) (chez-version \"0.0.0-bogus\") (skiff-compat \">=0.0.0\")) (files))"
                         (machine-type)))])
        (let-values ([(rc err) (run-verify-pack d #t)])
          (assert-equal 78 rc)
          (assert-true (has? err "chez-version"))
          (assert-true (has? err "(chandler-pack-error (target-mismatch")))))

    ;; --target:声明 (skiff-version "0.4.1") 而 runtime 是 stock Chez → 一律 78
    ;; (designs/10 §4 第 3 行);若恰好在 skiff 0.4.1 上跑则合法通过
    (verify-pack-target-skiff-required-on-stock
      (let ([d (make-verify-pack-fixture!
                 (format "(pack (format 1) (target (machine-type ~a) (chez-version \"~a\") (skiff-version \"0.4.1\")) (files))"
                         (machine-type) (chez-version-string)))])
        (let-values ([(rc err) (run-verify-pack d #t)])
          (if (and (eq? (current-runtime) 'skiff) (equal? (runtime-version) "0.4.1"))
              (assert-equal 0 rc)
              (begin
                (assert-equal 78 rc)
                (assert-true (has? err "(chandler-pack-error (target-mismatch"))
                (when (eq? (current-runtime) 'chez)
                  (assert-true (has? err "pack requires skiff, current runtime is stock Chez"))))))))

    ;; --target:(skiff-compat ">=0.0.0") 全开 → stock / skiff 两种 runtime 都过
    (verify-pack-target-skiff-compat-wildcard-passes
      (let ([d (make-verify-pack-fixture!
                 (format "(pack (format 1) (target (machine-type ~a) (chez-version \"~a\") (skiff-compat \">=0.0.0\")) (files))"
                         (machine-type) (chez-version-string)))])
        (let-values ([(rc err) (run-verify-pack d #t)])
          (assert-equal 0 rc))))

    ;; --target + SKIFF_ALLOW_VERSION_SKEW=1:只放宽 skiff 维(designs/10 §4
    ;; 逃生阀行)。skiff runtime 上版本不符 → WARNING + 通过;stock runtime 上
    ;; 「要求 skiff」不放宽 → 仍 78。
    (verify-pack-target-skew-escape-relaxes-only-skiff-version
      (let ([d (make-verify-pack-fixture!
                 (format "(pack (format 1) (target (machine-type ~a) (chez-version \"~a\") (skiff-version \"0.0.0-nonexistent\")) (files))"
                         (machine-type) (chez-version-string)))])
        (let-values ([(rc err) (with-env-var "SKIFF_ALLOW_VERSION_SKEW" "1"
                                 (lambda () (run-verify-pack d #t)))])
          (if (eq? (current-runtime) 'skiff)
              (begin
                (assert-equal 0 rc)
                (assert-true (has? err "WARNING: skiff-version skew allowed")))
              (assert-equal 78 rc)))))

    ;; 不带 --target:target 三元组再离谱也不查(opt-in;只查完整性)
    (verify-pack-no-target-skips-target-check
      (let ([d (make-verify-pack-fixture!
                 "(pack (format 1) (target (machine-type bogus-mt) (chez-version \"0.0.0-bogus\") (skiff-version \"0.0.0-nonexistent\")) (files))")])
        (let-values ([(rc err) (run-verify-pack d)])
          (assert-equal 0 rc))))


    ;; ── run.sps(designs/10 L0):统一 runner(install/pack 共用)──
    ;; run.sps 在 runtime 定位之前落盘(内容只依赖 entry/mt),故 pack-until-runtime
    ;; 这批「不捆真运行时」的用例同样能拿到产物;钉的是生成物的契约:runtime 探测、
    ;; format/target 校验、sysexits 退出码、单行 s-expr 诊断、校验先于状态变更。

    (runner-written-before-runtime-bundling
      (let* ([app (make-app '())]
             [_ (fake-build! app "myapp")])
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
        (assert-true (file-exists? (join-paths (app-vroot app "myapp" "1.0") ".chandler" "run.sps")))))

    ;; skiff 包也生成同一份 run.sps(不再分叉;启动器直接 --program)
    (runner-also-written-for-skiff-packs
      (let* ([app (make-app '())]
             [_ (fake-build! app "myapp")])
        (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . skiff)))
        (assert-true (file-exists? (join-paths (app-vroot app "myapp" "1.0") ".chandler" "run.sps")))))

    ;; runtime 探测:(top-level-bound? 'skiff-version) + 字符串/过程双绑定容忍
    (runner-detects-runtime-via-skiff-version-binding
      (let ([bs (packed-runner)])
        (assert-true (has? bs "(top-level-bound? 'skiff-version)"))
        (assert-true (has? bs "(top-level-value 'skiff-version)"))
        (assert-true (has? bs "(procedure? v)"))
        (assert-true (has? bs "'skiff 'chez"))))

    ;; (format N) 超出 pack-format-supported(=1)→ 70 EX_SOFTWARE
    (runner-checks-format-version-exit-70
      (let ([bs (packed-runner)])
        (assert-true (has? bs "pack-format-supported"))
        (assert-true (has? bs "format-too-new"))
        (assert-true (has? bs "(exit 70)"))))

    ;; 完整 target 校验:machine-type / chez-version / skiff-version / skiff-compat
    ;; 四个分支都在,不符即 78 EX_CONFIG + target-mismatch s-expr
    (runner-full-target-check-exit-78
      (let ([bs (packed-runner)])
        (assert-true (has? bs "machine-type"))
        (assert-true (has? bs "chez-version"))
        (assert-true (has? bs "skiff-version"))
        (assert-true (has? bs "skiff-compat"))
        (assert-true (has? bs "target-mismatch"))
        (assert-true (has? bs "(exit 78)"))))

    ;; 内联版区间匹配(部署态无 chandler 可 import):%version-match? 必须自含
    (runner-inlines-version-match
      (let ([bs (packed-runner)])
        (assert-true (has? bs "(define (%version-match?"))
        (assert-true (has? bs "(define (%match-one"))
        (assert-true (has? bs "(define (%version-compare"))))

    ;; manifest 不可读 / 缺 (target …) → 65 EX_DATAERR
    (runner-manifest-invalid-exit-65
      (let ([bs (packed-runner)])
        (assert-true (has? bs "pack.manifest"))
        (assert-true (has? bs "(chandler-pack-error (manifest-invalid))"))
        (assert-true (has? bs "target-missing"))
        (assert-true (has? bs "(exit 65)"))))

    ;; (skiff-compat \">=0.0.0\") 全开通配:stock runtime 也合法(designs/10 §4 第 8 行)
    (runner-skiff-compat-wildcard-passes-stock
      (let ([bs (packed-runner)])
        (assert-true (has? bs "\">=0.0.0\""))
        (assert-true (has? bs "(not (string=? %want-compat \">=0.0.0\"))"))))

    ;; 声明要 skiff(exact 或 compat 非全开)+ runtime 是 stock Chez → 一律 78
    (runner-skiff-required-on-stock-exit-78
      (let ([bs (packed-runner)])
        (assert-true (has? bs "pack requires skiff, current runtime is stock Chez"))))

    ;; SKIFF_ALLOW_VERSION_SKEW=1 只放宽 skiff 维:WARNING + 通过,
    ;; machine-type / chez-version 的 %mismatch! 路径不带 skew 分支
    (runner-skew-escape-only-relaxes-skiff-version
      (let ([bs (packed-runner)])
        (assert-true (has? bs "SKIFF_ALLOW_VERSION_SKEW"))
        (assert-true (has? bs "WARNING: skiff-version skew allowed"))
        (assert-true (has? bs "(define %skew-ok? (equal? (getenv \"SKIFF_ALLOW_VERSION_SKEW\") \"1\"))"))
        ;; skew 的首次使用必须晚于 machine-type / chez-version 的 %mismatch!
        ;; 检查(即 skew 门不住这两条)
        (assert-true (> (index-of bs "(if %skew-ok?")
                        (index-of bs "%mismatch! 'chez-version")))))

    ;; 结构化诊断:单行 s-expr 走 %err-sexp,chandler-pack-error 前缀统一
    (runner-structured-sexp-diagnostics
      (let ([bs (packed-runner)])
        (assert-true (has? bs "(define (%err-sexp s)"))
        (assert-true (has? bs "chandler-pack-error"))
        (assert-true (has? bs "(list 'expected"))))

    ;; target/format/manifest 失败绝不走 Chez error(会进 debugger / 留栈帧)
    (runner-no-chez-error-for-verify-failures
      (let ([bs (packed-runner)])
        (assert-false (has? bs "(error 'chandler-pack"))))

    ;; 生成物必须是平衡的 s-expr 序列:子串断言查不出括号错位,交给 reader 兜底
    (runner-source-is-well-formed-sexps
      (let* ([bs (packed-runner)]
             [ip (open-input-string bs)])
        (let loop ([n 0])
          (let ([d (read ip)])
            (if (eof-object? d)
                (assert-true (> n 10))        ; 真有东西,不是空串假阳性
                (loop (+ n 1)))))))

    ;; 校验先于一切状态变更:65/70/78 出口都在 %load-natives / eval-entry 之前
    ;; (scan-libdirs 设在校验前,但那只是目录列表,不加载代码)
    (runner-verifies-before-any-state-change
      (let ([bs (packed-runner)])
        (assert-true (< (index-of bs "(exit 78)") (index-of bs "(%load-natives %root)")))
        (assert-true (< (index-of bs "(exit 78)") (index-of bs "(eval (list '")))))

  ;; 造一个 petite 包到 runtime 步为止,读回生成的 run.sps
  (define (packed-runner)
    (let* ([app (make-app '())]
           [_ (fake-build! app "myapp")])
      (pack-until-runtime app '((name . "myapp") (version . "1.0") (entry . (myapp)) (runtime . petite)))
      (read-file (join-paths (app-vroot app "myapp" "1.0") ".chandler" "run.sps"))))

  (define (index-of hay needle)
    (let ([n (string-length hay)] [m (string-length needle)])
      (let loop ([i 0])
        (cond
          [(> (+ i m) n) #f]
          [(string=? needle (substring hay i (+ i m))) i]
          [else (loop (+ i 1))]))))

  (define (has? hay needle) (and (index-of hay needle) #t))

  ;; 造一个最小 pack 目录:只有 pack.manifest;声明 (files ()) → 完整性恒过,
  ;; 把变数全部留给 format / --target 两条新路径。
  (define (make-verify-pack-fixture! manifest-str)
    (let ([d (mktmp)])
      (put! (join-paths d "pack.manifest") manifest-str)
      d))

  ;; 跑 verify-pack 并捕获 stderr,返回 (values 退出码 stderr文本)
  (define (run-verify-pack path . target?)
    (let ([op (open-output-string)])
      (let ([rc (parameterize ([current-error-port op])
                  (if (and (pair? target?) (car target?))
                      (verify-pack path #t)
                      (verify-pack path)))])
        (values rc (get-output-string op)))))

  ;; 临时设环境变量跑 thunk,跑完恢复旧值(skew 逃生阀用例用)
  (define (with-env-var key val thunk)
    (let ([old (getenv key)])
      (dynamic-wind
        (lambda () (putenv key val))
        thunk
        (lambda () (putenv key (or old "")))))))
