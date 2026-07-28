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
          (chandler proc)            ; which(替掉 `command -v`)
          (chandler task-engine)
          (chandler recipe)
          (chandler import-graph)
          (chandler compile)
          (chandler native-build))

  ;; with-proj / silently / when-compiler 来自 (tests chandler fixtures)。

  ;; 环境门:真编 C + 编 Scheme 库都具备才跑端到端用例。
  ;;
  ;; C9:探针从 `command -v cc …`(POSIX shell 内建 + `/dev/null`)换成 proc 的
  ;; `which` —— 它在 Windows 上走 `where.exe`。
  ;;
  ;; 另外这一组还要 POSIX,但**理由与 script 后端无关**(D39 之后后端两平台都能跑,
  ;; 见 fixtures 的 make-native-lib):这里的 build.sh 里写的是
  ;; `cc -shared -fPIC`,那是 gcc/clang 的旗标,MSVC 不认。要在 Windows 上跑,
  ;; 得连**这个 C 工程本身**一起写第二份(cl.exe 的 `/LD`),那是另一件事 ——
  ;; 本组用例验的是 FFI 端到端,不是可移植的 C 构建脚本怎么写。
  (define (cc-available?) (and (which "cc") #t))
  (define (needs-toolchain proc)
    (when-posix
      (lambda ()
        (when (and (compiler-available?) (cc-available?)) (proc)))))

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

    ;; ══════════════════════════════════════════════════════════════
    ;; script 后端的平台派发(纯字符串;`windows-shell?` 参数化,两侧都在
    ;; Linux 上逐字断言 —— 不这么做 cmd 那半边在 CI 里等于从没被执行过)
    ;; ══════════════════════════════════════════════════════════════

    ;; 按扩展名挑本平台能跑的那个。POSIX 侧**刻意不要求 `.sh`** ——
    ;; 现存的包写 `(script "build")` / `"mk.bash"` 都合法,收紧等于判死它们。
    (script-picked-by-platform
      (let ([both '("build.sh" "build.cmd")])
        (assert-string= "build.sh"  (parameterize ([windows-shell? #f]) (pick-script both)))
        (assert-string= "build.cmd" (parameterize ([windows-shell? #t]) (pick-script both))))
      ;; 声明顺序不决定结果:cmd 写在前面,POSIX 照样挑 sh 那个
      (let ([rev '("build.cmd" "build.sh")])
        (assert-string= "build.sh"  (parameterize ([windows-shell? #f]) (pick-script rev)))
        (assert-string= "build.cmd" (parameterize ([windows-shell? #t]) (pick-script rev))))
      ;; 大小写不敏感(NTFS 上 BUILD.CMD 与 build.cmd 是同一个文件)
      (assert-string= "B.CMD" (parameterize ([windows-shell? #t]) (pick-script '("B.CMD"))))
      ;; 无扩展名 / 别的扩展名:POSIX 交给 sh,Windows 跑不了
      (assert-string= "build" (parameterize ([windows-shell? #f]) (pick-script '("build"))))
      (assert-string= "mk.bash" (parameterize ([windows-shell? #f]) (pick-script '("mk.bash"))))
      (assert-false (parameterize ([windows-shell? #t]) (pick-script '("build" "mk.bash")))))

    ;; 挑不出来 → **config 错**,而不是把 `sh build.sh` 扔给 cmd 让它报
    ;; 「'sh' 不是内部或外部命令」—— 那句话既不提 native-task 也不提该怎么办。
    ;;
    ;; **断言落在错误内容与 exit-code 上,不能只是 assert-raises**:后端跑完还有
    ;; 一道「产物在不在落点」的核验,那条也会抛。光看「抛没抛」的话,把本检查
    ;; 整个删掉测试照样绿 —— 验过了,它就是这么绿的。
    (script-backend-rejects-unrunnable-declaration
      (with-proj '(("native/greet/build.sh" . ": > \"$NATIVE_OUT/greet.so\"\n"))
        (lambda (d)
          (let ([sink (open-output-string)])
            (guard (e (#t (void)))
              (parameterize ([current-error-port sink] [windows-shell? #t])
                (run-native-backend 'greet "native/greet" '(script "build.sh") #f
                                    "greet" "_build/x" "_build/.cmake/x" "_build/x/greet.so")))
            (let ([msg (get-output-string sink)])
              (assert-true (string-contains? msg "no build script runnable on this platform"))
              (assert-true (string-contains? msg "build.sh"))
              ;; 可操作:说清 Windows 认什么、该怎么补
              (assert-true (string-contains? msg ".cmd"))
              ;; 没有退化成「跑了 sh 然后抱怨产物不在」
              (assert-false (string-contains? msg "did not produce")))))))

    ;; 反过来:带上 .cmd 之后,同一份声明在 Windows 侧就选得出来了
    (script-backend-accepts-declaration-with-cmd
      (assert-string= "build.cmd"
                      (parameterize ([windows-shell? #t])
                        (pick-script '("build.sh" "build.cmd")))))

    ;; 生成的命令串:两侧逐字。cmd 侧三处差异一次看清 ——
    ;; `cd /d`(漏了会静默不切盘)、`set "K=v" &&`(cmd 完全不认 `K=v cmd`)、
    ;; `call`(不带它调另一个批处理时控制权不返回,errorlevel 也不回传)。
    (script-command-dispatches-on-platform
      (with-proj '(("native/greet/build.sh" . ""))
        (lambda (d)
          (let ([posix (parameterize ([windows-shell? #f])
                         (script-command "native/greet" "build.sh" "_build/out" #f))]
                [win   (parameterize ([windows-shell? #t])
                         (script-command "native/greet" "build.cmd" "_build/out" #f))])
            (assert-true (string-contains? posix "cd 'native/greet' && "))
            (assert-true (string-contains? posix "NATIVE_OUT='"))
            (assert-true (string-contains? posix "sh 'build.sh'"))
            (assert-false (string-contains? posix "call "))

            (assert-true (string-contains? win "cd /d \"native/greet\" && "))
            (assert-true (string-contains? win "set \"NATIVE_OUT="))
            (assert-true (string-contains? win "call \"build.cmd\""))
            ;; CHEZ_INCLUDE 为 #f 时整条跳过(两侧同)
            (assert-false (string-contains? posix "CHEZ_INCLUDE"))
            (assert-false (string-contains? win "CHEZ_INCLUDE"))))))

    ;; chez-api 时 CHEZ_INCLUDE 才出现,且经各自的引用规则
    (script-command-includes-chez-include-when-given
      (with-proj '(("native/greet/build.sh" . ""))
        (lambda (d)
          (assert-true (string-contains?
                         (parameterize ([windows-shell? #t])
                           (script-command "native/greet" "b.cmd" "_build/out" "C:\\chez\\inc"))
                         "set \"CHEZ_INCLUDE=C:\\chez\\inc\""))
          (assert-true (string-contains?
                         (parameterize ([windows-shell? #f])
                           (script-command "native/greet" "b.sh" "_build/out" "/usr/inc"))
                         "CHEZ_INCLUDE='/usr/inc'")))))

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
