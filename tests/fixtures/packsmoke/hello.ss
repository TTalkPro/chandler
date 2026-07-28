#!chezscheme
;;; 见同目录 chandler-manifest.ss。
(library (hello)
  (export main)
  (import (chezscheme))
  (define (main args) (display "hello from pack") (newline) 0))
