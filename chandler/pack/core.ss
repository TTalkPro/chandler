#!chezscheme
;;; chandler/pack/core.ss --- pack 主入口(原 pack.ss §8)
;;;
;;; opts: (runtime . skiff|scheme|petite) (out . dir)
;;;       (name . s) (version . s) (entry . lib-ref) (main . sym)

(library (chandler pack core)
  (export pack)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc)
          (chandler layout)
          (chandler sexp)
          (chandler manifest)
          (chandler lock)
          (chandler install)
          (chandler runtime-detector)
          (chandler version)
          (chandler hash)
          (chandler pack paths)
          (chandler pack runtime)
          (chandler pack snapshot)
          (chandler pack natives)
          (chandler pack launchers)
          (chandler pack run-sps)
          (chandler pack manifest-writer))

  ;; 库名 (a b c) → 对象树里的相对路径 "a/b/c.so"
  (define (entry-so-rel entry)
    (string-append (string-join (map symbol->string entry) "/") ".so"))

  (define (pack project opts)
    (let* ([mpath (project-manifest-path project)]
           [mf    (and (file-exists? mpath) (read-manifest mpath))]
           [name  (or (alist-ref opts 'name) (and mf (manifest-name mf))
                      (error 'pack "cannot determine app name (no chandler-manifest.ss; pass --name)"))]
           [version (or (alist-ref opts 'version) (and mf (manifest-version mf)) "0.0.0")]
           [mapp  (and mf (manifest-app mf))]
           [entry (or (alist-ref opts 'entry) (and mapp (app-entry mapp)))]
           [mainp (or (alist-ref opts 'main) (and mapp (app-main mapp)) 'main)]
           [rt    (or (alist-ref opts 'runtime) (default-runtime mf))]
           [out   (or (alist-ref opts 'out) "dist")]
           [lib?  (alist-ref opts 'lib)]
           [mt    (current-machine-type)])
      ;; pack 服务于**应用**:必须有显式入口。库(manifest 没声明 (app …))不该被打成
      ;; 可执行分发包 —— 它的天然分发形态是 git,消费方 `chandler add` 即可。允许用
      ;; `--entry` 显式覆盖,以便临时打包或 lib→app 演化期;但缺省情况(manifest 没声明
      ;; 且命令行也没传)就直接拒绝,而不是**猜**一个顶层 umbrella。
      ;;
      ;; 这取代了早先的 infer-entry:它把"包名"和"入口库名"混为一谈(skiff-demo 的包名
      ;; 是 skiff-demo、入口库却是 (mdserver)),让 lib 也能被悄无声息地打成 app 包 ——
      ;; 产出一堆无意义的 bin/boot/runtime。
      (unless (or entry lib?)
        (error 'pack
               (string-append
                 "no entry library declared; this looks like a library, not an application.\n"
                 "  `chandler pack` ships runnable applications. For a library, push to git\n"
                 "  and let consumers `chandler add <name> <url>` instead.\n"
                 "  If this is actually an app, declare it in chandler-manifest.ss:\n"
                 "    (app (entry (<lib>)) (main main))\n"
                 "  or pass --entry '(<lib>)' on the command line.")))
      (unless (memq rt '(skiff scheme petite))
        (error 'pack (format "runtime ~s not supported (skiff | scheme | petite)" rt)))
      (let* ([locked (project-locked-deps project)]
             [root (if (and (> (string-length out) 0) (char=? (string-ref out 0) #\/))
                       (join-paths out (pack-dir-name name version))
                       (join-paths project out (pack-dir-name name version)))]
             ;; temp sibling + rename(2026-07-26):全程在 <out>.tmp.<pid>/ 兄弟目录
             ;; 里组装(与 <out> 同文件系统,rename 才原子),完工才换到 <out>/。
             ;; 中途崩溃/失败只留 temp,最终位置绝不留半截包;pid 后缀防并发撞名。
             [tmp-root (string-append root ".tmp." (number->string (get-process-id)))]
             [libdir (pack-libdir tmp-root)])
        (preflight project mt locked)
        (guard (e [#t (rm-rf tmp-root) (raise e)])
        (printf "pack ~a~%" root)
        ;; ── 阶段 1:载荷(与 install 同一管线,I2 by construction)──
        ;; app 自身 + 各 dep 装到 share/chez/<name>/<version>/{src,<mt>}/,
        ;; + manifest/lock 快照;register?=#f → 无 .registry/(可再分发包不带
        ;; 安装机私有状态),无 staging(目录全新),不写 install shim。
        (install-project-payload! project libdir name version entry
                                  (list (cons 'register? #f)))
        ;; chandler 的 runtime 子集:它不是 lock 里的依赖(是运行时门,designs/12 §5),
        ;; 独立在 share/chez/chandler/<version>/。从 `_vendor/chandler/_build/<mt>/` 取
        ;; (deps 期 build-chandler-runtime! 已就地编译;与 build 同源 → 实例一致)。
        (when (and mf (manifest-chandler mf))
          (copy-chandler-into-pack! project libdir (manifest-chandler mf)))
        ;; 清单快照(无源清单时合成最小清单)
        (write-app-manifest! project libdir name version entry mainp)
        ;; 入口库必须真的在包里 —— 否则打出的包一路正常,到启动 import 才报
        ;; "library (x) not found"。这一步把那个失败提前到打包期。
        ;; lib pack 跳过 entry 检查(无 entry);失败由外层 guard 清掉 temp。
        (unless lib?
          (let ([e (join-paths (version-root libdir name version) mt (entry-so-rel entry))])
            (unless (file-exists? e)
              (error 'pack
                     (format "entry library ~a has no compiled object at ~a~%  (pass --entry '(<lib>)', or run `chandler build` if it is simply not built)"
                             entry e)))))
        ;; ── 阶段 2:envelope(仅 app pack;lib pack 到阶段 1 为止)──
        (unless lib?
          ;; pack 模式 run.sps:目标三元组校验 + native 加载在 install 模式之上
          (let ([runner-dir (join-paths (version-root libdir name version) ".chandler")])
            (ensure-dir runner-dir)
            (write-text (join-paths runner-dir "run.sps")
              (run-sps-content entry mainp 'pack)))
          ;; 运行时 exe → bin/,boot → lib/chez/,启动器 → bin/<app>
          (if (eq? rt 'skiff)
            (let* ([exe (skiff-exe-path)]
                   [bd  (skiff-boot-dir exe)]
                   [sv  (probe-skiff-version exe)])
              (copy-exe! exe (join-paths (pack-bin-dir tmp-root) (exe-name "skiff")))
              (for-each (lambda (b) (copy-file (join-paths bd b) (join-paths (pack-boot-dir tmp-root) b)))
                        '("petite.boot" "scheme.boot" "skiff.boot"))
              (write-launcher! tmp-root name (launcher-sh-skiff name version) (launcher-cmd-skiff name version))
              (write-pack-manifest! tmp-root name version rt entry mainp
                                    (probe-chez-version exe) mt sv))
            (let* ([exe (chez-exe-path)]
                   [ver (probe-chez-version exe)]
                   [csv (chez-csv-dir exe ver)])
              (copy-exe! exe (join-paths (pack-bin-dir tmp-root) (exe-name "scheme")))
              (copy-file (join-paths csv "petite.boot") (join-paths (pack-boot-dir tmp-root) "petite.boot"))
              (when (eq? rt 'scheme)
                (copy-file (join-paths csv "scheme.boot") (join-paths (pack-boot-dir tmp-root) "scheme.boot")))
              (write-launcher! tmp-root name (launcher-sh-stock rt name version) (launcher-cmd-stock rt name version))
              (write-pack-manifest! tmp-root name version rt entry mainp ver mt #f)))
            ) ;; close unless lib?
          ;; ── 阶段 3:原子替换 —— temp 完工,换到最终位置 ──
          (commit-pack-output! tmp-root root))
        (printf "packed ~a ~a -> ~a~%" name version root)
        0)))

  ;; 原子替换:tmp-root → root。root 已存在则先 rename 到 <root>.old.<pid> 再删
  ;; (同文件系统内 rename 原子:消费者要么看到旧包要么看到新包,没有半截)。
  ;; Windows 兼容:rename 目标已存在会失败,故 old 先清(带 guard)。
  ;; 回滚:tmp→root 失败则把 old 挪回 root(旧包保住);temp 留给外层 guard 清。
  (define (commit-pack-output! tmp-root root)
    (let ([old (string-append root ".old." (number->string (get-process-id)))])
      (guard (e [#t (void)]) (rm-rf old))
      (if (or (file-exists? root) (file-directory? root))
          (begin
            (rename-file root old)
            (guard (e [#t
                       (guard (e2 [#t (void)]) (rename-file old root))
                       (raise e)])
              (rename-file tmp-root root))
            (rm-rf old))
          (rename-file tmp-root root))))

  ;; _vendor/chandler/_build/<mt>/chandler/<sub>.so → <libdir>/chandler/<version>/<mt>/chandler/<sub>.so。
  ;; **来源 = _vendor/chandler/_build/<mt>/**(BUG-1,2026-07-24):与 build-chandler-runtime!
  ;; 编译产物同源(就地编译 vendored chandler 源码),不再读全局前缀 —— 故 app 链到的
  ;; 实例与包内交付的实例是同一个物理对象文件。版本门用进程内常量,不再读快照。
  (define (copy-chandler-into-pack! project libdir range)
    (unless (version-match? range chandler-version)
      (error 'pack
             (format "manifest requires chandler ~s, but the running chandler is ~a"
                     range chandler-version)))
    (let* ([chandler-vr (version-root libdir 'chandler chandler-version)]
           [obj-dest (join-paths chandler-vr (current-machine-type) "chandler")]
           [src-dest (join-paths chandler-vr "src" "chandler")]
           [from (join-paths project "_vendor" "chandler" "_build"
                             (current-machine-type) "chandler")])
      (unless (file-directory? from)
        (error 'pack
               (format "chandler runtime not vendored at ~a~%  (run `chandler deps` — the (chandler …) gate copies it there)"
                       from)))
      (ensure-dir obj-dest)
      (ensure-dir src-dest)
      (let ([n 0])
        (for-each
          (lambda (e)
            (let ([p (join-paths from e)])
              (when (and (not (file-directory? p)) (string-suffix? ".so" e))
                (let ([dst (join-paths obj-dest e)])
                  (ensure-parent dst) (copy-file p dst) (set! n (+ n 1))))))
          (dir-entries from))
        (when (= n 0)
          (error 'pack (format "no chandler runtime objects found in ~a" from))))))

  ;; 拷贝可执行文件并保住执行位(平台差异见 fs 的 make-executable!)。
  (define (copy-exe! src dst)
    (ensure-parent dst)
    (copy-file src dst)
    (make-executable! dst))

  ;; manifest 声明了 (skiff …) 门 → 捆 skiff;否则 stock petite(部署态只 fasl 载入
  ;; 预编译 .so,不需要编译器,包更小)。--runtime 覆盖。
  (define (default-runtime mf)
    (if (and mf (manifest-skiff mf)) 'skiff 'petite))

  ;; ── 前置校验:pack 只组装。缺什么就说清楚该跑哪个命令补 ──
  ;; C0:每个依赖各有自己的对象树(_vendor/<dep>/<srcdir>/_build/<mt>/),故逐依赖查,
  ;; 报错也能指名道姓「是哪个依赖没编」——比先前一句笼统的「lib/<mt> 不在」可操作。
  (define (preflight project mt locked)
    (let ([bdir (join-paths project "_build" mt)])
      (unless (file-directory? bdir)
        (error 'pack
               (format "~a not found; the application itself is not compiled -- run `chandler build` first" bdir)))
      (for-each
        (lambda (d)
          (let* ([n   (symbol->string (locked-dep-name d))]
                 [obj (dep-obj-dir project d)])
            (unless (file-directory? obj)
              (error 'pack
                     (format "~a not compiled (~a not found) -- run `chandler build` first" n obj)))
            (unless (or (file-exists? (join-paths obj (string-append n ".so")))
                        (file-directory? (join-paths obj n)))
              (error 'pack
                     (format "dependency ~a has no compiled objects in ~a -- run `chandler build`" n obj)))
            ;; native 无法在消费方现编,故缺了必须当场停 —— 否则打出的包会一路正常,
            ;; 直到第一次 foreign call 才炸。
            (let ([miss (missing-dep-natives obj (list d))])
              (unless (null? miss)
                (error 'pack
                       (format "declared native libraries are missing -- run `chandler build --allow-build`:~%  ~a"
                               (string-join miss "\n  ")))))))
        locked)))
  )
