#!chezscheme
;;; chandler/native-build.ss --- native(C/FFI)构建后端 + 自加载 loader 代码生成
;;;
;;; 来源:bake/native.ss(designs/20 三个后端 + designs/24 生成 loader)。
;;; 我们**不编 C** —— 只驱动后端(script | make | cmake)、在 FFI 模型需要时注入
;;; Chez 变量(Model B / chez-api),并核验产物落在不变量位置:
;;;   _build/<mt>/<lib>/native/<soname>.<ext>
;;; 那是统一加载(chandler activate / pack)与 install 唯一认得的落点。
;;;
;;; 搬运期的三处改动(理由见 TASK.md P6 §B5 实现期决定):
;;;   ① 自带的 so-ext 删掉,用 (chandler layout) 的;② `%abs` 不再 shell 出去跑
;;;   `pwd`,直接 (current-directory);③ chez-api 的 include 目录从**当前运行时的
;;;   可执行文件**反推(bake 写死 `command -v scheme`)—— 拿另一个 Chez 的
;;;   scheme.h 去编,ABI 对不上,是真会炸的。

(library (chandler native-build)
  (export native-task native-task*
          native-owner-segs native-soname-of native-fingerprint toolchain-id
          run-native-backend chez-include-dir
          native-gen-dir native-loader-source
          record-native-loader! emit-native-loaders! prescan-native-loaders!
          install-native-hooks! reset-native-state!)
  (import (chezscheme)
          (chandler base)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph)
          (chandler compile))

  ;; ====================================================================
  ;; §19b Chez C API include 目录(designs/20 §Chez include 路径解析)
  ;;   只有 Model B(chez-api #t)需要。解析序:
  ;;   1. env CHEZ_INCLUDE_DIR(显式覆盖,最高优先)
  ;;   2. 从**当前运行时**的可执行文件反推 <prefix>/lib/csv<版本>/<mt>/
  ;;   3. 校验 scheme.h 在不在;不在就**立刻**报错(而不是编到一半才炸)
  ;;
  ;;   第 2 步 bake 写死 `command -v scheme`。跑在 skiff 上时那会拿到 PATH 上
  ;;   随便哪个 Chez 的头文件,与真正链接的运行时 ABI 未必一致 —— 编得过、跑起来
  ;;   崩。故改为跟着运行时走(与 -j worker 同一套 CHANDLER_SKIFF/CHANDLER_SCHEME);
  ;;   skiff 若不按这个布局摆头文件,报的是可操作的「设 CHEZ_INCLUDE_DIR」。
  ;; ====================================================================

  (define (chez-include-dir)
    (define (validated dir)
      (if (file-exists? (string-append dir "/scheme.h"))
          dir
          (bail-config
            "Chez C API header not found: ~a/scheme.h\n  (Model B / chez-api needs it; set CHEZ_INCLUDE_DIR to override)"
            dir)))
    (cond
      ((getenv* "CHEZ_INCLUDE_DIR") => validated)
      (else
       (let* ((rt  (worker-runtime))
              (exe (guard (e (#t "")) (string-trim (run/capture "command -v" (shq rt))))))
         (when (string=? exe "")
           (bail-config "cannot locate `~a` on PATH to derive CHEZ_INCLUDE (set CHEZ_INCLUDE_DIR)" rt))
         ;; <...>/bin/scheme → <...>/lib/csv<ver>/<mt>/
          (let* ((bin  (parent-dir-or-dot exe))              ; <...>/bin
                 (root (parent-dir-or-dot bin))              ; <...>
                (dir  (string-append root "/lib/csv" (chez-version-string)
                                     "/" (current-machine-type))))
           (validated dir))))))

  ;; ====================================================================
  ;; §19c native-task — recipe API(designs/20 §三个后端)
  ;;
  ;;   (native-task 'async
  ;;     (lib chez-async)              ; **所属库** —— native 嵌在它下面;
  ;;                                   ; 默认 (symbol->string name)(独立)
  ;;     (dir "native/async")          ; 源码目录;默认 "native/<name>"
  ;;     (build (script "build.sh"))   ; 后端:(script "x") | make | (cmake …)
  ;;     (chez-api #t)                 ; 默认 #f(Model A);#t → 注入 CHEZ_INCLUDE
  ;;     (produces "async"))           ; soname;默认 (symbol->string name)
  ;;
  ;;   落点:_build/<mt>/<lib>/native/<soname>.<ext>。native 属于某个库,故嵌在
  ;;   **那个库**的命名空间下 —— chez-async 的全部产物(编译的 Scheme .so + native)
  ;;   共处一个 _build/<mt>/chez-async/ 目录,而不是散成平级的顶层工程。源码留在
  ;;   <dir>(你的 C 代码);**所有**构建产物落进按 machine-type 分区的 _build 树 ——
  ;;   源码树永不被污染。cmake 在 _build/.cmake/<mt>/<name>/ 里做 out-of-source ——
  ;;   scratch 刻意放在可交付的 _build/<mt>/ **之外**,于是 install 永远不会把 cmake
  ;;   中间产物拷过去。一个 file 任务建产物(前置 = <dir> 下每个文件,按内容取指纹),
  ;;   一个同名 phony 依赖它。后端跑完我们核验产物落位。这层 <lib>/native/ 嵌套正是
  ;;   install(_build/<mt>/ → <prefix>/<mt>/)原样带过去的形状。
  ;;
  ;;   信任:**你自己 chandler-tasks.ss 里**的 native-task 是被信任的(与 run/sh 同一档)。
  ;;   **依赖**的 native 构建是 RCE,由 chandler 的 `--allow-build` 把关
  ;;   (见 designs/07 §2-3、designs/08 §3)—— 不在本模块职责内。
  ;; ====================================================================

  (define-clause-task native-task native-task*)

  ;; 所属库拆成名字段:(lib chez-async) → ("chez-async");(lib (chez async)) →
  ;; ("chez" "async")。默认 = 本任务自己的名字(独立 native)。名字段 1:1 映到
  ;; 交付路径,也映到生成 loader 的库名(designs/24)。
  (define (native-owner-segs name clauses)
    (let ((l (%clause 'lib clauses #f)))
      (cond
        ((not l) (list (symbol->string name)))
        ((symbol? l) (list (symbol->string l)))
        ((and (pair? l) (for-all symbol? l)) (map symbol->string l))
        (else (bail-config "native-task ~a: (lib …) must be a symbol or list of symbols, got ~s"
                           name l)))))

  (define (native-soname-of name clauses)
    (%clause 'produces clauses (symbol->string name)))

  (define (native-task* name clauses)
    (let* ((sname    (symbol->string name))
           (dir      (%clause 'dir clauses (string-append "native/" sname)))
           (build    (%clause-req 'native-task sname 'build "<backend>" clauses))
           (chez-api (%clause 'chez-api clauses #f))
           (soname   (native-soname-of name clauses))
           (segs     (native-owner-segs name clauses))
           (owner    (string-join segs "/"))
           ;; 产物落在按 machine-type 分区的 _build 树、**所属库**的目录下。
           ;; **关键的分割**:
           ;;   _build/<mt>/<lib>/native/  = 可交付(只有最终 .so)
           ;;   _build/.cmake/<mt>/<name>/ = cmake out-of-source scratch(按任务名
           ;;                                分键,共享同一个库的兄弟任务不撞)
           ;; scratch 在 _build/<mt>/ **之外**,故 `install`(整体拷 _build/<mt>/)
           ;; 绝不会捎上 cmake 的缓存与中间 .so。它照样按 mt 分键、照样被 clean 扫掉。
           (outbase  (string-append (build-dir) "/" owner))
           (landing  (string-append outbase "/native"))
           (bdir     (string-append "_build/.cmake/" (current-machine-type) "/" sname))
           (target   (string-append landing "/" soname "." (so-ext)))
           ;; 前置 = <dir> 下每个源文件。产物不再落在源码树里,故无需排除自产物。
           (prereqs  (files-under dir)))
      ;; 内容指纹(designs/20/07):源码内容 + build 声明 + chez-api + soname +
      ;; chez 版本 + machine-type + 工具链。touch 不再触发重建;换 Chez / 换工具链
      ;; 会。经 fingerprint-providers 汇入与编译库同一条 manifest/needed? 通路。
      (hashtable-set! fingerprint-providers target
                      (lambda () (native-fingerprint prereqs build chez-api soname)))
      (register-task! target 'file prereqs
                      (lambda (t deps) (run-native-backend name dir build chez-api soname landing bdir t))
                      #f)
      (register-task! name 'phony (list target) #f #f)
      ;; designs/24:把这个 soname 声明给所属库的生成 loader。幂等 + 内容不变不写;
      ;; load-recipe 的预扫通常已经先到(它必须先到,build-graph 才解析得到 loader
      ;; 库),这一句覆盖的是**程序化创建**的 native-task。
      (record-native-loader! segs soname)
      (emit-native-loaders!)))

  ;; 相关工具链版本的哈希(C 编译器恒计;后端的驱动程序也计)。gcc→clang 或
  ;; cmake 版本变动都会改 ABI/输出,故必须使指纹失效(designs/20 §指纹)。
  ;;
  ;; **按后端记忆化**:本函数是 native-fingerprint 的一部分,而后者作为
  ;; fingerprint-providers 里的 thunk 会被 fingerprint-of 反复调用(needed? 一次、
  ;; 记录指纹一次、下游算指纹时还会再来)。每次都 fork 两个子进程去问
  ;; `cc --version` / `cmake --version`,而工具链在一个进程的生命周期里不会变。
  ;; **刻意不进 reset-native-state!**:复位钩子是每次 load-recipe / 每棵依赖树跑一遍,
  ;; 清掉它等于没缓存;而「同一进程内工具链换了」不是真实场景。
  (define toolchain-cache (make-hashtable string-hash string=?))

  (define (toolchain-id build)
    (define (ver cmd) (guard (e (#t "")) (string-trim (run/capture cmd))))
    (let ([key (datum->string build)])
      (or (hashtable-ref toolchain-cache key #f)
          (let ([id (sha256-string
                      (string-append
                        "cc\n"   (ver "cc --version 2>/dev/null | head -1")
                        "\nbk\n" (cond ((and (pair? build) (eq? (car build) 'cmake))
                                        (ver "cmake --version 2>/dev/null | head -1"))
                                       ((eq? build 'make) (ver "make --version 2>/dev/null | head -1"))
                                       (else ""))))])
            (hashtable-set! toolchain-cache key id)
            id))))

  (define (native-fingerprint prereqs build chez-api soname)
    (sha256-string
      (string-append
        "SRC\n"   (string-join (list-sort string<? (map sha256-file prereqs)) ",")
        "\nBUILD\n"   (datum->string build)
        "\nCHEZAPI\n" (if chez-api "1" "0")
        "\nSONAME\n"  soname
        "\nCHEZ\n"    (scheme-version)
        "\nMT\n"      (current-machine-type)
        "\nTOOL\n"    (toolchain-id build))))

  ;; ====================================================================
  ;; §19d 后端派发 + 落点核验(designs/20 §落点不变量)
  ;; ====================================================================

  (define (run-native-backend name dir build chez-api soname landing bdir target)
    (ensure-dir landing)                       ; NATIVE_OUT / CMAKE_INSTALL_PREFIX
    (let ((inc (and chez-api (chez-include-dir))))
      (cond
        ((and (pair? build) (eq? (car build) 'script))
         (run-script-backend dir (cadr build) landing inc))
        ((eq? build 'make)
         (run-make-backend dir landing inc))
        ((and (pair? build) (eq? (car build) 'cmake))
         (run-cmake-backend dir (cdr build) landing inc soname bdir))
        (else
         (bail-config "native-task ~a: unknown backend ~s" (symbol->string name) build))))
    ;; 落点不变量:核验产物确实在统一加载期望的位置。
    (unless (file-exists? target)
      (bail-exec "native-task ~a: backend did not produce ~a\n  (expected <soname>.<ext> in ~a)"
                 (symbol->string name) target landing))
    ;; 记下指纹,于是下次运行会跳过没变的构建(designs/07 —— 与 compile-lib 同招)。
    (hashtable-set! fp-manifest target (fingerprint-of target)))

  ;; script 后端(designs/20 §script 后端:环境契约):在包源码目录里跑脚本,带上
  ;; NATIVE_OUT/MACHINE_TYPE/SOEXT [+ CHEZ_INCLUDE]。环境前缀用 (chandler proc)
  ;; 的 env-prefix(它跳过值为 #f 的项,正是 CHEZ_INCLUDE 可选所需)。

  (define (run-script-backend dir script landing inc)
    (let ((cmd (string-append
                 "cd " (shq dir) " && "
                 (env-prefix (list (cons "NATIVE_OUT"   (%abs landing))
                                   (cons "MACHINE_TYPE" (current-machine-type))
                                   (cons "SOEXT"        (so-ext))
                                   (cons "CHEZ_INCLUDE" inc)))
                 "sh " (shq script))))
      (unless (*quiet*)
        (display "native: script ") (display dir) (display "/") (display script) (newline))
      (let ((rc (system cmd)))
        (unless (= rc 0)
          (bail-exec "native script backend failed (exit ~a): ~a" rc cmd)))))

  ;; make 后端:autotools 的 DESTDIR/PREFIX 都指向落点目录。
  (define (run-make-backend dir landing inc)
    (let ((abs (%abs landing)))
      (let ((cmd (string-append
                   "cd " (shq dir) " && "
                   ;; autotools 契约(PREFIX/DESTDIR)+ 与 script 后端同样的
                   ;; MACHINE_TYPE/SOEXT,好让 Makefile 可移植地命名输出
                   ;; (.so/.dylib/.dll)。
                   (env-prefix (list (cons "MACHINE_TYPE" (current-machine-type))
                                     (cons "SOEXT"        (so-ext))
                                     (cons "CHEZ_INCLUDE" inc)))
                   "make PREFIX=" (shq abs) " DESTDIR= install")))
        (unless (*quiet*) (display "native: make ") (display dir) (newline))
        (let ((rc (system cmd)))
          (unless (= rc 0) (bail-exec "native make backend failed (exit ~a): ~a" rc cmd))))))

  ;; cmake 后端(designs/20 §cmake 配方):三段式,out-of-source。bdir 是
  ;; _build/.cmake/<mt>/<name> —— 按 mt + native-task 名分键的 scratch,在可交付树
  ;; (_build/<mt>/)**之外**,故 install 永远不会拷走 cmake 缓存、也不会拷走 cmake
  ;; 在 bdir 里先建出、随后才 install 到 <landing> 的那个 .so。
  (define (run-cmake-backend dir spec landing inc soname bdir)
    (let* ((abs   (%abs landing))
           (defs  (%clause 'defines spec '()))
           (dflag (apply string-append
                         (map (lambda (d) (string-append " -D" (car d) "=" (shq (cadr d)))) defs)))
           (iflag (if inc (string-append " -DCHEZ_INCLUDE=" (shq inc)) ""))
           (tgts  (%clause 'targets spec #f))
           (tflag (if tgts (string-append " --target " (shq tgts)) "")))
      (ensure-dir bdir)
      (unless (*quiet*) (display "native: cmake ") (display dir) (newline))
      (for-each
        (lambda (cmd)
          (let ((rc (system cmd)))
            (unless (= rc 0) (bail-exec "native cmake backend failed (exit ~a): ~a" rc cmd))))
        (list
          (string-append "cmake -S " (shq dir) " -B " (shq bdir)
                         " -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=" (shq abs)
                         dflag iflag)
          (string-append "cmake --build " (shq bdir) tflag " -j")
          (string-append "cmake --install " (shq bdir))))))

  ;; ====================================================================
  ;; §19e 生成的 native loader(designs/24 —— 自加载优先,统一加载兜底)
  ;;
  ;;   对每个带 native-task 的所属库 <lib>,生成
  ;;
  ;;     (library (<lib> native-loader)
  ;;       (export native-loaded native-foreign-procedure) …)
  ;;
  ;;   其库体负责定位并 load-shared-object 该库的 native 产物。作者的 FFI 模块
  ;;   import 它,并写 `native-foreign-procedure` 而不是裸 `foreign-procedure`。
  ;;
  ;;   两条**实验确立**的硬约束塑造了生成代码(designs/24 §实验校准的三条硬约束;
  ;;   Chez 10.4.1/ta6le):
  ;;
  ;;   1. 裸 `import` **不会** invoke 一个库 —— Chez 由**运行期引用**算 invoke
  ;;      依赖。故 loader 导出一个宏,展开成 (begin native-loaded
  ;;      (foreign-procedure …)):正是对 `native-loaded` 的这次引用,强制加载
  ;;      发生在任何 foreign 入口被解析之前。同一条引用边也是
  ;;      compile-whole-program 保留 loader 的原因(活的绑定,而不是优化器
  ;;      「不敢删」的副作用)。
  ;;   2. 在 boot 文件里,`guard` **抓不住** load-shared-object 的失败(进程直接
  ;;      abort)。故每个候选都用 file-exists? **预检**而非试探。只有最后那次裸
  ;;      soname 尝试(走 ld 搜索路径 —— 没什么可预检的)仍带 guard:guard 能起
  ;;      作用的场合它给出好消息,不起作用的场合链条也已穷尽,横竖都是失败。
  ;;
  ;;   生成的源码落 _build/.gen/ —— 在 _build 树内(故 clean 收得回),但在可交付的
  ;;   _build/<mt>/ 树**外**(故 install 不会交付它),且**不**按 mt 分区:这段代码
  ;;   不烤进任何平台事实,so-ext / machine-type / 候选路径全在运行期推。消费者只会
  ;;   见到编译好的 _build/<mt>/<lib>/native-loader.so。
  ;; ====================================================================

  (define (native-gen-dir) "_build/.gen")

  ;; libpath("chez-async" | "chez/async")→ (segs . sonames),按声明序
  (define native-loader-decls (make-hashtable string-hash string=?))

  (define (record-native-loader! segs soname)
    (let* ((key (string-join segs "/"))
           (cur (hashtable-ref native-loader-decls key #f))
           (old (if cur (cdr cur) '())))
      (hashtable-set! native-loader-decls key
                      (cons segs (if (member soname old) old (append old (list soname)))))))

  (define (add-gen-root!)
    (*gen-roots* (list (native-gen-dir)))
    (unless (member (native-gen-dir) (lib-roots))
      (lib-roots (append (lib-roots) (list (native-gen-dir))))))

  ;; 对 recipe 顶层 form 的预扫(由 load-recipe 在**任何 form 求值之前**调用)。
  ;; 直接从源 s-表达式里读 `(native-task 'name clause …)` 声明 —— clause 列表是
  ;; 字面数据,与 native-task* 收到的形状一致 —— 并生成 loader 库,好让
  ;; build-graph 解析得到它,不论 recipe 把 native-task 写在哪里。
  ;; **刻意不致命**:这里跳过格式不对的声明,等那个 form 真被求值时由
  ;; native-task* 好好报错。
  (define (prescan-native-loaders! forms)
    (for-each
      (lambda (f)
        (when (and (pair? f) (eq? (car f) 'native-task) (pair? (cdr f)))
          (guard (e (#t (void)))
            (let* ((nm   (cadr f))
                   (name (if (and (pair? nm) (eq? (car nm) 'quote)) (cadr nm) nm))
                   (cls  (cddr f)))
              (when (symbol? name)
                (record-native-loader! (native-owner-segs name cls)
                                       (native-soname-of name cls)))))))
      forms)
    (emit-native-loaders!))

  (define (emit-native-loaders!)
    (let ((keys (list-sort string<? (vector->list (hashtable-keys native-loader-decls)))))
      (unless (null? keys)
        (for-each
          (lambda (k)
            (let ((v (hashtable-ref native-loader-decls k #f)))
              (write-text-if-changed
                (string-append (native-gen-dir) "/" k "/native-loader.ss")
                (native-loader-source (car v) (cdr v)))))
          keys)
        (add-gen-root!))))

  ;; 定位只走 `(library-directories)`(D8:APP_ROOT 已完全去除)——进程对着哪些
  ;; 前缀跑,native 就在那些前缀的 `<obj侧>/<libpath>/native/` 下。
  (define (native-loader-source segs sonames)
    (let ((libname (string-join segs " "))         ; (chez async)   → 库名
          (libpath (string-join segs "/")))        ; chez/async     → 交付路径
      (string-append
        ";; generated by chandler (designs/24) — do not edit; regenerated each build.\n"
        ";; Self-loading native locator for library (" libname ").\n"
        "(library (" libname " native-loader)\n"
        "  (export native-loaded native-foreign-procedure)\n"
        "  (import (chezscheme))\n"
        "  (define (so-ext)\n"
        "    (let* ((m (symbol->string (machine-type))) (n (string-length m)))\n"
        "      (cond ((and (>= n 2) (string=? (substring m (- n 2) n) \"nt\")) \"dll\")\n"
        "            ((and (>= n 3) (string=? (substring m (- n 3) n) \"osx\")) \"dylib\")\n"
        "            (else \"so\"))))\n"
        ;; §约束 2 —— 预检,不试探:在 boot 文件里一次未命中就 abort。
        "  (define (load-if-exists p)\n"
        "    (and (file-exists? p) (begin (load-shared-object p) #t)))\n"
        "  (define (obj-dir d) (if (pair? d) (cdr d) d))\n"
        "  (define (locate! soname)\n"
        ;; 候选 1:扫 (library-directories) 各条目的**对象**侧。
        "    (or (let loop ((ds (library-directories)))\n"
        "          (and (pair? ds)\n"
        "               (or (load-if-exists\n"
        "                     (string-append (obj-dir (car ds)) \"/" libpath "/native/\" soname))\n"
        "                   (loop (cdr ds)))))\n"
        "        (load-if-exists\n"
        "          (string-append \"_build/\" (symbol->string (machine-type))\n"
        "                         \"/" libpath "/native/\" soname))\n"
        "        (guard (e (#t #f)) (load-shared-object soname) #t)\n"
        "        (assertion-violation 'native-loader\n"
        "          \"cannot locate native library (run `chandler build` first)\" soname)))\n"
        "  (define native-loaded\n"
        "    (begin\n"
        (apply string-append
               (map (lambda (s)
                      (string-append "      (locate! (string-append \"" s "\" \".\" (so-ext)))\n"))
                    sonames))
        "      #t))\n"
        ;; §约束 1 —— 对 native-loaded 的引用就是那条 invoke 边(也是全程序优化
        ;; 保留本库的原因)。
        "  (define-syntax native-foreign-procedure\n"
        "    (syntax-rules ()\n"
        "      ((_ conv ...) (begin native-loaded (foreign-procedure conv ...))))))\n")))

  ;; 项目相对目录的绝对路径(env 变量传给的是已经 `cd` 进包目录的子 shell,
  ;; 相对落点会失效)。bake 那份 shell 出去跑 `pwd`;进程自己就知道 cwd。
  (define (%abs p)
    (if (absolute-path? p) p (string-append (current-directory) "/" p)))

  ;; ── 装配 + 复位(与 (chandler compile) 同一套理由:Chez 惰性实例化库,
  ;;    而 recipe 求值前就得有 native-task;单二进制里同进程二次构建要复位)──
  (define (install-native-hooks! )
    (current-native-prescan prescan-native-loaders!)
    (register-recipe-library! '(chandler native-build))
    (register-recipe-reset! 'native-build reset-native-state!))

  (define (reset-native-state!)
    (hashtable-clear! native-loader-decls))

  (install-native-hooks!)

  )
