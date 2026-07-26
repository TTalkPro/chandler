;;; manifest.ss --- Chandler 自身的 Chandler 清单
;;; 自举目标:Chandler 核心零外部依赖(只用 (chezscheme))。故 deps 为空。

(manifest
  (format 1)
  (name    "chandler")
  (version "0.1.5")
  (chez    ">=10.0")            ; 标准 Chez 即可,不要求 Skiff
  (srcdir  ".")               ; 搜索根 = 仓库根(库布局规范默认)
  ;; chandler 自身也是标准 app:入口库 (chandler cli main),其 main 即 CLI 主函数。
  ;; install 据此生成 run.sps + 稳定 shim 启动器 + registry active 版本。
  (app (entry (chandler cli main)) (main main)))
