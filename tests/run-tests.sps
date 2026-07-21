#!chezscheme
;;; tests/run-tests.sps --- 汇总运行 chandler/test/* 全部 suite
;;;   scheme --libdirs . --program tests/run-tests.sps   (搜索根 = 仓库根)
;;; 非零退出码表失败。新增测试库 → prefix import + 在 all-suites 挂一行。

(import (chezscheme)
        (chandler test harness)
        (prefix (chandler test harness-selftest) self:)
        (prefix (chandler test sexp) sexp:)
        (prefix (chandler test layout) layout:)
        (prefix (chandler test version) version:)
        (prefix (chandler test manifest) manifest:)
        (prefix (chandler test lock) lock:))

(define all-suites
  (list
    (cons 'harness self:suite)
    (cons 'sexp sexp:suite)
    (cons 'layout layout:suite)
    (cons 'version version:suite)
    (cons 'manifest manifest:suite)
    (cons 'lock lock:suite)))

(exit (if (run-suites all-suites) 0 1))
