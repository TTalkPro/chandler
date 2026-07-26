#!chezscheme
;;; tests/chandler/native-build.ss --- (chandler native-build) 测试
;;;
;;; 覆盖:clause 解析(所属库/soname)、指纹输入、loader 代码生成的两条硬约束
;;; (library-directories 扫描 + native-loaded 引用边)、预扫、落点不变量,以及 script 后端
;;; 端到端(真 cc 编一个 C 库,真跑 FFI)。
;;;
;;; 环境门:没有 `cc` 就跳过真编 C 的用例;没有 Chez 编译器(Petite)跳过要编库的。

(library (tests chandler native-build)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (tests chandler fixtures)
          (chandler base)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph)
          (chandler compile)
          (chandler native-build))

  (define (with-proj files proc)
    (let ((d (mktmp)) (old (current-directory)))
      (for-each (lambda (f)
                  (let ((p (join-paths d (car f))))
                    (ensure-parent p)
                    (write-file p (cdr f))))
                files)
      (dynamic-wind
        (lambda () (current-directory d))
        (lambda () (proc d))
        (lambda () (current-directory old) (rm-rf d)))))

  (define (silently thunk)
    (let ((sink (open-output-string)))
      (guard (e (#t (raise e)))
        (parameterize ((current-output-port sink) (*quiet* #t))
          (thunk)))))

  ;; 环境门:真编 C + 编 Scheme 库都具备才跑端到端用例。
  (define (cc-available?) (= 0 (run/code "command -v cc >/dev/null 2>&1")))
  (define (needs-toolchain proc)
    (when (and (compiler-available?) (cc-available?)) (proc)))

  ;; 一个带 native 的最小工程:C 源 + build.sh + 用 native-foreign-procedure 的库。
  (define native-files
    '(("native/greet/greet.c" . "int greet_answer(void) { return 42; }\n")
      ("native/greet/build.sh" . "set -e\ncc -shared -fPIC -o \"$NATIVE_OUT/greet.$SOEXT\" greet.c\n")
      ("mylib/ffi.sls" .
       "(library (mylib ffi)\n  (export answer)\n  (import (chezscheme) (mylib native-loader))\n  (define answer (native-foreign-procedure \"greet_answer\" () int)))\n")
      ("check.ss" . "(import (chezscheme) (mylib ffi))(display (answer))(newline)\n")
      ("recipe.ss" .
       "(define-lib-roots \".\")\n(native-task 'greet (lib mylib) (dir \"native/greet\") (build (script \"build.sh\")) (produces \"greet\"))\n(library-task 'libs '(mylib ffi))\n(task 'build '(greet libs) (lambda () (void)))\n(default-task 'build)\n")))

  (define (build!)
    (silently
      (lambda ()
        (install-compile-hooks!)
        (install-native-hooks!)
        (load-recipe "recipe.ss")
        (load-fp-manifest!)
        (invoke-task 'build)
        (write-fp-manifest!))))

  (define-suite suite

    (owner-segs
      ;; (lib …) 决定 native 嵌在哪个库下;缺省用任务自己的名字(独立 native)。
      (assert-equal '("greet") (native-owner-segs 'greet '()))
      (assert-equal '("mylib") (native-owner-segs 'greet '((lib mylib))))
      (assert-equal '("chez" "async") (native-owner-segs 'a '((lib (chez async)))))
      (assert-raises (lambda () (native-owner-segs 'a '((lib "string")))))
      (*exit-code* exit-ok))

    (soname-default-and-override
      (assert-string= "greet" (native-soname-of 'greet '()))
      (assert-string= "libgreet" (native-soname-of 'greet '((produces "libgreet")))))

    (clause-required-build
      ;; (build …) 是必填 clause,缺了给统一、可操作的话。
      (with-proj '(("x" . ""))
        (lambda (d)
          (assert-raises (lambda () (native-task* 'greet '((lib mylib)))))
          (*exit-code* exit-ok))))

    (loader-source-constraints
      ;; designs/24 的两条硬约束必须体现在生成文本里:
      ;;   ① 导出的宏展开成 (begin native-loaded (foreign-procedure …)) —— 那次
      ;;      对 native-loaded 的引用才是 invoke 边(裸 import 不 invoke 库);
      ;;   ② 候选路径一律 file-exists? **预检**,只有最后的裸 soname 才 guard
      ;;      (boot 文件里 guard 抓不住 load-shared-object 失败,进程直接 abort)。
      (let ((src (native-loader-source '("chez" "async") '("async"))))
        (assert-true (string-contains? src "(library (chez async native-loader)"))
        (assert-true (string-contains? src "(export native-loaded native-foreign-procedure)"))
        (assert-true (string-contains? src "(begin native-loaded (foreign-procedure conv ...))"))
        (assert-true (string-contains? src "(define (load-if-exists p)"))
        (assert-true (string-contains? src "(file-exists? p)"))
        (assert-true (string-contains? src "/chez/async/native/"))
        ;; 兜底候选:扫 (library-directories) 的**对象**侧
        (assert-true (string-contains? src "(obj-dir (car ds))"))
        ;; 报错话术随工具名走
        (assert-true (string-contains? src "run `chandler build` first"))))

    (loader-source-multiple-sonames
      ;; 同一个库声明多个 native → 逐个 locate!,按声明序。
      (let ((src (native-loader-source '("mylib") '("a" "b"))))
        (assert-true (string-contains? src "(locate! (string-append \"a\" \".\" (so-ext)))"))
        (assert-true (string-contains? src "(locate! (string-append \"b\" \".\" (so-ext)))"))
        (assert-true (< (string-search src "\"a\"") (string-search src "\"b\"")))))

    (record-loader-dedup
      ;; 同名 soname 重复声明不重复登记;不同的按序追加。
      (with-proj '(("x" . ""))
        (lambda (d)
          (reset-native-state!)
          (record-native-loader! '("mylib") "a")
          (record-native-loader! '("mylib") "a")
          (record-native-loader! '("mylib") "b")
          (silently (lambda () (emit-native-loaders!)))
          (let ((src (read-file-string "_build/.gen/mylib/native-loader.ss")))
            (assert-equal 1 (length (filter (lambda (l) (string-contains? l "\"a\""))
                                            (split-lines src))))
            (assert-true (string-contains? src "\"b\"")))
          (reset-native-state!))))

    (emit-adds-gen-root
      ;; 生成 loader 后 _build/.gen 必须进搜索根,否则 build-graph 解析不到
      ;; (<lib> native-loader);且它进 *gen-roots*,好被 define-lib-roots 接回去。
      (with-proj '(("x" . ""))
        (lambda (d)
          (reset-native-state!)
          (parameterize ((lib-roots (list ".")) (*gen-roots* '()))
            (record-native-loader! '("mylib") "a")
            (silently (lambda () (emit-native-loaders!)))
            (assert-equal '("_build/.gen") (*gen-roots*))
            (assert-true (member "_build/.gen" (lib-roots))))
          (reset-native-state!))))

    (prescan-reads-declarations
      ;; 预扫直接读 recipe 的 s-表达式(clause 是字面数据),故 native-task 写在
      ;; recipe 哪个位置都不影响 —— loader 源码在任何 form 求值前就已落盘。
      (with-proj '(("x" . ""))
        (lambda (d)
          (reset-native-state!)
          (silently
            (lambda ()
              (prescan-native-loaders!
                '((define-lib-roots ".")
                  (library-task 'libs '(mylib ffi))
                  (native-task 'greet (lib mylib) (build (script "b.sh")) (produces "greet"))))))
          (assert-true (file-exists? "_build/.gen/mylib/native-loader.ss"))
          (assert-true (string-contains? (read-file-string "_build/.gen/mylib/native-loader.ss")
                                         "\"greet\""))
          (reset-native-state!))))

    (prescan-skips-malformed
      ;; 格式不对的声明这里**跳过**(不致命),留给 native-task* 求值时好好报错。
      (with-proj '(("x" . ""))
        (lambda (d)
          (reset-native-state!)
          (silently
            (lambda ()
              (prescan-native-loaders! '((native-task)
                                         (native-task "not-a-symbol" (lib mylib))
                                         (not-a-native-task 'x)))))
          (assert-false (file-exists? "_build/.gen"))
          (reset-native-state!))))

    (fingerprint-inputs
      ;; 指纹随 soname / chez-api / build 声明变(设计要求:换工具链或声明即失效)。
      (with-proj '(("native/greet/greet.c" . "int f(void){return 1;}\n"))
        (lambda (d)
          (let ((srcs (files-under "native/greet")))
            (let ((base (native-fingerprint srcs '(script "b.sh") #f "greet")))
              (assert-false (string=? base (native-fingerprint srcs '(script "b.sh") #t "greet")))
              (assert-false (string=? base (native-fingerprint srcs '(script "b.sh") #f "other")))
              (assert-false (string=? base (native-fingerprint srcs 'make #f "greet")))
              (assert-string= base (native-fingerprint srcs '(script "b.sh") #f "greet")))))))

    (chez-include-dir-validates
      ;; CHEZ_INCLUDE_DIR 显式覆盖仍要校验 scheme.h 在不在 —— 缺了就**立刻**报,
      ;; 而不是编到一半让 cc 抛一堆看不懂的话。
      (with-proj '(("inc/scheme.h" . "/* stub */\n") ("noinc/keep" . ""))
        (lambda (d)
          (putenv "CHEZ_INCLUDE_DIR" (join-paths d "inc"))
          (assert-string= (join-paths d "inc") (chez-include-dir))
          (putenv "CHEZ_INCLUDE_DIR" (join-paths d "noinc"))
          (assert-raises (lambda () (chez-include-dir)))
          (putenv "CHEZ_INCLUDE_DIR" "")
          (*exit-code* exit-ok))))

    (hooks-installed
      ;; 与 compile 同理:必须显式装配 —— Chez 惰性实例化库,而 load-recipe
      ;; 的预扫要在任何 form 求值前就拿到 native 的 prescan。
      (install-native-hooks!)
      (assert-true (member '(chandler native-build) (recipe-environment-libs)))
      (assert-true (eq? prescan-native-loaders! (current-native-prescan))))

    (script-backend-end-to-end
      ;; 真 cc 编 C → 落 _build/<mt>/<lib>/native/ → 生成并编 loader → 编 FFI 库
      ;; → 只给对象根跑起来,FFI 真调通(自加载)。
      (needs-toolchain (lambda ()
        (with-proj native-files
          (lambda (d)
            (build!)
            (let ((so (string-append (build-dir) "/mylib/native/greet." (so-ext))))
              (assert-true (file-exists? so))
              (assert-true (file-exists? (string-append (build-dir) "/mylib/native-loader.so")))
              (assert-true (file-exists? (string-append (build-dir) "/mylib/ffi.so")))
              (let ((r (run-capture "scheme"
                                    (list "-q" "--libdirs" (join-paths d (build-dir))
                                          "--script" (join-paths d "check.ss")))))
                (assert-equal 0 (proc-result-code r))
                (assert-string= "42" (string-trim (proc-result-out r))))
              ;; 搬走 native → 报的是 loader 自己的话(而不是 Chez 的 unbound)
              (move-file so (join-paths d "moved.so"))
              (let ((r (run-capture "scheme"
                                    (list "-q" "--libdirs" (join-paths d (build-dir))
                                          "--script" (join-paths d "check.ss")))))
                (assert-false (= 0 (proc-result-code r)))
                (assert-true (string-contains? (proc-result-err r) "native-loader")))))))))

    (landing-invariant-enforced
      ;; 后端跑完但产物没落在约定位置 → 明确报「backend did not produce」,
      ;; 而不是等到部署时才发现 native 不见了。
      (needs-toolchain (lambda ()
        (with-proj
          '(("native/greet/build.sh" . "exit 0\n")     ; 什么也不产
            ("recipe.ss" . "(define-lib-roots \".\")\n(native-task 'greet (lib mylib) (dir \"native/greet\") (build (script \"build.sh\")))\n(default-task 'greet)\n"))
          (lambda (d)
            (assert-raises
              (lambda ()
                (silently (lambda ()
                  (install-compile-hooks!) (install-native-hooks!)
                  (load-recipe "recipe.ss") (invoke-task 'greet)))))
            (assert-equal exit-exec-error (*exit-code*))
            (*exit-code* exit-ok))))))

    (unknown-backend-rejected
      (with-proj
        '(("native/greet/keep" . "")
          ("recipe.ss" . "(define-lib-roots \".\")\n(native-task 'greet (lib mylib) (dir \"native/greet\") (build bogus))\n(default-task 'greet)\n"))
        (lambda (d)
          (assert-raises
            (lambda ()
              (silently (lambda ()
                (install-compile-hooks!) (install-native-hooks!)
                (load-recipe "recipe.ss") (invoke-task 'greet)))))
          (assert-equal exit-config-error (*exit-code*))
          (*exit-code* exit-ok))))

    ))
