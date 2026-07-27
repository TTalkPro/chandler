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
  ;; 遍历本身在 (chandler layout) 的 walk-native-dirs —— 与 install 的 native 预载
  ;; 共用同一份「native 落点」定义。
  (define (native-libs-under base)
    (let ([out '()])
      (walk-native-dirs base (lambda (segs nd) (set! out (cons segs out))))
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
