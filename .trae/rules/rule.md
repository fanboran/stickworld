---
alwaysApply: true
---

> **说明**：本文件（`rule.md`）是 AI 辅助开发的**主规则文件**。汇集了模块化架构规范、核心行为指令、Git 工作流、项目文档导航。

***

### 注意事项

- 使用中文回答问题。
- Git写中文提交信息，格式：`类型(模块): 描述`，示例：`feat(combat): 实现基础自动战斗单位AI`
- 改进待办项记录在 `docs/project/待办事项.md`
- Godot路径：`F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`

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
| 查场景图（卷轴地图）架构 | `docs/技术/架构/场景与战斗架构.md`（导读，索引各子系统）<br>↳ 宿主: [`场景宿主架构.md`](docs/技术/架构/场景与战斗/场景宿主架构.md)<br>↳ 地图/室内/旅行: [`地图与场景图.md`](docs/技术/架构/场景与战斗/地图与场景图.md)<br>↳ 建筑/定居点: [`建筑与定居点.md`](docs/技术/架构/场景与战斗/建筑与定居点.md)<br>↳ 火柴人AI/战斗: [`战斗与AI.md`](docs/技术/架构/场景与战斗/战斗与AI.md)<br>↳ UI/环境: [`UI与环境.md`](docs/技术/架构/场景与战斗/UI与环境.md)<br>↳ 事件信号: [`EventBus信号契约.md`](docs/技术/架构/场景与战斗/EventBus信号契约.md) |
| 查数据流与存储方案      | `docs/技术/架构/数据流全景.md` |
| 查程序化世界生成       | `docs/设计/系统/08-程序化世界生成.md` |
| 游戏数据表           | `config/excel/` 目录 + `docs/技术/教程/Excel数据管线.md` |
| 查编辑器工具/插件    | `docs/技术/编辑器工具索引.md`（addons/ + tools/ 全部脚本） |
| 开发规范            | `docs/CONTRIBUTING.md`                                  |
| 有可以参考的开源项目就放到这里 | external/                                               |

> **术语提示**：「战略图」（modules/world_map，鸟瞰多边形领土，玩家不在其中）与「场景图」（modules/world 等，卷轴地图，玩家在其中）是两类不同的地图概念，详见 `docs/技术/架构/世界地图数据流.md` §1。

***

## 核心行为指令

1. **安全第一**：需要修改 `/core/` 目录下的文件时应该得到请求释解释复杂逻辑。
3. **主动沟通**：当任务描述不清晰或与架构原则冲突时，积极主动提问，不做危险假设。
4. **设计先行**：实现任何模块（`/modules/`）前，须先用 Read 工具读取对应的设计文档。如果 GDD 标记了 `[待补充]`，须向用户确认。

***

### Godot 模块化架构原则

1. **文件夹结构**：模块一级目录按功能划分（`/modules/`、`/core/`），新功能 = 新模块，互不干扰，保证高可扩展性；模块内二级目录按类型划分（scenes/、scripts/、assets/ 等），找场景去 scenes/、找脚本去 scripts/，保证高速定位。功能定边界、类型定导航，两级结合。
2. **耦合原则**：模块间通信优先使用 `core/autoload/event_bus.gd` 的全局事件总线，或通过模块的 `api.gd` 定义信号。不要跨模块 `get_node` 或引用非 API 内部方法。
3. **接口契约**：模块对外交互须通过其根目录下的 `api.gd` 文件。

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
├── scenes/                # 模块场景（子目录按需组织，不强制固定结构）
│   └── player.tscn
├── scripts/               # 模块脚本（可再按子域分组，如 ai/、map/）
├── assets/                # 模块专属资源（按需）
├── ui/                    # 模块专属 UI（按需）
├── data/                  # 纯数据定义类（按需）
└── api.gd                 # 公共接口契约（关键）

# 二级类型目录可拓展：除常用类型外，可按需引入新类型，已有先例：
#   animations/ —— 动画资源
#   buildings/  —— 建筑类资源：建筑实例 = 场景 + 专属脚本的组合体，
#                  抽象为一个整体存放（如 building_gen/buildings/）
```

命名规范：配置尽量放 `.tres`/`.json` 而非全堆在 `project.godot`。

***

## GitHub 代码检索工具（opencode MCP）

opencode 通过本地 MCP server 接入 GitHub API，弥补模型静态知识过时（新开源库、最新 API 变更、冷门库、工业级实现参考）。模型会在需要时自动调用，无需手动干预。详细说明见 `docs/CONTRIBUTING.md` 的「GitHub 代码检索工具」一节。

**位置与注册**（全局配置，非项目内）：

- MCP server 脚本：`C:\Users\fanbo\.config\opencode\github-search.mjs`
- 注册于 `~/.config/opencode/opencode.jsonc` 的 `mcp.github-search`

**工具一览**：

| 工具 | 用途 | 底层 API |
| --- | --- | --- |
| `github_code_search` | 搜源码片段（新库用法/示例/API 报错迁移） | `/search/code` |
| `github_repo_search` | 仓库元数据（选型、活跃度判断） | `/search/repositories` |
| `github_issue_search` | 报错解决方案、已知 bug 与 workaround | `/search/issues` |
| `github_readme` | 官方安装/用法（裁剪约 220 行） | `/repos/{repo}/readme` |
| `github_clone` | 下载整仓到本地（长期/系统级参考，不限制大小） | codeload tarball（可直连，不依赖代理） |

**Token 配置**：

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens**
2. Repository access 选 **"Public repositories (read-only)"**
3. 权限仅保留：**Contents: Read** + **Metadata: Read**（只读，不泄露写权限）
4. `setx GITHUB_TOKEN "你的token"`，重启 opencode 生效

- 带 token：5000 次/小时（代码搜索必须认证）；无 token：60 次/小时（仓库/issue/README 可用，代码搜索不可用）

**克隆仓库落盘目录**：`<项目根>/external/<owner>--<repo>/`（已被 `.gitignore` 忽略，不入库；在项目内可直接 Read/Grep 深入参考）

**防上下文溢出**：所有搜索结果按 token 上限裁剪（单次 ≤8k tokens）；限流耗尽（`X-RateLimit-Remaining`）时自动降级为友好提示，不疯狂重试。
