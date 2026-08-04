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

```powershell
# 标准检查（ERROR / SCRIPT ERROR / Parse Error / Invalid call...），有错退出码 1
powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1

# 连 WARNING 一起看（改代码后建议带 -Warnings）
powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -Warnings

# 只看最近 N 条错误摘要（大日志快速定位）
powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -Head 10

# 指定日志目录（如排查其他项目）
powershell -ExecutionPolicy Bypass -File tools\check_godot_errors.ps1 -LogDir "C:\path\to\logs"
```

**约定**（写进 AGENTS.md 核心行为指令）：

1. 任何代码修改后运行标准检查，退出码 1 必须修复后再继续
2. 用户报告编辑器报错时，先查 `logs/` 最新日志（含轮转文件）定位根因
3. headless 测试（`tests/run_all.ps1`）只看断言结果，**不覆盖**编辑器资源解析类错误（BOM Parse Error 就是例子）——两者都要查

---

## 四、已知历史案例

| 报错 | 根因 | 修复 |
|------|------|------|
| 编辑器 `Parse Error: Expected '['`（8 个测试 tscn/gd） | 文件带 UTF-8 BOM（对方 AI 编辑器保存引入）；headless 测试容忍 BOM 故全绿 | 去除 BOM（2026-08-05） |
| `get_child_orgs` 返回类型崩溃 | 无类型 Array 赋给 `Array[String]` 返回值 | 显式构造类型化数组 |
| `from_dict` 系列 typed Array 赋值崩溃 | `duplicate()` 返回无类型 Array 赋给 typed Array 字段 | 改用 `.assign()` |
