#!chezscheme
;;; recipe.ss --- bake 构建描述(由【另一仓库】的 bake 消费)
;;;
;;; bake 在独立仓库实现;本文件描述如何编译/安装 Chandler。开发期用解释执行即可,
;;; 无需 bake 也完全可用(见 designs/08 §1 形态表):
;;;   scheme --libdirs . --program tests/run-tests.sps   # 跑测试(110+ 用例)
;;;   ./bin/chandler --version                           # 入口(解释执行)
;;;   ./install.sh                                        # 自举安装到用户级 libdir
;;;
;;; 预期最终形态(示意,以 bake 仓库的 DSL 权威为准):
;;;
;;;   (default-task 'build)
;;;
;;;   ;; 编译 umbrella + 子库树为 .so(bake compile-tree,布局规范即隐式构建描述)
;;;   (task 'build '(compile-libs)
;;;     (lambda () (compile-tree "." "build")))
;;;
;;;   (task 'test '(build)
;;;     (lambda () (run "scheme" "--libdirs" "." "--program" "tests/run-tests.sps")))
;;;
;;;   ;; 安装:复用 (chandler registry) 事务装进用户级 libdir + bin/chandler
;;;   (task 'install '(build)
;;;     (lambda () (run "./install.sh")))
;;;
;;;   ;; 自举本工具为快启动镜像(可选,见 designs/08 §1)
;;;   (task 'boot '(build)
;;;     (lambda () (make-boot-file "chandler.boot" '("petite" "scheme")
;;;                                "chandler.ss" "chandler/cli/main.sps")))
;;;
;;; Chandler 自身零外部依赖(只用 (chezscheme)),故无 manifest deps 需 chandler 供货。
