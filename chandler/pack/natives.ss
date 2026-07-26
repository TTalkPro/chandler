#!chezscheme
;;; chandler/pack/natives.ss --- native 库清点(原 pack.ss §4)
;;;
;;; lock 给**期望集**(精确,缺项能指出是哪个依赖);组装后的树给**实际集**(完整,
;;; 连应用自己经 bake native-task 产出的那些也在内)。前者用于前置校验,后者用于
;;; 写清单 —— 两者各司其职,不能相互替代。

(library (chandler pack natives)
  (export native-libs-under native-files-in missing-dep-natives)
  (import (chezscheme)
          (chandler fs)
          (chandler layout)
          (chandler lock))

  ;; 对象树里每个带 native/ 的库,返回其名字段列表(("mylib") / ("chez" "async"))。
  ;; **递归** —— 多段库名的 native 落在 lib/<mt>/chez/async/native/,一层扫描会漏掉。
  (define (native-libs-under base)
    (let ([out '()])
      (let walk ([rel '()])
        (let ([dir (fold-left join-paths base (reverse rel))])
          (when (file-directory? dir)
            (for-each
              (lambda (e)
                (let ([p (join-paths dir e)])
                  (when (file-directory? p)
                    (if (string=? e "native")
                        (unless (null? rel) (set! out (cons (reverse rel) out)))
                        (walk (cons e rel))))))
              (list-sort string<? (dir-entries dir))))))
      (reverse out)))

  (define (native-files-in dir)
    (list-sort string<?
      (filter (lambda (f) (not (file-directory? (join-paths dir f)))) (dir-entries dir))))

  ;; lock 声明的 native 是否都在 lib/<mt>/ 里(前置校验)
  (define (missing-dep-natives obj-dir locked)
    (let ([miss '()])
      (for-each
        (lambda (d)
          (let ([name (symbol->string (locked-dep-name d))])
            (for-each
              (lambda (n)
                (let* ([soname (if (pair? n) (symbol->string (car n)) (symbol->string n))]
                       [p (lib-native-path obj-dir name soname)])
                  (unless (file-exists? p)
                    (set! miss (cons (string-append name ": " p) miss)))))
              (locked-dep-natives d))))
        locked)
      (reverse miss)))
  )
