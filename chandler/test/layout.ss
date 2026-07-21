#!chezscheme
;;; chandler/test/layout.ss --- (chandler layout) 测试

(library (chandler test layout)
  (export suite)
  (import (chezscheme)
          (chandler test harness)
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

    (native-dir-and-path
      (assert-string= (string-append "lib/sqlite/native/" (current-machine-type))
                      (native-dir "lib/sqlite"))
      (assert-string= (string-append "lib/sqlite/native/" (current-machine-type) "/sqlite.so")
                      (native-path "lib/sqlite" "sqlite")))

    (library-name-to-path
      (assert-string= "a/b.ss" (library-name->path '(a b)))
      (assert-string= "http/client.ss" (library-name->path '(http client)))
      (assert-string= "foo.ss" (library-name->path '(foo))))

    (srcdir-join-default
      (assert-string= "lib/http" (srcdir-join "lib/http" "."))
      (assert-string= "lib/http" (srcdir-join "lib/http" ""))
      (assert-string= "lib/http" (srcdir-join "lib/http" #f))
      (assert-string= "lib/http/src" (srcdir-join "lib/http" "src")))

    (lib-root-compose
      (assert-string= "proj/lib/http" (lib-root "proj" "http" "."))
      (assert-string= "proj/lib/http/src" (lib-root "proj" "http" "src")))))
