#!chezscheme
;;; tests/chandler/fixtures.ss --- 测试夹具:临时目录 / 文件 / 本地 git 仓构造
;;;
;;; 消除各测试文件各写一份 mktmp/write-file/trim/git-repo-builder 的 boilerplate。
;;; 都基于本地临时 git 仓,不依赖外网。

(library (tests chandler fixtures)
  (export mktmp write-file read-file trim substr?
          write-file-tree with-file-tree with-proj
          run-quiet silently capture-output when-compiler
          lock-ref
          git-init! git-commit! git-in
          manifest-text lib-umbrella-text
          make-lib-repo make-native-lib make-app)
  (import (chezscheme)
          (tests chandler harness)
          (chandler util)
          (chandler fs)
          (chandler layout)          ; join-paths
          (chandler lock)
          (chandler proc)
          (chandler task-engine)     ; *quiet*
          (chandler compile))        ; compiler-available?

  ;; ── 文件树夹具 ──
  ;; files = (("rel/path" . "内容") …)。四个测试文件先前各写一份这个循环
  ;; (compile / cli-make 的 with-proj 逐字节相同,import-graph 的 with-src-tree
  ;; 与 cli-runtime-env 的 proj-with-files 只差要不要切 cwd)。
  (define (write-file-tree dir files)
    (for-each (lambda (f)
                (let ([p (join-paths dir (car f))])
                  (ensure-parent p)
                  (write-file p (cdr f))))
              files)
    dir)

  ;; 临时目录里铺一棵树,交 proc 处置**绝对根路径**。不动 cwd。
  (define (with-file-tree files proc)
    (let ([d (write-file-tree (mktmp) files)])
      (dynamic-wind
        (lambda () (void))
        (lambda () (proc d))
        (lambda () (rm-rf d)))))

  ;; 同上,但把 cwd 切进去 —— recipe / CLI 通路以 cwd 为项目根。无论成败都还原。
  (define (with-proj files proc)
    (let ([d (write-file-tree (mktmp) files)]
          [old (current-directory)])
      (dynamic-wind
        (lambda () (current-directory d))
        (lambda () (proc d))
        (lambda () (current-directory old) (rm-rf d)))))

  ;; ── stdout 吞噬 ──
  ;; Chez 的 compile-library 自己往 stdout 打 "compiling … with output to …",
  ;; 不受 *quiet* 管,故必须换端口而不只是设 *quiet*。
  ;;
  ;; **guard 先解开 parameterize 再重抛**:否则断言失败时 harness 的 FAIL 行
  ;; 会被打进 sink 一起吞掉,测试报「N failed」却一条都看不见。
  ;;
  ;; 三种用法各有一个名字(不用布尔开关 —— 调用点上 `#t` 说明不了任何事):
  ;;
  ;;   (run-quiet thunk)      换端口;返回 thunk 的值。**不**设 *quiet*:
  ;;                          CLI 用例要的正是任务的正常输出被产生出来
  ;;   (silently thunk)       换端口 + 设 *quiet*;返回 thunk 的值。
  ;;                          编译用例只看产物,连 task-engine 的进度行一起压
  ;;   (capture-output thunk) 换端口;返回**吞下的文本**(断言输出内容用,
  ;;                          故同样不设 *quiet*)
  (define (run-quiet thunk)
    (let ([sink (open-output-string)])
      (guard (e [#t (raise e)])
        (parameterize ([current-output-port sink]) (thunk)))))

  (define (silently thunk)
    (let ([sink (open-output-string)])
      (guard (e [#t (raise e)])
        (parameterize ([current-output-port sink] [*quiet* #t]) (thunk)))))

  (define (capture-output thunk)
    (let ([sink (open-output-string)])
      (guard (e [#t (raise e)])
        (parameterize ([current-output-port sink]) (thunk)))
      (get-output-string sink)))

  ;; ── 编译器门 ──
  ;; Petite 没有编译器(compile-library 一调就抛 "compile package is not loaded")。
  ;; 真编译的用例在它上面**跳过**而不是放宽断言 —— 那些用例验的正是「产出能被
  ;; Chez 加载的对象」,放宽等于不验。scheme / skiff 上照跑。
  (define (when-compiler proc) (when (compiler-available?) (proc)))

  ;; ── lock 里按名取一条依赖 ──
  ;; 曾是 (chandler lock) 的导出,但生产代码从不用它 —— 只有断言在用。
  ;; 收进夹具:它是测试脚手架,不是产品 API。
  (define (lock-ref lk name)
    (find (lambda (d) (eq? (locked-dep-name d) name)) (lock-deps lk)))

  ;; ── 临时目录 / 文件 ──
  ;; 登记进 harness,由 run-suites 逐用例清。空串(mktemp 失败,如磁盘满)当场报错 ——
  ;; 从前它会静默返回 "",调用方随即把夹具写进 **cwd(= 仓库根)**,污染工作区。
  (define (mktmp)
    (let ([d (trim (proc-result-out (run-capture "mktemp" '("-d"))))])
      (when (string=? d "")
        (error 'mktmp "mktemp -d returned empty (disk full? /tmp not writable?)"))
      (register-test-tmp! d)))
  (define (write-file p s) (call-with-output-file p (lambda (o) (display s o)) 'truncate))
  (define (read-file p) (if (file-exists? p) (call-with-input-file p get-string-all) ""))
  (define (trim s) (string-trim s))
  (define (substr? s sub) (string-contains? s sub))

  ;; ── git ──
  (define (git-init! dir)
    (run-check "git" (list "init" "-q" "-b" "main" dir) '())
    (git-in dir "config" "user.email" "t@t")
    (git-in dir "config" "user.name" "t"))
  (define (git-commit! dir msg)
    (git-in dir "add" "-A")
    (git-in dir "commit" "-q" "-m" msg))
  (define (git-in dir . args)
    (run-check "git" (append (list "-C" dir) args) '()))

  ;; ── 清单 / 库文本 ──
  ;; deps: ((sym . url) …) → (name (git url) (branch "main"))
  (define (manifest-text name deps)
    (let ([op (open-output-string)])
      (fprintf op "(manifest (format 1) (name ~s) (version \"0.1.0\") (srcdir \".\")" name)
      (unless (null? deps)
        (display " (deps" op)
        (for-each (lambda (d) (fprintf op " (~a (git ~s) (branch \"main\"))" (car d) (cdr d))) deps)
        (display ")" op))
      (display ")" op)
      (get-output-string op)))

  ;; umbrella:(library (<name>) (export <name>-ok) … (define <name>-ok #t))
  (define (lib-umbrella-text name)
    (format "#!chezscheme~%(library (~a) (export ~a-ok) (import (chezscheme)) (define ~a-ok #t))~%"
            name name name))

  ;; ── 库仓构造 ──
  ;; 单提交库仓:umbrella + manifest;deps 可选((sym . url)…)
  (define make-lib-repo
    (case-lambda
      [(name) (make-lib-repo name '())]
      [(name deps)
       (let ([dir (mktmp)])
         (git-init! dir)
         (write-file (string-append dir "/chandler-manifest.ss") (manifest-text name deps))
         (write-file (string-append dir "/" name ".ss") (lib-umbrella-text name))
         (git-commit! dir "c1")
         dir)]))

  ;; 带 native 声明的库仓(build 授权测试用)
  ;; 带 native 的依赖。后端用 **script** 且脚本只按落点契约产出文件(`: > $NATIVE_OUT/…`)
  ;; —— 不需要 C 编译器:这些用例要验的是授权、落点不变量与产物搬运,不是 cc。
  ;; (2026-07-24 之前后端写的是 `make`、也没有 native/ 目录,那时构建被 mock bake
  ;; 挡着从不真跑;进程内编译后它会真的去执行,故补成一个真能跑的最小后端。)
  (define (make-native-lib name soname)
    (let ([dir (mktmp)])
      (git-init! dir)
      (write-file (string-append dir "/chandler-manifest.ss")
        (format "(manifest (format 1) (name ~s) (version \"0.1.0\") (srcdir \".\") (native (~a (path \"native/~a\") (build (script \"build.sh\")))))"
                name soname soname))
      (write-file (string-append dir "/" name ".ss") (lib-umbrella-text name))
      (ensure-dir (string-append dir "/native/" soname))
      (write-file (string-append dir "/native/" soname "/build.sh")
                  (string-append ": > \"$NATIVE_OUT/" soname ".$SOEXT\"\n"))
      (git-commit! dir "c1")
      dir))

  ;; app 项目目录(仅 manifest,name "app",deps=((sym . url)…))。
  ;; 可选第二参:插进 manifest 的额外字段文本(如 (chandler ">=0.1.0") 运行时门)。
  (define make-app
    (case-lambda
      [(deps) (make-app deps "")]
      [(deps extra)
       (let ([dir (mktmp)])
         (write-file (string-append dir "/chandler-manifest.ss")
                     (let ([base (manifest-text "app" deps)])
                       (if (string=? extra "")
                           base
                           ;; 塞在收尾右括号之前
                           (string-append (substring base 0 (- (string-length base) 1))
                                          " " extra ")"))))
         dir)])))
