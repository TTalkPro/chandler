#!chezscheme
;;; chandler/test/fixtures.ss --- 测试夹具:临时目录 / 文件 / 本地 git 仓构造
;;;
;;; 消除各测试文件各写一份 mktmp/write-file/trim/git-repo-builder 的 boilerplate。
;;; 都基于本地临时 git 仓,不依赖外网。

(library (chandler test fixtures)
  (export mktmp write-file read-file trim substr?
          git-init! git-commit! git-in
          manifest-text lib-umbrella-text
          make-lib-repo make-native-lib make-app)
  (import (chezscheme)
          (chandler util)
          (chandler fs)
          (chandler proc))

  ;; ── 临时目录 / 文件 ──
  (define (mktmp) (trim (proc-result-out (run-capture "mktemp" '("-d")))))
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
         (write-file (string-append dir "/manifest.ss") (manifest-text name deps))
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
      (write-file (string-append dir "/manifest.ss")
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
         (write-file (string-append dir "/manifest.ss")
                     (let ([base (manifest-text "app" deps)])
                       (if (string=? extra "")
                           base
                           ;; 塞在收尾右括号之前
                           (string-append (substring base 0 (- (string-length base) 1))
                                          " " extra ")"))))
         dir)])))
