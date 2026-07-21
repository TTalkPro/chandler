#!chezscheme
;;; chandler/cli/main.sps --- 程序入口:取命令行参数,调 (chandler cli main)

(import (chezscheme) (chandler cli main))

;; (command-line) = (程序名 参数…);去掉程序名
(exit (main (cdr (command-line))))
