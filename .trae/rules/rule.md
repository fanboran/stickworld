---
alwaysApply: true
---

> **说明**：本文件（`rule.md`）是 AI 辅助开发的**主规则文件**。汇集了模块化架构规范、核心行为指令、Git 工作流、项目文档导航。

***

### 输出规范

- 使用中文进行思考、回答问题、写提交信息。
- 所有对文件、代码元素的引用使用可点击链接 `[name](file:///absolute/path)`。
- 不要创建不必要的文件，优先编辑现有文件。

### 项目文档导航

本项目（stick-world）是一个火柴人大战略+工厂自动化缝合怪。游戏设计文档和技术架构位于 `docs/` 目录。任何需要记忆的信息都应该记忆到文档里，但是如果不那么结构化可以直接在对应目录写README.md文件，也可以直接在代码里注释。

**按需自行读取以下文档（不要预加载，只在实现对应模块时读取）**：

| 要做什么            | 读哪个                                                     |
| --------------- | ------------------------------------------------------- |
| 了解游戏整体          | `docs/设计/游戏设计文档.md`                                 |
| 实现某个系统          | `docs/设计/系统/<系统名>.md`                        |
| 查核心实体/状态机       | `docs/技术/架构/核心实体与状态机.md`               |
| 查 EventBus 信号   | `docs/技术/架构/系统交互与EventBus.md`           |
| 查模块 API 规范      | `docs/技术/架构/模块API契约.md`                   |
| 查 Autoload 依赖   | `docs/技术/架构/自动加载依赖.md`              |
| 查战略图（world_map）架构 | `docs/技术/架构/战略图架构.md`（模块重新设计基线） |
| 查程序化产物如何喂给战略图 | `docs/技术/架构/世界地图数据流.md`（生成端 ↔ 消费端契约） |
| 查场景图（卷轴地图）架构 | `docs/技术/架构/场景与战斗架构.md`（modules/world 等） |
| 查数据流与存储方案      | `docs/技术/架构/数据流全景.md` |
| 查程序化世界生成       | `docs/设计/系统/08-程序化世界生成.md` |
| 游戏数据表           | `config/excel/` 目录 + `docs/技术/教程/Excel数据管线.md` |
| 查编辑器工具/插件    | `docs/技术/编辑器工具索引.md`（addons/ + tools/ 全部脚本） |
| 开发规范            | `docs/CONTRIBUTING.md`                                  |
| 有可以参考的开源项目就放到这里 | external/                                               |

> **术语提示**：「战略图」（modules/world_map，鸟瞰多边形领土，玩家不在其中）与「场景图」（modules/world 等，卷轴地图，玩家在其中）是两类不同的地图概念，详见 `docs/技术/架构/世界地图数据流.md` §1。

***

## 核心行为指令

1. **安全第一**：不能直接修改 `/core/` 目录下的文件，有修改需求应该得到授权。
2. **代码即文档**：代码必须清晰、易读，包含必要的注释解释复杂逻辑。
3. **主动沟通**：当任务描述不清晰或与架构原则冲突时，主动提问，不做危险假设。
4. **设计先行**：实现任何模块前，须先用 Read 工具读取对应的设计文档（`docs/design/mechanics/<模块名>.md` ）。如果 GDD 标记了 `[待补充]`，须向用户确认。

***

### Godot 模块化架构 4 大原则

1. **文件夹结构**：严格遵循按功能模块（`/modules/`）和核心系统（`/core/`）划分的结构。按功能组织，不按类型（场景/脚本/素材）。
2. **命名规范**：文件和目录 `snake_case`，节点和类名 `PascalCase`。
3. **耦合原则**：模块间通信优先使用 `core/autoload/event_bus.gd` 的全局事件总线，或通过模块的 `api.gd` 定义信号。不要跨模块 `get_node` 或引用非 API 内部方法。
4. **接口契约**：模块对外交互须通过其根目录下的 `api.gd` 文件。

**解耦核心策略**：

- 优先使用事件总线，而非直接方法调用
- 每个模块只暴露一小组精心设计的公共方法和信号
- 高层模块不直接依赖低层模块，两者依赖抽象接口
- 同一模块所有文件物理上放在同一文件夹

***

### 顶层目录结构

```
/ (res://)
├── core/                  # 核心系统与基础设施（稳定，修改需批准）
├── modules/               # 游戏功能模块（开发最频繁的区域）
├── assets/                # 全局共享资源
├── addons/                # 编辑器插件（项目自带 + 第三方），详见 docs/技术/编辑器工具索引.md
├── prototypes/            # 原型沙盒（不被正式逻辑依赖）
├── tools/                 # 自定义编辑器工具与 CLI 脚本（@tool），详见 docs/技术/编辑器工具索引.md
├── tests/                 # 自动化测试（镜像 core/ 和 modules/ 结构）
└── docs/                  # 项目文档
```

### 核心模块 (`core/`) 结构

```
core/
├── autoload/              # 全局单例
│   ├── event_bus.gd       # 全局事件总线（发布-订阅模式）
│   ├── scene_manager.gd   # 场景加载与视图切换
│   ├── save_manager.gd    # 存档/读档服务
│   └── config_manager.gd  # 游戏配置管理
├── ui_framework/          # UI 基础设施
│   ├── base_screen.gd     # UI 界面基类
│   ├── components/        # 通用 UI 组件
│   └── theme/             # 全局 UI 主题
├── services/              # 抽象服务
│   ├── audio_manager.gd   # 音频管理器
│   ├── analytics/         # 数据分析（预留）
│   └── iap/               # 内购（预留）
└── utils/                 # 通用工具类
```

### 游戏功能模块 (`modules/`) 标准结构

每个模块是一个垂直切片，自包含。以 `player` 为例：

```
modules/player/
├── scenes/                # 模块场景
│   ├── player.tscn
│   └── components/        # 组件化子场景
├── scripts/               # 模块脚本
├── animations/            # 动画资源（按需）
├── assets/                # 模块专属资源（按需）
├── ui/                    # 模块专属 UI（按需）
├── data/                  # 纯数据定义类（按需）
└── api.gd                 # 公共接口契约（关键）
```

命名规范：配置尽量放 `.tres`/`.json` 而非全堆在 `project.godot`。

## Git 分支与工作流规范

### 提交规范

- 中文提交信息
- 格式：`类型(模块): 描述`
- 类型：`feat` / `fix` / `refactor` / `test` / `docs` / `chore`
- 示例：`feat(combat): 实现基础自动战斗单位AI`

### 待办项维护

- 改进待办项记录在 `docs/project/待办事项.md`
- 完成一项立即删除对应条目
- 新增项追加到对应优先级分区

***

## 命令行环境规范

- PowerShell 5 不支持 `&&` 和 `||`，请使用 `;` 分隔命令，或用 `if ($LASTEXITCODE -eq 0)` 做条件判断。
- 不使用 `mkdir -p`、`rm -rf`、`ls -la`、`grep -r` 等 Unix shell 语法；改用 PowerShell 原生命令：`New-Item -ItemType Directory -Force`、`Get-ChildItem`、`Select-String`、`Get-Command`。
- 路径包含空格必须用引号包裹并使用 `&` 调用运算符，例如 `& "F:\SteamLibrary\steamapps\common\Godot Engine\godot.exe" --headless`。
- 始终使用反斜杠 `\` 作为路径分隔符；连接路径优先使用 `Join-Path`。
- `.ps1` 脚本默认被执行策略拦截，**不要主动修改执行策略**；如有需要应向用户说明风险并征得确认。
- 执行当前目录的脚本需要加 `.\` 前缀（如 `.\script.ps1`）。
- 避免使用 `Read-Host`、`Get-Credential`、`Out-GridView`、`$Host.UI.PromptForChoice`、`pause` 等需要人工输入的命令；AI 应在非交互式模式下完成任务。
- Git 命令始终加 `--no-pager` 或设置 `$env:GIT_PAGER = "cat"` 防止挂起。
- PowerShell 中的 `curl` 是 `Invoke-WebRequest` 的别名，不兼容 curl 参数；应直接使用 `Invoke-WebRequest` 或 `Invoke-RestMethod` 并加 `-UseBasicParsing`。
- 删除移动文件尽量调用工具而不是直接操作文件系统，如 `Move-Item`、`Remove-Item` 等。
