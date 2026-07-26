#!chezscheme
;;; chandler-tasks.ss --- chandler 自己的构建/任务描述(自举)
;;;
;;; 本文件是**程序**(task/file/rule/default-task,加载即求值),与数据文件
;;; manifest.ss 配对;由 `chandler make`(吸收自 bake 的任务运行器)消费。
;;; 2026-07-24:原名 `recipe.ss`(bake 术语)—— bake 全吸收进 chandler 后改此名。
;;;
;;;   chandler make            # = build,编译 (chandler) 库树为 .so → _build/<mt>/
;;;   chandler test            # 跑全测试套件(顶层命令,挂全运行时环境;v3 起取代 make test)
;;;   chandler make -T         # 列任务
;;;
;;; **为什么 chandler 自己还留着这个文件**:多数项目不需要它(`chandler build`
;;; 从 manifest 推导构建);chandler 留着,只是惯例示范 —— build 段本身其实也能
;;; 从 manifest 推出来。跑测试统一走 `chandler test`(库搜索 + native + .env +
;;; .env.tests 全挂);不再默认提供 `make test` / `make test-ps` 任务(需要时
;;; 自行在本文件里 (task 'test ...) 即可)。PowerShell 启动器验收直接跑
;;; `bash tests/powershell-run.sh`。
;;;
;;; **安装不在这里**:chandler 的安装由自含的 `bootstrap.ss` 负责(拷源码 →
;;; <prefix>/src/、拷 _build/<mt>/ → <prefix>/<mt>/,并写运行时发现启动器)。
;;; 故顺序是先 `chandler make` 编译,再 `scheme --script bootstrap.ss [--force]`
;;; —— 否则装进前缀的是上一轮的旧对象。

(define-lib-roots ".")                       ; 库搜索根 = 仓库根(布局规范:umbrella 在根)

;; ── build(默认):编译 (chandler) umbrella + 其 import 闭包为 .so ──
(library-task 'build '(chandler))

(default-task 'build)
