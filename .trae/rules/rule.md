---
alwaysApply: true
---

## 通用规则（跨 Godot 项目可复用的主规则文件）

> **说明**：本文件（`rule.md`）是 AI 辅助开发的**主规则文件**。汇集了模块化架构规范、核心行为指令、Git 工作流、项目文档导航。
>
> 同一目录下可能还存在：
> - `rule_local.md`（项目特定内容：项目名、项目路径、项目级引用）
> - `CI-DI.md`（CI/CD 方法论）
> - `issues.md`（错误记忆 / 向量数据库管理）

---

### 语言规范

- 使用中文进行思考、回答问题、写提交信息。

### 代码输出规范

- **代码引用格式**：所有对文件、代码元素的引用使用可点击链接 `[name](file:///absolute/path)`。
- **不要创建不必要的文件**：优先编辑现有文件。
- **不要主动创建文档类文件**（如 README），除非用户明确要求。

### 项目文档导航

本项目（stick-world）是一个火柴人大战略+工厂自动化缝合怪。游戏设计文档和技术架构位于 `docs/` 目录。

**按需自行读取以下文档（不要预加载，只在实现对应模块时读取）**：

| 要做什么 | 读哪个 |
|----------|--------|
| 了解游戏整体 | `docs/design/gdd.md` |
| 实现某个系统 | `docs/design/mechanics/<系统名>.md` |
| 查核心实体/状态机 | `docs/technical/architecture/entities.md` |
| 查 EventBus 信号 | `docs/technical/architecture/interactions.md` |
| 查模块 API 规范 | `docs/technical/architecture/apis.md` |
| 查 Autoload 依赖 | `docs/technical/architecture/autoloads.md` |
| 开发规范 | `docs/CONTRIBUTING.md` |

---

## 核心行为指令

1. **安全第一**：不能直接修改 `/core/` 目录下的任何文件，除非得到明确指令。
2. **测试驱动**：生成的任何功能代码，必须附带相应的 `GdUnit4` 单元测试，放置在 `/tests/` 目录中。
3. **代码即文档**：代码必须清晰、易读，包含必要的注释解释复杂逻辑。
4. **原子化提交**：每次提交完成一个独立、最小化的功能单元。
5. **主动沟通**：当任务描述不清晰或与架构原则冲突时，主动提问，不做危险假设。
6. **设计先行**：实现任何模块前，必须先用 Read 工具读取对应的设计文档（`docs/design/mechanics/<模块名>.md` 和 `docs/technical/architecture/apis.md` 中该模块的 API 段落）。如果 GDD 标记了 `[待补充]`，必须向用户确认后再编码。跳过此步直接写代码会导致 API 和数据结构与设计脱节。

---

### Godot 模块化架构 4 大原则

1. **文件夹结构**：严格遵循按功能模块（`/modules/`）和核心系统（`/core/`）划分的结构。按功能组织，不按类型（场景/脚本/素材）。
2. **命名规范**：文件和目录 `snake_case`，节点和类名 `PascalCase`。
3. **耦合原则**：模块间通信优先使用 `core/autoload/event_bus.gd` 的全局事件总线，或通过模块的 `api.gd` 定义信号。严禁跨模块 `get_node` 或引用非 API 内部方法。
4. **接口契约**：模块对外交互必须通过其根目录下的 `api.gd` 文件。

**解耦核心策略**：
- 优先使用事件总线，而非直接方法调用
- 每个模块只暴露一小组精心设计的公共方法和信号
- 高层模块不直接依赖低层模块，两者依赖抽象接口
- 同一模块所有文件物理上放在同一文件夹

---

### 顶层目录结构

```
/ (res://)
├── core/                  # 核心系统与基础设施（稳定，修改需批准）
├── modules/               # 游戏功能模块（开发最频繁的区域）
├── assets/                # 全局共享资源
├── addons/                # 第三方插件
├── prototypes/            # 原型沙盒（不被正式逻辑依赖）
├── tools/                 # 自定义编辑器工具（@tool 脚本）
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
├── assets/                # 模块专属资源
├── ui/                    # 模块专属 UI
└── api.gd                 # 公共接口契约（关键！）
```

`api.gd` 定义该模块对外暴露的公共方法、公共信号、公共属性。所有其他模块与该模块的交互**必须且只能**通过 `api.gd`。

命名规范：配置尽量放 `.tres`/`.json` 而非全堆在 `project.godot`。

---

## 自动化工作流（预留）

> 以下为团队扩展后的 CI/CD 设计，当前单人开发阶段不强制。

1. 任务定义 → Agent 代码生成 → 自动化验证（CI 运行编译+测试+场景检查）→ 人类审查 → 合并
2. 使用 GdUnit4 测试框架。AI 生成功能代码时同时生成测试。
3. 可在流水线中加入场景层次验证：用 Godot headless 运行验证脚本，断言场景结构完整。

---

## Git 分支与工作流规范

### 分支角色

| 分支 | 用途 | 寿命 |
|------|------|------|
| `main` | 稳定发布分支 | 永久 |
| `dev/xxx` | 各开发者的个人集成分支 | 永久 |
| `agent/xxx` | AI 执行任务的功能分支 | **合并后删除** |

### AI 工作流

1. 确定当前 `dev/xxx` 分支
2. `git checkout -b agent/xxx <当前dev分支>`
3. 编码 + 测试 → `godot --headless` 验证 → 原子化提交
4. `git push -u origin agent/xxx`
5. 合并回 dev：`git checkout <dev> ; git merge agent/xxx ; git push`
6. 清理：`git branch -d agent/xxx ; git push origin --delete agent/xxx`

### 提交规范

- 中文提交信息，格式：`类型(模块): 描述`
- 类型：`feat` / `fix` / `refactor` / `test` / `docs` / `chore`
- 示例：`feat(combat): 实现基础自动战斗单位AI`
- **修改 Godot 项目后必须用 `godot --headless` 验证编译通过再提交**

### 待办项维护

- 改进待办项记录在 `docs/project/todo.md`
- 完成一项立即删除对应条目
- 新增项追加到对应优先级分区

---

## 命令行环境规范

- 本项目使用 **Git Bash**（非 PowerShell）。使用 Unix 风格命令：`ls`、`grep`、`rm`、`mkdir -p`、`&&`、`||`。
- 路径使用正斜杠 `/`。
- 路径含空格必须用引号包裹。
- Godot headless 命令：`"<godot路径>" --headless`。

