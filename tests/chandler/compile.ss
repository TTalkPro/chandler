#!chezscheme
;;; tests/chandler/compile.ss --- (chandler compile) 测试
;;;
;;; 覆盖:落点与库目录对、library-task 端到端(真编译真产 .so)、指纹失效
;;; (改内容重编 / 只 touch 不重编 / 换旗标重编)、清单读写与 GC、拓扑序、
;;; 并行 worker(真起子进程)、clean、以及库化引入的两处新语义
;;; (显式装配 install-compile-hooks! / 同进程二次构建的状态复位)。
;;;
;;; 都在临时目录里编**真**库 —— 编译层的价值就在于产出能被 Chez 加载的对象,
;;; mock 掉就什么也没验。

(library (tests chandler compile)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler base)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph)
          (chandler compile))

  ;; 仓库根 —— 库实例化时捕获(测试从仓库根启动;with-proj 之后 cwd 会变)。
  ;; 有一条用例必须在**独立子进程**里构建,那时要用它当 --libdirs。
  (define repo-root (current-directory))

  ;; 两个库一条边:(app core) → (app util)
  (define basic-files
    '(("app/util.sls" . "(library (app util) (export u) (import (rnrs)) (define u 41))")
      ("app/core.sls" . "(library (app core) (export c) (import (rnrs) (app util)) (define c (+ u 1)))")
      ("recipe.ss" . "(define-lib-roots \".\")\n(library-task 'build '(app core))\n(default-task 'build)\n")))

  ;; with-proj / silently / when-compiler 来自 (tests chandler fixtures)。

  ;; 一次完整构建(与 CLI build 通路同序):装配 → 加载 recipe → 读清单 →
  ;; 跑目标 → 写清单。返回本次真正执行过的编译目标列表。
  (define (build! . target)
    (let ((executed '()))
      (silently
        (lambda ()
          (load-recipe "recipe.ss")
          (load-fp-manifest!)
          (invoke-task (if (null? target) 'build (car target)))
          ;; 记下哪些编译任务真跑了
          (set! executed
                (list-sort string<?
                  (filter-map
                    (lambda (k)
                      (let ((t (hashtable-ref task-registry k #f)))
                        (and t (task-executed? t) (string? k) k)))
                    (vector->list (hashtable-keys task-registry)))))
          (write-fp-manifest!)))
      executed))


  (define-suite suite

    (build-dir-and-so-paths
      (assert-string= (string-append "_build/" (current-machine-type)) (build-dir))
      (assert-string= (string-append (build-dir) "/app/util.so") (ref->so '(app util)))
      (assert-string= (string-append (build-dir) "/a/b/c.so") (ref->so '(a b c))))

    (root-dir-pairs
      ;; 普通根与我们自己的构建树配对;预构建根变 (obj . obj) —— 源码那半边
      ;; 有意不给 Chez(否则它可能从源码加载依赖,烤进 .so 的编译实例就不是
      ;; 我们要交付的那个)。
      (assert-equal '("src" . "B") (root->dir-pair "src" "B"))
      (assert-equal '("dep/ta6le" . "dep/ta6le")
                    (root->dir-pair '("dep/src" . "dep/ta6le") "B")))

    (prebuilt-form
      (assert-equal (cons "lib/src" (string-append "lib/" (current-machine-type)))
                    (prebuilt "lib"))
      (assert-equal '("s" . "o") (prebuilt "s" "o")))

    (flags-string-tracks-wpo
      (assert-true (string-contains? (flags-string) "generate-wpo-files=#f"))
      (parameterize ((*generate-wpo* #t))
        (assert-true (string-contains? (flags-string) "generate-wpo-files=#t"))))

    (library-task-compiles-closure
      ;; 端到端:真产出 .so,且依赖也被编(闭包,不只入口)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (assert-true (file-exists? (ref->so '(app core))))
            (assert-true (file-exists? (ref->so '(app util))))
            (assert-equal 2 (hashtable-size compile-nodes)))))))

    (compiled-objects-are-loadable
      ;; 交付形态自洽:**只给对象根**(源码不在搜索路径里)也能 import 起来。
      ;; 这才是编译层的产出标准 —— 能被 Chez 加载,而不是「字节等于某个参照实现」
      ;; (Chez 的 fasl 本就不可复现:同一份源码连编两次字节都不同)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (write-file "check.ss" "(import (app core))(display c)(newline)")
            (let ((r (run-capture "scheme"
                                  (list "-q" "--libdirs" (join-paths d (build-dir))
                                        "--script" (join-paths d "check.ss")))))
              (assert-equal 0 (proc-result-code r))
              (assert-string= "42" (string-trim (proc-result-out r)))))))))

    (fingerprint-skips-unchanged
      ;; 第二次构建什么都不该编(内容没变)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (assert-equal '() (build!)))))))

    (fingerprint-ignores-touch
      ;; 只 bump mtime、内容不变 → **不**重编(这正是 mtime 判据做不到的)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (let ((src (read-file-string "app/util.sls")))
              (write-text "app/util.sls" src))          ; 重写同样内容 = touch
            (assert-equal '() (build!)))))))

    (fingerprint-catches-content-change
      ;; 改内容 → 该库重编,**下游也重编**(上游指纹进下游指纹)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (write-text "app/util.sls"
                        "(library (app util) (export u) (import (rnrs)) (define u 99))")
            (let ((done (build!)))
              (assert-true (member (ref->so '(app util)) done))
              (assert-true (member (ref->so '(app core)) done))))))))

    (second-build-in-same-process-resets-state
      ;; **库化引入的新语义**:bake 是「一次调用一个进程」,靠退出复位全局状态;
      ;; chandler 是单二进制,同进程连着建两次时若不清 fp-cache,内容真改了也会
      ;; 被判成「无需重编」。load-recipe 现在跑 recipe-reset-hooks,故下面成立。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (assert-true (> (hashtable-size compile-nodes) 0))
            (write-text "app/core.sls"
                        "(library (app core) (export c) (import (rnrs) (app util)) (define c (* u 2)))")
            (assert-true (member (ref->so '(app core)) (build!))))))))

    ;; 内容指纹(我们)与 mtime 判据(Chez 在 compile-library 内部解析上游)的收口。
    ;; 场景:上游只被 touch(内容不变)、下游内容真改 → 下游要重编,而 Chez 会按
    ;; mtime 认为上游过期、在**内存里**重编它;若不同步对象的 mtime,产出的下游
    ;; .so 记的编译实例就与磁盘上那个上游 .so 对不上。
    ;;
    ;; 两处细节决定这条用例有没有牙(都踩过):
    ;;   ① 两次构建必须在**独立进程**里 —— 同进程里 (app util) 从第一次构建起就
    ;;      驻留着,Chez 不会再去读源码,分歧根本不发生,断言恒真。
    ;;   ② 收尾必须用**只给对象根**的子进程加载 —— 挂成 src::obj 对时 Chez 会从
    ;;      源码重编出一套自洽的实例,同样验不出来。而只挂对象侧正是 pack 启动器
    ;;      的加载方式,也是这个 bug 唯一现形的地方。
    (touched-upstream-does-not-poison-downstream
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (write-file "build-once.ss"
              (string-append
                "(import (chezscheme) (chandler recipe) (chandler compile) (chandler task-engine))\n"
                "(install-compile-hooks!)\n"
                "(load-recipe \"recipe.ss\") (load-fp-manifest!)\n"
                "(invoke-task 'build) (write-fp-manifest!)\n"))
            (let ((build-in-subprocess
                    (lambda ()
                      (let ((r (run-capture "scheme"
                                            (list "-q" "--libdirs" repo-root
                                                  "--script" (join-paths d "build-once.ss"))
                                            (list (cons 'cwd d)))))
                        (assert-equal 0 (proc-result-code r))))))
              (build-in-subprocess)
              (write-text "app/util.sls" (read-file-string "app/util.sls"))  ; 同内容,新 mtime
              (write-text "app/core.sls"
                          "(library (app core) (export c) (import (rnrs) (app util)) (define c (+ u 2)))")
              (build-in-subprocess))
            (write-file "check.ss" "(import (app core))(display c)(newline)")
            (let ((r (run-capture "scheme"
                                  (list "-q" "--libdirs" (join-paths d (build-dir))
                                        "--script" (join-paths d "check.ss")))))
              (assert-equal 0 (proc-result-code r))
              (assert-string= "43" (string-trim (proc-result-out r))))))))) 

    (flag-change-invalidates
      ;; 换编译旗标 → 指纹变 → 重编(mtime 判据同样抓不到)。
      ;; 注意**不能** parameterize 着 load-recipe:它跑 recipe-reset-hooks,
      ;; 而复位的第一件事就是把 *generate-wpo* 归 #f(program-task 逐 recipe 打开)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (silently (lambda () (load-recipe "recipe.ss")))
            (let ((target (ref->so '(app util))))
              (let ((fp0 (fingerprint-of target)))
                (*generate-wpo* #t)
                (reset-fingerprint-cache!)
                (let ((fp1 (fingerprint-of target)))
                  (*generate-wpo* #f)
                  (reset-fingerprint-cache!)
                  (assert-false (string=? fp0 fp1))
                  (assert-string= fp0 (fingerprint-of target))))))))))

    (manifest-round-trip-and-gc
      ;; 清单写的是 "<target> <fp>" 行;只写**本次**取过指纹的目标(GC 陈条目)。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (assert-true (file-exists? (fp-manifest-path)))
            (let ((lines (read-lines (fp-manifest-path))))
              (assert-equal 2 (length lines))
              (assert-true (string-prefix? (ref->so '(app core)) (car lines))))
            ;; 塞一条陈目标,重建后应被 GC 掉
            (hashtable-set! fp-manifest "_build/stale/x.so" "deadbeef")
            (build!)
            (assert-false (string-contains? (read-file-string (fp-manifest-path)) "stale")))))))

    (entry-path-resolution
      (with-proj basic-files
        (lambda (d)
          (parameterize ((lib-roots (list ".")))
            (assert-string= "app/core.sls" (entry->path "app/core.sls"))
            (assert-string= "./app/core.sls" (entry->path '(app core)))
            (assert-raises (lambda () (entry->path '(app nope))))
            (assert-raises (lambda () (entry->path 42)))
            (*exit-code* exit-ok)))))

    (topo-sort-dependencies-first
      (with-proj basic-files
        (lambda (d)
          (parameterize ((lib-roots (list ".")))
            (let* ((nodes (build-graph (list "./app/core.sls")))
                   (order (topo-sort-sos nodes)))
              (assert-equal 2 (length order))
              (assert-string= (ref->so '(app util)) (car order))
              (assert-string= (ref->so '(app core)) (cadr order)))))))

    (define-lib-roots-keeps-gen-roots
      ;; define-lib-roots **覆盖** lib-roots,故必须把 codegen 根接回去 ——
      ;; 否则一份写 (define-lib-roots ".") 的 recipe 会让 build-graph 解析不到
      ;; 生成的 (<lib> native-loader)。
      (parameterize ((*gen-roots* '("_build/.gen")) (lib-roots '()))
        (eval '(define-lib-roots "src")
              (environment '(chezscheme) '(chandler compile) '(chandler import-graph)))
        (assert-equal '("src" "_build/.gen") (lib-roots))))

    (consumer-roots-exclude-gen
      ;; dev 态挂库路径时排除 codegen 根:消费者只从对象侧解析 loader,
      ;; 给出源码根会让陈旧的生成源码遮蔽编译对象。
      (parameterize ((*gen-roots* '("_build/.gen"))
                     (lib-roots '("." "_build/.gen")))
        (assert-equal '(".") (consumer-lib-roots))
        (let ((s (libdirs-string)))
          (assert-false (string-contains? s ".gen"))
          ;; 分隔符随平台(bake 那份写死 "::",Windows 上是错的)
          (assert-true (string-contains? s (string-append (path-sep) (path-sep)))))))

    (parallel-build-produces-objects
      ;; -j:真起子进程编译。worker 是自含脚本(只 import (chezscheme)),
      ;; 故不依赖 chandler 装在哪。波前分级:util 在 level 0、core 在 level 1。
      (with-proj basic-files
        (lambda (d)
          (silently
            (lambda ()
              (load-recipe "recipe.ss")
              (load-fp-manifest!)
              (parallel-build! 2)))
          (assert-true (file-exists? (worker-script-path)))
          (assert-true (file-exists? (ref->so '(app util))))
          (assert-true (file-exists? (ref->so '(app core))))
          ;; 指纹已记下 → 之后的执行器不会再编一遍
          (assert-equal '() (build!)))))

    (worker-cmd-shape
      (with-proj basic-files
        (lambda (d)
          (parameterize ((lib-roots (list "." '("dep/src" . "dep/ta6le"))))
            (let* ((node (parse-source "./app/util.sls"))
                   (cmd  (worker-cmd (ref->so '(app util)) node)))
              (assert-true (string-contains? cmd (worker-script-path)))
              (assert-true (string-contains? cmd " lib "))          ; kind
              (assert-true (string-contains? cmd "./app/util.sls"))
              ;; 预构建根按「只给对象」的对传过去
              (assert-true (string-contains?
                             cmd (string-append "dep/ta6le" (path-sep) (path-sep) "dep/ta6le")))
              (assert-false (string-contains? cmd "dep/src")))))))

    (clean-removes-declared-outputs
      ;; 只删声明过的产物 + 整棵 _build/;源码一个不碰。
      (when-compiler (lambda ()
        (with-proj basic-files
          (lambda (d)
            (build!)
            (assert-true (file-exists? "_build"))
            (silently (lambda () (load-recipe "recipe.ss") (cmd-clean)))
            (assert-false (file-exists? "_build"))
            (assert-true (file-exists? "app/util.sls"))
            (assert-true (file-exists? "recipe.ss"))
            (assert-equal exit-ok (*exit-code*)))))))

    (hooks-installed
      ;; install-compile-hooks! 必须**显式**调用:Chez 惰性实例化库,而
      ;; recipe 里的 (library-task …) 要求加载 recipe 之前环境里就有它。
      (install-compile-hooks!)
      (assert-true (member '(chandler compile) (recipe-environment-libs)))
      (assert-true (procedure? (current-fingerprint-judge)))
      ;; 指纹判据:只有登记过的编译目标/自定义提供者走指纹通路
      (reset-compile-state!)
      (assert-false ((current-fingerprint-judge) "whatever.so"))
      (hashtable-set! fingerprint-providers "whatever.so" (lambda () "fp"))
      (assert-true ((current-fingerprint-judge) "whatever.so"))
      (reset-compile-state!))

    ))
