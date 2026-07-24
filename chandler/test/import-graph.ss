#!chezscheme
;;; chandler/test/import-graph.ss --- (chandler import-graph) 测试
;;;
;;; 覆盖 bake tests/deps-run.sh 的 I1–I4/I9/I10(基础图 / 包装器 / phase /
;;; include / 环 / 解析不到),外加预构建根归类与 (chandler …) 不算 builtin。
;;; 夹具是临时目录里的真源文件,根用绝对路径(不动 cwd)。

(library (chandler test import-graph)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler test fixtures)
          (chandler base)
          (chandler import-graph))

  ;; 在临时目录里铺一组 "相对路径" → 内容 的源文件,交 proc 处置绝对根路径。
  (define (with-src-tree files proc)
    (let ((d (mktmp)))
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (for-each (lambda (f)
                      (let ((p (join-paths d (car f))))
                        (ensure-parent p)
                        (write-file p (cdr f))))
                    files)
          (proc d))
        (lambda () (rm-rf d)))))

  ;; 常用夹具:(app core) 依赖 (app util) + (rnrs)
  (define basic-tree
    '(("src/app/util.sls" . "(library (app util) (export u) (import (rnrs)) (define u 1))")
      ("src/app/core.sls" . "(library (app core) (export c) (import (rnrs) (app util)) (define c u))")))

  (define (edge-refs node) (map dep-edge-ref (lib-node-edges node)))

  (define-suite suite

    (parse-library-shape
      ;; name / exports / edges 三样从 (library …) 头部抽出来。
      (with-src-tree basic-tree
        (lambda (d)
          (let ((n (parse-source (join-paths d "src/app/core.sls"))))
            (assert-equal '(app core) (lib-node-name n))
            (assert-equal '(c) (lib-node-exports n))
            (assert-equal '((rnrs) (app util)) (edge-refs n))
            (assert-equal '() (lib-node-includes n))))))

    (parse-program-shape
      ;; 没有 (library …) 头 → 程序:name 为 #f,import 仍收边。
      (with-src-tree
        '(("p.ss" . "(import (rnrs) (app util))\n(display 1)\n"))
        (lambda (d)
          (let ((n (parse-source (join-paths d "p.ss"))))
            (assert-false (lib-node-name n))
            (assert-equal '() (lib-node-exports n))
            (assert-equal '((rnrs) (app util)) (edge-refs n))))))

    (i2-wrappers-do-not-change-deps
      ;; only/except/rename/prefix 只剥壳,依赖仍是同一个库。
      (with-src-tree
        '(("src/app/core.sls" .
           "(library (app core) (export c)
              (import (only (app util) u) (except (app io) w)
                      (prefix (app fmt) f:) (rename (app x) (a b)))
              (define c 1))"))
        (lambda (d)
          (let ((n (parse-source (join-paths d "src/app/core.sls"))))
            (assert-equal '((app util) (app io) (app fmt) (app x)) (edge-refs n))))))

    (i3-phase-for-expand
      ;; (for (app macros) expand) → phase 'expand;多 level 各出一条边。
      (with-src-tree
        '(("src/app/b.sls" .
           "(library (app b) (export b)
              (import (rnrs) (for (app macros) expand) (for (app m2) (meta 2)))
              (define b 1))"))
        (lambda (d)
          (let* ((n (parse-source (join-paths d "src/app/b.sls")))
                 (es (lib-node-edges n)))
            (assert-equal '((rnrs) (app macros) (app m2)) (edge-refs n))
            (assert-equal 'run    (dep-edge-phase (car es)))
            (assert-equal 'expand (dep-edge-phase (cadr es)))
            (assert-equal '(meta . 2) (dep-edge-phase (caddr es)))))))

    (i4-include-scanned
      ;; include 的字面路径按源文件所在目录解析,进 lib-node-includes。
      (with-src-tree
        '(("src/app/helpers.ss" . "(define h 1)")
          ("src/app/x.sls" .
           "(library (app x) (export h) (import (rnrs)) (include \"helpers.ss\"))"))
        (lambda (d)
          (let ((n (parse-source (join-paths d "src/app/x.sls"))))
            (assert-equal (list (join-paths d "src/app/helpers.ss"))
                          (lib-node-includes n))))))

    (normalize-drops-version
      ;; (srfi :1 lists) 之类的版本子形式被丢掉,只留符号。
      (assert-equal '(app util) (normalize-libref '(app util)))
      (assert-equal '(app util) (normalize-libref '(app util (1 2))))
      (assert-equal '() (normalize-libref 'not-a-pair)))

    (dedupe-keeps-first
      ;; 同一个库被 import 多次只留一条边(留最先出现的那条,phase 随之)。
      (let ((es (dedupe-edges (list (make-dep-edge '(a) 'run)
                                    (make-dep-edge '(b) 'expand)
                                    (make-dep-edge '(a) 'expand)))))
        (assert-equal '((a) (b)) (map dep-edge-ref es))
        (assert-equal 'run (dep-edge-phase (car es)))))

    (ref-to-string-and-path
      (assert-string= "(app util)" (ref->string '(app util)))
      (assert-string= "app/util" (ref->rel '(app util)))
      (assert-string= "(chandler)" (ref->string '(chandler))))

    (candidates-cover-all-exts
      ;; 四种扩展名 × 每个根,顺序即优先级。
      (parameterize ((lib-roots (list "r1" '("r2" . "r2obj"))))
        (let ((cs (candidates '(a b))))
          (assert-equal 8 (length cs))
          (assert-string= "r1/a/b.chezscheme.sls" (car cs))
          (assert-string= "r2/a/b.chezscheme.sls" (list-ref cs 4)))))

    (classify-builtin-and-source
      ;; (rnrs)/(chezscheme) 是内建;搜索根下的源码归自己编。
      (with-src-tree basic-tree
        (lambda (d)
          (parameterize ((lib-roots (list (join-paths d "src"))))
            (assert-equal 'builtin (classify-libref '(rnrs)))
            (assert-equal 'builtin (classify-libref '(chezscheme)))
            (assert-true (external-libref? '(rnrs)))
            (assert-string= (join-paths d "src/app/util.sls")
                            (classify-libref '(app util)))
            (assert-false (external-libref? '(app util)))
            (assert-false (classify-libref '(app nope)))))))

    (classify-prebuilt-root
      ;; ("src" . "obj") 对:obj 侧有 .so → 'prebuilt(原样消费,不重编);
      ;; 只有 src 侧没 .so → 回落成源码路径(自己编)。
      (with-src-tree
        '(("dep/src/x/a.sls" . "(library (x a) (export a) (import (rnrs)) (define a 1))")
          ("dep/ta6le/x/a.so" . "not-really-fasl")
          ("dep/src/x/b.sls" . "(library (x b) (export b) (import (rnrs)) (define b 1))"))
        (lambda (d)
          (parameterize ((lib-roots (list (cons (join-paths d "dep/src")
                                                (join-paths d "dep/ta6le")))))
            (assert-equal 'prebuilt (classify-libref '(x a)))
            (assert-true (external-libref? '(x a)))
            ;; 预构建根不算「自己的源码」
            (assert-false (own-source-path '(x a)))
            (assert-string= (join-paths d "dep/src/x/b.sls") (classify-libref '(x b)))))))

    (own-source-beats-prebuilt
      ;; 项目库恒胜过同名预构建库(classify 顺序:builtin → own → prebuilt)。
      (with-src-tree
        '(("mine/x/a.sls" . "(library (x a) (export a) (import (rnrs)) (define a 2))")
          ("dep/src/x/a.sls" . "(library (x a) (export a) (import (rnrs)) (define a 1))")
          ("dep/ta6le/x/a.so" . "not-really-fasl"))
        (lambda (d)
          (parameterize ((lib-roots (list (join-paths d "mine")
                                          (cons (join-paths d "dep/src")
                                                (join-paths d "dep/ta6le")))))
            (assert-string= (join-paths d "mine/x/a.sls") (classify-libref '(x a)))))))

    (chandler-libs-are-not-builtin
      ;; **与 bake 的行为差异**:构建器自己的 (chandler …) 就加载在本进程里,
      ;; 会混进 (library-list);但它们是工具,不是目标运行时提供的东西。
      ;; 判成 builtin 会让忘跑 `chandler deps` 的项目静默不编、不交付,直到部署才炸。
      (assert-true (member '(chandler import-graph) (library-list)))  ; 确实加载着
      (assert-false (runtime-provided-lib? '(chandler base)))
      (assert-false (builtin-lib? '(chandler base)))
      (parameterize ((lib-roots (list "/nonexistent-root")))
        (assert-false (classify-libref '(chandler base)))))

    (i1-build-graph-reachable
      ;; 可达集 = 入口 + 传递依赖;内建边不下降。
      (with-src-tree basic-tree
        (lambda (d)
          (parameterize ((lib-roots (list (join-paths d "src"))))
            (let* ((nodes (build-graph (list (join-paths d "src/app/core.sls"))))
                   (names (map lib-node-name nodes)))
              (assert-equal 2 (length nodes))
              (assert-true (member '(app core) names))
              (assert-true (member '(app util) names)))))))

    (build-graph-skips-prebuilt
      ;; 预构建边不下降(它生成的 loader 没有源码可解析),故只有入口一个节点。
      (with-src-tree
        '(("mine/app/main.sls" .
           "(library (app main) (export m) (import (rnrs) (x a)) (define m 1))")
          ("dep/src/x/a.sls" . "(library (x a) (export a) (import (rnrs) (x deep)) (define a 1))")
          ("dep/ta6le/x/a.so" . "not-really-fasl"))
        (lambda (d)
          (parameterize ((lib-roots (list (join-paths d "mine")
                                          (cons (join-paths d "dep/src")
                                                (join-paths d "dep/ta6le")))))
            ;; (x deep) 根本不存在 —— 若下降进预构建库就会报 cannot locate。
            (let ((nodes (build-graph (list (join-paths d "mine/app/main.sls")))))
              (assert-equal 1 (length nodes)))))))

    (i9-cycle-detected
      ;; 环报错带完整链路,用 " → " 连接。
      (with-src-tree
        '(("src/app/a.sls" . "(library (app a) (export a) (import (rnrs) (app b)) (define a 1))")
          ("src/app/b.sls" . "(library (app b) (export b) (import (rnrs) (app a)) (define b 1))"))
        (lambda (d)
          (parameterize ((lib-roots (list (join-paths d "src"))))
            (let ((msg (guard (e (#t (condition-message e)))
                         (build-graph (list (join-paths d "src/app/a.sls")))
                         "no error")))
              (assert-true (string-contains?
                             msg "cyclic library dependency: (app a) → (app b) → (app a)")))))))

    (i10-unresolvable-lists-candidates
      ;; 解析不到:报库名 + 搜过哪些候选路径(可操作)。
      (with-src-tree
        '(("src/app/bad.sls" . "(library (app bad) (export b) (import (rnrs) (app nope)) (define b 1))"))
        (lambda (d)
          (parameterize ((lib-roots (list (join-paths d "src"))))
            (let ((msg (guard (e (#t (condition-message e)))
                         (build-graph (list (join-paths d "src/app/bad.sls")))
                         "no error")))
              (assert-true (string-contains? msg "cannot locate library (app nope)"))
              (assert-true (string-contains? msg "nope.sls")))))))

    (parse-error-is-actionable
      ;; 读不动的源文件报的是「哪个文件 + 为什么」,不是裸 read error。
      (with-src-tree
        '(("broken.sls" . "(library (a b) (export x"))
        (lambda (d)
          (let ((msg (guard (e (#t (condition-message e)))
                       (parse-source (join-paths d "broken.sls"))
                       "no error")))
            (assert-true (string-contains? msg "failed to parse"))
            (assert-true (string-contains? msg "broken.sls"))))))

    ))
