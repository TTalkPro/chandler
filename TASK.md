# Chandler v2 实施任务

> 设计文档见 [designs/](designs/),核心模型见 [designs/00-design-principles.md](designs/00-design-principles.md)。

## 完成状态

### Phase 1 — pack 重构闭环 ✅ 全部完成

| Milestone | 状态 | 关键 commit |
|-----------|------|------------|
| v2.0 数据层 | ✅ | `37db998` `737c111` `a228b8c` |
| v2.1 install nested | ✅ | `d579cdc` |
| v2.2 launcher libdirs | ✅ | `b7a864f` |
| v2.3 pack nested | ✅ | `2051200` `58b758b` `6db94dc` |

### Phase 2 — 已完成部分

| Milestone | 状态 | 关键 commit |
|-----------|------|------------|
| v2.1-global(install/list/doctor/uninstall) | ✅ | `74e2b42` |
| v2.5 lib pack(--lib) | ✅ | `b693bb0` |
| 去 --global + 路径调整 | ✅ | `bf0a987` |
| APP_ROOT 去除(D8) | ✅ | `4f1b8e3` |
| manifest.ss → chandler-manifest.ss | ✅ | `1bd34a1` |

### 备选(暂缓)

| Milestone | 说明 |
|-----------|------|
| v2.4 prebuilt 远程分发 | HTTP 下载 + sha256 + mt-gate(schema 已定义,实现暂缓) |

## 决策记录

| # | 决策 | 状态 |
|---|------|------|
| D1 | `.chandler/` 进 version 目录 | ✅ |
| D2 | pack = install --prefix + envelope | ✅ |
| D3 | lib 可 pack | ✅ |
| D4 | `(chandler setup)` Bundler 模型 | ❌ 取消(Chez import 编译时,改用 launcher --libdirs) |
| D5 | pack bundle chandler-runtime | ✅ |
| D6 | mt 嵌套(`<version>/<mt>/`) | ✅ |
| D7 | 不考虑老版本兼容 | ✅ |
| D8 | 去除 APP_ROOT | ✅ |
| D9 | dev app/dep 对称(`<dir>/` + `<dir>/_build/<mt>/`) | ✅ |
| D10 | 去掉 srcdir | ✅ |
| D11 | 去 --global,用 --user(默认)/--system/--prefix | ✅ |
| D12 | prebuilt 远程分发暂缓 | ⏸️ 备选 |

## 已验证的端到端流程

```
chandler deps → chandler build → chandler install --prefix=<dir>
  → chandler list → chandler doctor → chandler uninstall

chandler pack → 解包 → 运行("Hello from packed app!")
chandler pack --lib → 无 envelope nested payload
```

## 测试

357 passed, 0 failed(363 - 6 removed APP_ROOT/app-name tests)。
