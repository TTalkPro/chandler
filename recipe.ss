#!chezscheme
;;; recipe.ss --- bake 构建/安装描述(生态闭环:skiff 跑 · chandler 管依赖 · bake 装库)
;;;
;;; 有了本文件,chandler 可直接被 bake 构建与安装,补上整个体系的最后一环:
;;;   • skiff  —— 运行时,跑上面所有工具
;;;   • chandler —— 包管理器,拉取/激活依赖
;;;   • bake   —— 构建工具,编译库树、装进 Chez lib dir(本 recipe 消费方)
;;; 且 bake 自身依赖 (chandler lock/registry/layout/sexp/util/fs),故「bake 装 chandler 库」
;;; 正是闭环所在。
;;;
;;;   bake            # = bake build,编译 (chandler) 库树为 .so
;;;   bake test       # 跑全测试套件(130 用例)
;;;   bake install    # 装 (chandler) 库树 → ~/.local/share/chez/lib(--global 装 /usr/local)
;;;   bake uninstall  # 据安装清单干净卸载
;;;   bake -T         # 列任务

(define-lib-roots ".")                       ; 库搜索根 = 仓库根(布局规范:umbrella 在根)

;; ── build(默认):编译 (chandler) umbrella + 其 import 闭包为 .so ──
(library-task 'build '(chandler))

;; ── test:跑测试套件(解释执行,无需先编译)──
;;   (build/install/uninstall 是 bake 的 tool-task,不带描述,故不列入 `bake -T`,但可直接调用。)
(task 'test "跑全测试套件(130 用例)"
  '()
  (lambda ()
    (run "scheme" "--libdirs" "." "--program" "tests/run-tests.sps")))

;; ── install / uninstall:把 (chandler) 库树装进 Chez lib dir ──
;;   → (import (chandler …)) 全局可解析(apps 的 (activate) 与 bake 自身都需要)。
;;   chandler 的自安装(install.sh / install-self)即委托这些任务装库,再补一个
;;   运行时发现启动器(bin/chandler);故 chandler「自安装基于 bake install」。
;;   user → ~/.local/share/chez/lib;global → /usr/local/share/chez/lib(需 root)。
(install-task 'install
  (lib chandler)
  (from ".")
  (target user))
(uninstall-task 'uninstall
  (lib chandler)
  (target user))

(install-task 'install-global
  (lib chandler)
  (from ".")
  (target global))
(uninstall-task 'uninstall-global
  (lib chandler)
  (target global))

(default-task 'build)
