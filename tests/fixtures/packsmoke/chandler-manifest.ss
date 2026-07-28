;;; pack 冒烟夹具(.github/workflows/windows.yml 第 ③ 步)。
;;; 刻意**不写 (chandler ">=…") 运行时门** —— 那要求先把 chandler 自身 vendor 进
;;; _vendor/,与本夹具要验的「pack 出来的东西能不能跑」无关,徒增一层。
(manifest
  (format 1)
  (name "hello")
  (version "0.1.0")
  (srcdir ".")
  (deps)
  (app (entry (hello)) (main main)))
