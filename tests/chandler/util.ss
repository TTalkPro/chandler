#!chezscheme
;;; tests/chandler/util.ss --- (chandler util) 测试

(library (tests chandler util)
  (export suite)
  (import (chezscheme)
          (tests chandler harness)
          (chandler util))

  (define-suite suite
    (split-char
      (assert-equal '("a" "b" "c") (string-split "a/b/c" #\/))
      (assert-equal '("" "a" "") (string-split "/a/" #\/))
      (assert-equal '("solo") (string-split "solo" #\/)))

    (split-charset
      (assert-equal '("a" "b" "c") (string-split "a b\tc" '(#\space #\tab))))

    (split-lines-fn
      (assert-equal '("x" "y" "") (split-lines "x\ny\n")))

    (trim
      (assert-string= "hi" (string-trim "  hi \n"))
      (assert-string= "" (string-trim "   "))
      (assert-string= "a b" (string-trim "\ta b\r")))

    (prefix-suffix
      (assert-true (string-prefix? "foo" "foobar"))
      (assert-false (string-prefix? "bar" "foobar"))
      (assert-true (string-suffix? "bar" "foobar"))
      (assert-false (string-suffix? "foo" "foobar")))

    (strip
      (assert-string= "bar" (strip-prefix "foobar" "foo"))
      (assert-string= "foobar" (strip-prefix "foobar" "xyz"))
      (assert-string= "foo" (strip-suffix "foobar" "bar"))
      (assert-string= ".git" (strip-suffix ".git" "xyz")))

    (search-contains
      (assert-equal 3 (string-search "abcdef" "def"))
      (assert-equal 0 (string-search "abc" "abc"))
      (assert-equal #f (string-search "abc" "xyz"))
      (assert-true (string-contains? "hello world" "o w"))
      (assert-false (string-contains? "hello" "z")))

    (char-index-fn
      (assert-equal 2 (char-index "a.b" #\b))
      (assert-equal 4 (char-index "a.b.c" #\c))
      (assert-equal #f (char-index "abc" #\z))
      ;; 带 start:从下标 2 起找 /,命中下标 3
      (assert-equal 3 (char-index "a/b/c" #\/ 2)))

    (join
      (assert-string= "a:b:c" (string-join '("a" "b" "c") ":"))
      (assert-string= "solo" (string-join '("solo") ":"))
      (assert-string= "" (string-join '() ":")))

    (alist
      (assert-equal 1 (alist-ref '((a . 1) (b . 2)) 'a))
      (assert-equal #f (alist-ref '((a . 1)) 'z))
      (assert-equal 'dflt (alist-ref '() 'z 'dflt)))

    (ignore-errors-macro
      (assert-equal #f (ignore-errors (error 'x "boom")))
      (assert-equal #f (ignore-errors (car '())))
      (assert-equal 42 (ignore-errors 42))
      (assert-equal 3 (ignore-errors (+ 1 2))))))
