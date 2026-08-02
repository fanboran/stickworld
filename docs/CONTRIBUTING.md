# 贡献指南

## 开发环境

1. 安装 Godot 4.x（[godotengine.org](https://godotengine.org)）
2. 克隆仓库：`git clone <repo-url>`
3. 安装 GdUnit4 测试框架（Godot 内 AssetLib 搜索安装）
4. 安装 Python 3.10+（用于工具脚本和向量知识库）
5. Godot 编辑器路径：`F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`

## 分支策略

- `dev` — 主开发分支
- `agent/<feature>` — 功能分支（AI Agent 自动创建）
- `fix/<issue>` — 修复分支

**工作流**：
```
1. 从 dev 创建功能分支
2. 编写代码 + 测试
3. 原子化提交（一个功能一个 commit）
4. 推送并合并回 dev
```

## 代码规范

- 语言：GDScript
- 命名：snake_case（变量/函数），PascalCase（类）
- 信号命名：`something_happened`
- 所有公开函数须有 docstring
- 新增功能必须有对应的 GdUnit4 测试
- 配置尽量放 `.tres`/`.json` 而非全堆在 `project.godot`
- 与 AI 协作时使用中文交流

## 提交信息格式

```
<type>(<scope>): <description>
```

类型：`feat` / `fix` / `refactor` / `test` / `docs` / `chore`

描述使用中文。示例：
```
feat(combat): 实现基础自动战斗单位AI
fix(org): 修复组织架构树节点层级溢出
```

## 项目结构

```
/ (res://)
├── core/                  # 核心系统与基础设施（稳定，修改需批准）
├── modules/               # 游戏功能模块（开发最频繁的区域）
├── assets/                # 全局共享资源
├── addons/                # 编辑器插件（项目自带 + 第三方）
├── prototypes/            # 原型沙盒（不被正式逻辑依赖）
├── tools/                 # 自定义编辑器工具与 CLI 脚本（@tool）
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

## 架构红线

以下内容**禁止**在未获明确许可的情况下修改：

1. `core/` 目录下的核心系统文件（修改前须获批并解释复杂逻辑）
2. `core/autoload/` 中的全局单例
3. 跨模块直接引用内部节点（必须通过 `api.gd` 或 `event_bus`）

### 模块化架构原则

1. **文件夹结构**：按功能模块（`/modules/`）和核心系统（`/core/`）划分，按功能组织，不按类型（场景/脚本/素材）
2. **耦合原则**：模块间通信优先使用 `core/autoload/event_bus.gd` 全局事件总线，或通过模块的 `api.gd` 定义信号；不要跨模块 `get_node` 或引用非 API 内部方法
3. **接口契约**：模块对外交互须通过其根目录下的 `api.gd` 文件

**解耦核心策略**：

- 优先使用事件总线，而非直接方法调用
- 每个模块只暴露一小组精心设计的公共方法和信号
- 高层模块不直接依赖低层模块，两者依赖抽象接口
- 同一模块所有文件物理上放在同一文件夹

## 测试要求

- 新功能要有单元测试
- 修改核心系统前必须先跑全量测试

## 文档同步

- 修改游戏设计 → 更新 `docs/设计/游戏设计文档.md`（GDD 是唯一真相源）
- 发现架构问题 → 追加到 `docs/项目/待办事项.md`
- 实现模块（`/modules/`）前先读取对应设计文档，GDD 标记 `[待补充]` 时须先确认

### 文档导航（按需读取，不要预加载）

| 要做什么 | 读哪个 |
| --- | --- |
| 了解游戏整体 | `docs/设计/游戏设计文档.md` |
| 实现某个系统 | `docs/设计/系统/<系统名>.md` |
| 查核心实体/状态机 | `docs/技术/架构/核心实体与状态机.md` |
| 查 EventBus 信号 | `docs/技术/架构/系统交互与EventBus.md` |
| 查模块 API 规范 | `docs/技术/架构/模块API契约.md` |
| 查 Autoload 依赖 | `docs/技术/架构/自动加载依赖.md` |
| 查战略图（world_map）架构 | `docs/技术/架构/战略图架构.md` |
| 查程序化产物如何喂给战略图 | `docs/技术/架构/世界地图数据流.md` |
| 查场景图（卷轴地图）架构 | `docs/技术/架构/场景与战斗架构.md`（导读，索引各子系统文档） |
| 查数据流与存储方案 | `docs/技术/架构/数据流全景.md` |
| 查程序化世界生成 | `docs/设计/系统/08-程序化世界生成.md` |
| 游戏数据表 | `config/excel/` 目录 + `docs/技术/教程/Excel数据管线.md` |
| 查编辑器工具/插件 | `docs/技术/编辑器工具索引.md` |
| 开源项目参考 | `external/` 目录 |

> **术语提示**：「战略图」（modules/world_map，鸟瞰多边形领土，玩家不在其中）与「场景图」（modules/world 等，卷轴地图，玩家在其中）是两类不同的地图概念，详见 `docs/技术/架构/世界地图数据流.md` §1。

## 提问与沟通

- 设计问题 → 参考 `docs/设计/游戏设计文档.md`（GDD 是唯一真相源）
- 技术问题 → 参考 `docs/技术/技术栈选型.md`
- 任务描述不清晰或与架构原则冲突时 → 主动提问，不做危险假设
- 未找到答案 → 询问项目创始人

---

# GitHub 代码检索工具（opencode MCP）

opencode 通过本地 MCP server 接入 GitHub API，弥补模型静态知识过时（新开源库、最新 API 变更、冷门库、工业级实现参考）。模型会在需要时自动调用，无需手动干预。

**位置与注册**（全局配置，非项目内）：

- MCP server 脚本：`C:\Users\fanbo\.config\opencode\github-search.mjs`
- 注册于 `~/.config/opencode/opencode.jsonc` 的 `mcp.github-search`
- 依赖 `@modelcontextprotocol/sdk`（安装于 `~/.config/opencode/node_modules`）

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
