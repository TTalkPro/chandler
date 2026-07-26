#!chezscheme
;;; chandler/pack/paths.ss --- 包内路径常量(原 pack.ss §2)
;;;
;;; FHS 式包内布局(designs/05):载荷走 install 同一管线 → share/chez/;
;;; envelope(运行时 exe / boot / 启动器)在 bin/ 与 lib/chez/。
;;; <mt> 已在包名里(<name>-<ver>-<mt>),bin/boot 下不再嵌 <mt> 层。

(library (chandler pack paths)
  (export pack-dir-name pack-libdir pack-bin-dir pack-boot-dir exe-name)
  (import (chezscheme)
          (chandler layout))

  (define (pack-dir-name name version)
    (string-append name "-" version "-" (current-machine-type)))

  ;; FHS 式包内布局(designs/05):载荷走 install 同一管线 → share/chez/;
  ;; envelope(运行时 exe / boot / 启动器)在 bin/ 与 lib/chez/。
  ;; <mt> 已在包名里(<name>-<ver>-<mt>),bin/boot 下不再嵌 <mt> 层。
  (define (pack-libdir root) (join-paths root "share" "chez"))
  (define (pack-bin-dir  root) (join-paths root "bin"))
  (define (pack-boot-dir root) (join-paths root "lib" "chez"))

  ;; 可执行文件在 Windows 上必须带 .exe —— .ps1 启动器按全名调用,无扩展名跑不起来
  (define (exe-name base) (if (windows-mt? (current-machine-type)) (string-append base ".exe") base))
  )
