# Godot 日志与报错检测

> 本文档说明 stick_world 的 Godot 报错从哪来、落在哪、如何自动检测。
> 检测脚本：`tools/check_godot_errors.ps1`（核心行为指令要求代码修改后运行）。

---

## 一、两类报错及其来源

### 1. 编辑器启动报错（编辑器进程输出）

**触发场景**：启动 Godot 编辑器 / 编辑器内资源重扫描 / 打开项目时。

**典型内容**：

- `Parse Error: Expected '['` —— `.tscn`/`.tres` 文本格式问题（**最常见根因：文件带 UTF-8 BOM**；Godot 4.x 编辑器对 BOM 报错，headless 运行测试时却被容忍，所以测试全绿但编辑器报错）
- 插件 / GDExtension 加载失败（如 `godot-sqlite` 缺 dll：`Error loading extension: 'res://addons/godot-sqlite/gdsqlite.gdextension'`）
- 编辑器工具脚本（@tool / MapEditor 插件）的运行时错误
- 语言服务器消息（`Debug adapter server started on port 6006` / `GDScript language server started on port 6005`）——**正常信息**，不是错误

**落盘位置**：编辑器进程的 stdout/stderr 写入 `user://logs/godot.log`；每次编辑器启动把旧日志轮转为 `godot<时间戳>.log`。

### 2. 运行程序报错（调试器/游戏进程输出）

**触发场景**：编辑器内 F5 运行 / headless 命令行运行 / 自动化测试。

**典型内容**：

- `SCRIPT ERROR` —— 脚本运行时错误（类型不匹配、无效访问、nil 调用），含 GDScript backtrace 与 `文件:行号`
- `Invalid call / Invalid access to property or key` —— 属性/方法访问错误（如本文档项目里曾出现的 `get_child_orgs` 返回类型崩溃、`from_dict` typed Array 赋值崩溃）
- `push_error()` / `push_warning()` 主动上报
- WARNING 行（非致命，但应关注，如 `safe_emit` 参数超限）

**落盘位置**：从编辑器运行时，游戏进程输出被编辑器捕获并**追加到同一 `godot.log`**；headless 运行时直接输出到 stdout/stderr。

---

## 二、日志文件位置与轮转

```
%APPDATA%\Godot\app_userdata\stick_world\logs\
├── godot.log                  # 最近一次运行的完整日志
├── godot<时间戳>.log          # 每次启动时轮转的旧日志（保留最近若干次）
```

`godot.log` 是**增量真相**：最新错误优先看它；被轮转覆盖的报错去时间戳文件找（如编辑器刚启动就报错而你没看到，错误就在最新的时间戳文件里）。

---

## 三、自动检测

> 默认终端为 **bash**。检测脚本为 `.ps1`，从 bash 中经 `powershell` 调用（路径用 `/` 分隔）。

```bash
# 标准检查（默认 = 日志扫描 + 编辑器启动模拟）：有错退出码 1
powershell -ExecutionPolicy Bypass -File tools/check_godot_errors.ps1

# 只查日志（跳过 ~15s 的启动模拟）
powershell -ExecutionPolicy Bypass -File tools/check_godot_errors.ps1 -Quick

# 连 WARNING 一起看（改代码后建议带 -Warnings）
powershell -ExecutionPolicy Bypass -File tools/check_godot_errors.ps1 -Warnings

# 只看最近 N 条错误摘要
powershell -ExecutionPolicy Bypass -File tools/check_godot_errors.ps1 -Head 10
```

### 检测原理（2026-08 实验验证）

**为什么不能只靠日志 / 无头测试？**

| 检测方式 | 覆盖 | 局限 |
|---|---|---|
| 读 `logs/godot.log` | 最近一次运行的错误 | 会被后续运行轮转覆盖（保留最近若干次）；编辑器没再启动就没有新日志 |
| `godot --headless --import` | 全量资源导入解析 | **有缓存跳过**：只解析"首次/变更"文件，重复跑不报 |
| `godot --headless --editor --quit` | 完整编辑器启动（扫描/全局类名/GDExtension/插件/资源解析） | 同样受缓存影响：失败状态会被 `.godot` 缓存记住，第二次跑不报 |
| 普通无头测试（run_all） | 测试加载到的代码路径 | **资源解析严格度不同**：普通运行路径容忍 UTF-8 BOM，编辑器启动路径严格报 Parse Error；且只加载测试场景 |

**编辑器启动报错的标准复现**（已实验验证，~15s）：

```
删除 .godot/editor/filesystem_cache10（文件变更缓存，删除 = 强制全量重扫）
→ godot --headless --editor --quit
→ 输出中的 ERROR / Parse Error 即编辑器启动会报的错误
```

实验记录：带 BOM 的 tscn → 普通测试 9/9 通过（容忍）；`--editor --quit` 首次报 `Parse Error: Expected '['`（与 GUI 编辑器一致）；**删 filesystem_cache10 后每次都稳定报出**。

**约定**（写进 AGENTS.md 核心行为指令）：

1. 任何代码修改后运行标准检查（默认含启动模拟），退出码 1 必须修复后再继续
2. 用户报告编辑器报错时，先跑 `check_godot_errors.ps1`（启动模拟会强制重扫全部资源），再查 `logs/` 最新日志定位
3. headless 测试（`tests/run_all.ps1`）只看断言结果，**不覆盖**编辑器资源解析类错误（BOM Parse Error 就是例子）——两者都要查
4. 注意：`--editor --quit` 会重建 `filesystem_cache10`，首次耗时 ~15s；对项目无其他副作用（不写存档、不改源文件）

---

## 四、已知历史案例

| 报错 | 根因 | 修复 |
|------|------|------|
| 编辑器 `Parse Error: Expected '['`（8 个测试 tscn/gd） | 文件带 UTF-8 BOM（对方 AI 编辑器保存引入）；headless 测试容忍 BOM 故全绿 | 去除 BOM（2026-08-05） |
| `get_child_orgs` 返回类型崩溃 | 无类型 Array 赋给 `Array[String]` 返回值 | 显式构造类型化数组 |
| `from_dict` 系列 typed Array 赋值崩溃 | `duplicate()` 返回无类型 Array 赋给 typed Array 字段 | 改用 `.assign()` |
