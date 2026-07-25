#!chezscheme
;;; chandler/test/layout.ss --- (chandler layout) 测试

(library (chandler test layout)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
          (chandler util)          ; string-suffix?(判平台)
          (chandler layout))

  (define-suite suite
    (machine-type-nonempty
      (assert-true (> (string-length (current-machine-type)) 0)))

    (so-ext-on-this-host
      ;; 本机 ta6le → so(测试机为 Linux)
      (assert-string= "so" (so-ext)))

    (join-paths-basic
      (assert-string= "a/b/c" (join-paths "a" "b" "c"))
      (assert-string= "a/c" (join-paths "a" "." "c"))
      (assert-string= "a/b" (join-paths "a" "" "b"))
      (assert-string= "" (join-paths)))

    (path-join-slash
      (assert-string= "a/b" (path-join "a" "b"))
      (assert-string= "a/b" (path-join "a/" "b"))
      (assert-string= "b" (path-join "" "b"))
      (assert-string= "a" (path-join "a" "")))

    ;; src/mt 拆分:安装前缀 → (源 . 对象) 对;条目 → --libdirs 串
    (split-pair-and-args
      ;; 分隔符随平台:Chez $separator-character —— Windows ";" 其余 ":";
      ;; 条目内双分隔符表 (源 . 对象),条目间单分隔符(见 layout.ss 注释)。
      (let* ([sp (path-sep)] [mt (current-machine-type)]
             [dbl (string-append sp sp)])
        (assert-string= (if (string-suffix? "nt" mt) ";" ":") sp)
        (assert-equal (cons "/pfx/src" (string-append "/pfx/" mt))
                      (split-pair "/pfx"))
        (assert-string= (string-append "/pfx/src" dbl "/pfx/" mt)
                        (entry->arg (split-pair "/pfx")))
        (assert-string= "/plain" (entry->arg "/plain"))
        (assert-string= (string-append "/pfx/src" dbl "/pfx/" mt sp "/plain")
                        (libdirs->arg (list (split-pair "/pfx") "/plain")))))

    ;; native 收进所属库:<obj-root>/<lib>/native/<soname>.<ext>
    (native-under-owning-lib
      (assert-string= "obj/sqlite/native"
                      (lib-native-dir "obj" "sqlite"))
      (assert-string= "obj/sqlite/native/sqlite.so"
                      (lib-native-path "obj" "sqlite" "sqlite"))
      (assert-true (native-so? "x/native/foo.so"))
      (assert-false (native-so? "x/foo.ss")))

    (library-name-to-path
      (assert-string= "a/b.ss" (library-name->path '(a b)))
      (assert-string= "http/client.ss" (library-name->path '(http client)))
      (assert-string= "foo.ss" (library-name->path '(foo))))

    (srcdir-join-default
      (assert-string= "lib/http" (srcdir-join "lib/http" "."))
      (assert-string= "lib/http" (srcdir-join "lib/http" ""))
      (assert-string= "lib/http" (srcdir-join "lib/http" #f))
      (assert-string= "lib/http/src" (srcdir-join "lib/http" "src")))))
