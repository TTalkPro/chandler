# Skiff —— Chez Scheme + libuv 构建 Node.js 式运行时 · 架构调研

**调研日期**: 2026-07-21
**项目名**: **Skiff**(轻舟)—— 运行时本体。生态配套:包管理器 **Chandler**(读 `manifest.ss`,见 [chez-chandler-git-lib-manager-design.md](chez-chandler-git-lib-manager-design.md))、构建工具 **bake**(读 `recipe.ss`,见 [chez-bake-build-tool-design.md](chez-bake-build-tool-design.md))。
**结论**: **可行,且有生产级参考(Swish)。核心是「续延调度器 + 单线程 libuv loop + 控制反转的完成队列」**

---

## 核心结论

用 Chez Scheme + libuv 做一个「Node.js 式运行时」是可行的,而且不必从零摸索——
**`becls/swish` 已经把底座(Chez + libuv + continuation)在产线上跑通了**,只是它上层暴露的是
Erlang/OTP 的 actor 模型,而非 Node 的 event-loop + async/await。底座可直接复用/借鉴。

四条定架构的决定:

| 决定 | 选择 | 理由 |
|------|------|------|
| 异步模型 | **delimited continuation**(shift/reset / `call-with-prompt`),而非 callback | Chez 有一等续延,可做「同步写法、异步执行」,天生比 JS 优雅 |
| 宿主归属 | **Chez 当 main + FFI 调 libuv**,不用 C++ 内嵌 | 迭代快、单语言核心;C++ 内嵌并不能省掉 FFI 层 |
| C 代码形状 | **库形状**(编成 `.so` 被 FFI),而非宿主形状 | libuv/解析器/TLS 都是库;只有 loop/调度器/stream 该是 Scheme |
| 线程模型 | **可单线程到底**(Swish 路线),或线程版 + `fork-thread` 做 worker | 单线程更简单,绕开 GC/线程 activation;并行需求另开子进程/线程 |

---

## 1. 异步模型:别复刻 callback,直接上 continuation

Node 被迫 callback → Promise → async/await 三层演进,是因为早期 JS 没有可捕获的续延。
Chez 有 `call/cc` + `dynamic-wind`,可从第一天做成同步写法:

```scheme
(define (handler req)
  (let ([data (await (fs-read "foo.txt"))])   ; await 挂起当前续延
    (send-response req data)))
```

`await` = 捕获当前续延 → 存进 libuv 请求的 callback → 交还控制权给 loop → 完成时 resume。

**强烈建议用 delimited continuation(shift/reset、`call-with-prompt`/`abort-current-continuation`)
而非裸 `call/cc`**:
- 裸 `call/cc` 捕获整个栈,有 I/O 副作用时 resume 语义易错;
- delimited 版每个 task 是一个 prompt 边界,天然对应一个任务,取消/超时/错误传播都好做。

## 2. 宿主归属:Chez 当 main + FFI,不要 C++ 内嵌

C++ 内嵌 Chez(`Sscheme_init` 启动 + C++ 驱动 loop)看似可控,实则亏:

1. **并不能省掉 FFI 层**——libuv 回调要 resume Scheme 续延,谁当宿主都得写互操作层;
   内嵌 = C 互操作层 + C++ 构建系统,两个世界的缺点相加。
2. **迭代速度差一个数量级**——Chez 当主进程是脚本/REPL 模式,改一行就跑;C++ 宿主每次重编译链接。
3. **语言分裂**——核心逻辑(调度器、stream、模块 resolver)本就该 Scheme 写。

**内嵌只在两种情况值得**:
- 塞进已有的 C++ 大程序当脚本引擎 / 必须由 C 掌控进程生命周期;
- **单文件打包**(见 §6)——但那是收尾一步,不是开局决策。

## 3. 「有多少 C」不是分歧点,「谁拥有 main/loop/调度器」才是

C 代码再多,只要都是**库形状**(编成 `.so` 被调用),Scheme 当 main 就没问题。

| 东西 | 形状 | 归属 |
|------|------|------|
| libuv | 库 | `.so`,FFI |
| llhttp / WebSocket 解析器 | 库 | `.so` FFI(或直接 Scheme)|
| TLS(OpenSSL) | 库 | `.so`,FFI |
| 工作池任务 | 库(C work fn) | libuv 内部或你的 `.so` |
| **事件循环驱动** | **宿主** | **Scheme** |
| **续延调度器** | **宿主** | **Scheme** |
| **stream / 背压 / 模块系统** | **宿主** | **Scheme** |

### 澄清两个常见误解

- **「FFI 用不了 libuv 工作池」——不成立。** 工作池上跑的是 C 函数不是 Scheme。
  `uv_fs_*`/`uv_getaddrinfo`/`uv_random` 的 work fn 是 libuv 内部 C 实现,FFI 调 `uv_fs_read`
  阻塞的 `pread` 就已在池线程上跑,你天然白嫖到工作池。Node 也这么用。
  CPU 密集的自定义计算**不该**塞 libuv 池(Node 也不把 JS 放上去,走 `worker_threads`),
  你的对应做法是 `fork-thread` 开独立 Chez 线程。
- **「C++ 能直接实现 HTTP/WebSocket 解析」——真,但那是库不是宿主。** 解析是纯字节状态机,
  和 loop、和谁当宿主正交。**Node 的 `ws` 库是纯 JS 写的**;HTTP 用的 `llhttp` 是独立单文件 C 库。
  想用 C 写解析器 → 编成 `.so` FFI 进来,不需要 Chez 被 C++ 托管。

## 4. 参考项目:Swish(becls/swish)

Beckman Coulter 开源的 **Erlang 风格并发框架,建在 Chez + libuv 上**,用于医疗/实验室仪器产线。

- 定位:**「Erlang-on-Chez」**;你要做的是「Node-on-Chez」——**同底座,不同并发表面**。
- 轻量进程用 continuation/engine 实现;actor:`send`/`receive` 邮箱、监督树、gen-server(照搬 OTP)。
- I/O 边界叫 **OSI 层(Operating System Interface)**,封装 libuv——就是你要写的 shim 的成熟范本。
- 附带:Web server、SQLite3、日志/事件系统。
- 构建:Chez 10.3+、C 编译器、GNU make 4.4+、cmake。
- **要求非线程版 Chez**:`Swish does not support threaded Chez Scheme builds.`

## 5. Swish OSI/libuv 集成剖析(重点,可直接借鉴)

### 题眼:控制反转

Node 是 **C++ 主动回调进 JS**。**Swish 反过来:Scheme 当调度器,主动「步进」libuv 一个时间片,
再排干完成队列**:

```
Scheme 调度器循环:
  1. osi_get_callbacks(timeout)  ──► C 侧跑 uv_run 一个 quantum
  2. libuv 完成的操作 ──► 各自 C 回调把 (callback . args) 塞进全局队列
  3. quantum 到点 uv_stop,osi_get_callbacks 返回整条队列给 Scheme
  4. Scheme 逐个 dispatch,resume 对应绿色进程/续延
  5. 回到 1
```

这就是**非线程 Chez 还能干净跑异步的原因**:libuv 的 C 回调**从不直接跳进 Scheme**,
只往队列 append 一个指针对;进入 Scheme 永远发生在主线程、由调度器掌控的时刻。
GC、续延、线程 activation 的麻烦一次性消掉。

### C 侧(osi.c)四件套

```c
// ① 每个异步请求 = libuv req 结构体 + 内嵌 Scheme 指针
typedef struct {
  uv_fs_t fs;        // libuv 请求本体放第一个字段
  ptr buffer;        // Scheme bytevector
  ptr callback;      // Scheme 回调闭包
} rw_fs_req_t;

// ② 提交:Slock_object 锁住 Scheme 对象防 GC,发给 libuv
static ptr read_fs_port(uptr port, ptr buffer, size_t start_index,
                        uint32_t size, int64_t offset, ptr callback) {
  rw_fs_req_t* req = malloc_container(rw_fs_req_t);
  Slock_object(buffer);      // ★ 异步期间不能被 GC 移动/回收
  Slock_object(callback);
  req->buffer = buffer;
  req->callback = callback;
  uv_buf_t buf = {.base = (char*)&Sbytevector_u8_ref(...), .len = size};
  uv_fs_read(osi_loop, &req->fs, p->file, &buf, 1, offset, rw_fs_cb);
  return Strue;
}

// ③ 完成回调:不进 Scheme,只解锁 + 入队
static void rw_fs_cb(uv_fs_t* req) {
  rw_fs_req_t* fs_req = container_of(req, rw_fs_req_t, fs);  // 从 libuv req 反推 wrapper
  ptr callback = fs_req->callback;
  uv_fs_req_cleanup(req);
  Sunlock_object(fs_req->buffer);
  Sunlock_object(callback);
  free(fs_req);
  osi_add_callback1(callback, Sinteger(req->result));   // ★ 只 append,不调用 Scheme
}

// ④ 队列排干 + 时间片(loop 的心脏)
static void get_callbacks_timer_cb(uv_timer_t* handle) { uv_stop(handle->loop); }

ptr osi_get_callbacks(uint64_t timeout) {
  if (0 == timeout)
    uv_run(osi_loop, UV_RUN_NOWAIT);          // 非阻塞:有啥收啥
  else {
    uv_timer_start(&g_timer, get_callbacks_timer_cb, timeout, 0);
    uv_run(osi_loop, UV_RUN_ONCE);            // 阻塞到有事件或超时
  }
  // 返回这一轮攒下的 callback 队列给 Scheme
}
```

### Scheme 侧(osi.ss)

```scheme
(define _init_ ((foreign-procedure "osi_init" () void)))

;; define-osi 宏:一次生成 unsafe(name*)+ safe(name)两个绑定
;; safe 版检测错误对 (错误符号 . errno) 并抛异常
(define (name arg ...)
  (let ([x (name* arg ...)])
    (if (not (and (pair? x) (symbol? (car x))))
        x
        (throw `#(osi-error name ,(car x) ,(cdr x))))))

;; 实际绑定:回调就是一个 ptr 参数(Scheme 闭包作为不透明指针交给 C)
(define-osi osi_read_port
  (port uptr) (buffer ptr) (start-index size_t)
  (size unsigned-32) (offset integer-64) (callback ptr))
(define-osi osi_connect_tcp (node string) (service string) (callback ptr))
(fdefine osi_get_hrtime unsigned-64)
```

注意:回调类型是 `ptr` 而非 `foreign-callable`。**只要走「C 入队、Scheme 取」模型,
C 就不主动回调 Scheme,`lock-object` 心智负担和线程 activation 全免。**

### 可复用结论

1. **偷这个控制反转模型**:`osi_get_callbacks(timeout)` + 完成队列 + Scheme 主循环 dispatch。
   你的 async/await 只是在 dispatch 那步 resume delimited continuation,而非 Swish 的绿色进程。
2. **每请求 wrapper + `container_of` + `Slock/Sunlock` 三件套**是所有 libuv 绑定的模板。
3. **`define-osi` 那个宏值得照抄**:统一生成安全/不安全绑定 + 错误对约定。
4. **回调传 `ptr` 而非 `foreign-callable`**。

## 6. 分层架构与落地顺序

```
┌─────────────────────────────────────────────┐
│  用户代码 (Scheme,同步写法 + await)            │
├─────────────────────────────────────────────┤
│  运行时核心 (Scheme):调度器/stream/module       │  ← 90% 的代码
├─────────────────────────────────────────────┤
│  FFI 绑定层 (Scheme):foreign-procedure/ftype    │
├─────────────────────────────────────────────┤
│  薄 C shim (OSI 层):尺寸/偏移查询、完成队列、      │
│    Slock/Sunlock 胶水                          │
├─────────────────────────────────────────────┤
│         libuv / llhttp / OpenSSL (.so)         │
└─────────────────────────────────────────────┘
```

**最小可用闭环落地顺序**(走 Node 当年的路径):

1. `uv_timer` — 最简单,验证 loop + quantum + 续延调度(≈ `setTimeout`)。
2. `uv_tcp` + `uv_read_start`/`uv_write` — 验证流和**背压**(stream 核心难点)。
3. `uv_fs_*` — 文件 I/O,验证工作池路径。
4. HTTP 层 — **别自己写解析器**,FFI 绑 `llhttp`(Node 同款,单文件)或 `picohttpparser`。

**具体决策建议**:

| 问题 | 推荐 | 理由 |
|------|------|------|
| 错误处理 | Scheme `guard`/condition,在 prompt 边界 catch | 比 JS try/catch + unhandledRejection 干净 |
| 模块系统 | 别硬套 Chez library,做 Node 式 runtime resolver | Chez library 是编译期的,和运行时 `require` 冲突 |
| 定时器结构 | 直接用 libuv 的 timer heap | libuv 已调好 |
| Buffer | 用 bytevector,UTF-8 转换用 Chez 内建 | 避免自管 C 内存 |
| C shim 语言 | **C 不是 C++** | libuv/Chez FFI 都是 C ABI;C++ 的 name mangling/异常/ABI 徒增摩擦 |
| 单文件打包 | 收尾时套 C `main` 引导 boot image + 静态链 | 开发期 Scheme 驱动,打包期才需要 C main |

---

## 参考资料

- Swish 仓库:https://github.com/becls/swish · Windows 版:https://github.com/becls/swish-win
- 关键源码:`src/swish/osi.c`、`osi.ss`、`osi.h`、`io.ss`、`io-constants.c`
- Swish 手册(含 OSI 章):https://becls.github.io/swish/swish.pdf
- libuv 官方 book(uvbook):https://docs.libuv.org
- Guile `fibers`:delimited continuation + epoll 做协程调度的现成思路参考
- Chez FFI 重点:`foreign-procedure`、`foreign-callable`、`lock-object`/`unlock-object`、`ftype`、
  `Sactivate_thread`/`Sdeactivate_thread`(仅线程版跨线程回 Scheme 时需要)

## 相关文档

- `chez-async-http-analysis.md` — Chez 异步 HTTP 分析
- `chez-async-websocket-difficulty.md` — WebSocket 难点
- `chez-compile-and-distribute.md` — 编译与分发(单文件打包相关)
- `ffi/` — Chez FFI 专题
