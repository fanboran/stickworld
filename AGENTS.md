> **说明**：本文件是 AI 辅助开发的**主规则文件**。汇集了模块化架构规范、核心行为指令、Git 工作流、项目文档导航。

***

### 注意事项

- 使用中文回答问题。
- Git写中文提交信息，格式：`类型(模块): 描述`，示例：`feat(combat): 实现基础自动战斗单位AI`
- 改进待办项记录在 `docs/项目/待办事项.md`；建筑管线专项待办单独在 `docs/项目/待办事项-建筑管线.md`（条目多、多会话并行，不挤占全局表）
- **创始人纠正后先对齐再执行**：复述理解 + 拟执行动作给创始人过目，确认后才动手；过目内容对应他所纠正/询问的事，不夹带无关项。**豁免**：独立任务分支（worktree）上的改动直接执行、无需过目；仅主分支上的直接改动才需先过目。
- **胖文件拆分方法论**：按职责内聚与行业最佳实践判断拆分点，不固定写死行数阈值（行数仅作提示信号）；拆分纪律 = 行为与公共 API 不变、测试零改动为验收线。
- **指令范围精确**：停/改/启只作用于被点名的对象，禁止扩大到全部；不可逆操作（终止 agent、删文件、重派）未经确认不执行。
- **子代理工作纪律：代码先行，渲染最后**：先对照任务清单把全部代码改完并逐项自查（数值/摆布/密度等代码可判的错误不许靠渲染发现），再统一渲染一次出图验收；渲染是最终验证不是开发手段。
- Godot路径：`F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`
- **打包导出统一落 `F:\VSCode\作品集\`**：Windows 导出的产物（exe/pck/dll）一律输出到该本地目录（不入库），export_presets 的 export_path 与手动导出均以此为准；给创始人验收时直接给该目录下对应子目录的完整绝对路径。版本存档按 `stick-world-vX.Y-win64.zip` 命名放在同目录。
- **打正式包前先核导入缓存**：`.import` 参数（如压缩模式）变更后，`--headless --import` 不一定触发重导入，会把 `.godot/imported/` 里的陈旧 ctex 原样打进 pck（实测虚胖到 511M）——改动过压缩参数后须删 `.godot/imported/`（可连带 `.godot/exported/`）再 `--import` 重建，打出的包才真实。

### 文档写作规范

- **普通文档只写"是什么 / 怎么设计 / 为什么这么设计"**，不写"什么时候改的 / 为什么改的 / 之前是什么"这类变更记录（如"已于 2026-08 移出 P0""原为 X，现已改为 Y""经创始人确认"等）。
- **AI 提案必须显式标注**：世界观/剧情/命名类内容凡属 AI 生成的提案而非创始人确认的设定，须在所在文档标注「提案/待定」；其他文档引用时不得当作已确认设定——防止提案被反复复读成"世界观基石"（上古魔方事件的教训）。
- **Git 本身就是文档的历史版本**，变更过程一律交给提交历史，不需要在正文里复述。
- 例外：**专门记录变更的文档**（`docs/项目/待办事项-已完成.md`（待办的已完成归档）等）可以写变更过程。

### 会话交接（长任务跨对话）

- 长任务（多阶段实施类）跨多个对话会话推进。当上下文过长、判断质量可能下降时，**主动建议用户开新对话**，不要硬撑。
- **交接前必须**：更新该任务的交接文档（进度 / 下一步任务分解 / 关键决策 / 新会话恢复指引）并 git 提交。
- **新会话恢复**：用户说「继续 <任务名>」时，先读[活跃任务登记](docs/项目/交接/活跃任务登记.md)找到对应交接档并恢复上下文，再开始干活，不重新摸底。
- **任务分支一律用独立 worktree**：`git worktree add .temp/<任务名> -b agent/<后缀>`，任务会话在对应 worktree 内干活；**主工作区（仓库根）留给 `main`**，禁止在主工作区长期 checkout 任务分支（多会话并行共用仓库，占主工作区会把其他会话的提交混进自己的分支）。注意各 worktree 的 `temp/`（gitignored）互相独立，渲染产物/验收档案不共享。收线后 `git worktree remove` + 合并/删分支。
- **交接档统一放 `docs/项目/交接/`**（索引见其 [README.md](docs/项目/交接/README.md)）；任务收官无待验收项的移入 `docs/项目/交接/归档/`；**代码审计/快照类文档用完直接删除**，不进归档（审计快照放 `docs/审计/`）。
- **待创始人人工验收的产物必须给完整绝对路径**：凡"需要创始人看/听/点开才能验收"的东西（渲染图、试听样带、报告、存档、可执行产物），在本文件的登记行（即[活跃任务登记](docs/项目/交接/活跃任务登记.md)对应行）与交接文档里都要写出**完整 Windows 绝对路径并带盘符**（形如 `F:\VSCode\game-2\.temp\<worktree>\temp\<产物目录>\`），让他能直接粘贴进文件资源管理器跳过去；**只写仓库相对路径（如 `temp/xxx/`）算没写**——相对路径无法在资源管理器里定位，等于让他自己找。各任务在自己 worktree 里干活，产物通常在 `.temp\<任务名>\temp\` 下，也可能在仓库根 `temp\`，**以实际位置为准**（写之前先 `ls` 确认存在）。
- **活跃任务登记独立成档**：全部活跃交接文档（含各任务状态/验收产物绝对路径）、在跑任务分支、在役审计快照统一登记在 [docs/项目/交接/活跃任务登记.md](docs/项目/交接/活跃任务登记.md)——**只有交接类任务读取它**（新会话恢复任务、收线/登记更新时），其余会话不预载；worktree 增删、分支收线、产物迁移后须当场同步该文件对应行。

### 项目文档导航

本项目（stick-world）是一个火柴人大战略+组织自动化缝合怪。游戏设计文档和技术架构位于 `docs/` 目录。任何需要记忆的信息都应该记忆到文档里，但是如果不那么结构化可以直接在对应目录写README.md文件，也可以直接在代码里注释。

**按需自行读取以下文档（不要预加载，只在实现对应模块时读取）**：

| 要做什么            | 读哪个                                                     |
| --------------- | ------------------------------------------------------- |
| **查技术架构（模块依赖/实体/EventBus/API 契约/存储/战略图/场景图…）** | `docs/技术/架构/README.md`（架构文档地图，按场景索引全部架构文档） |
| **查建筑管线（流程/资产/规则/HD-2D 街景）** | `docs/技术/架构/建筑管线/README.md`（管线文档导读：主规范→资产清单→分级/地面/烘焙/内景/品控→运行时） |
| 了解游戏整体          | `docs/设计/游戏设计文档.md`                                 |
| 查 UI 体系规划/模板    | `docs/设计/UI/README.md`（索引各篇；模板在 `modules/ui_global/scenes/templates/`） |
| **音效（SFX）** | 事件表与播放策略 = `core/services/audio_manager.gd` 的 `SFX_EVENTS`/`SFX_POLICY`；设计口径 `docs/技术/音频/音效设计规范.md`；触发时机 `docs/技术/音频/音效触发规范.md`；来源与许可 `docs/技术/音频/音效资产登记与来源.md`；替换登记 `docs/项目/素材替换清单.md` |
| **音乐（设计/技法/管线/运行时）** | 设计索引 `docs/设计/音乐/README.md`；运行时架构 `docs/技术/架构/音乐系统.md`；离线管线 `docs/技术/音频/音乐制作管线.md`；资产许可 `docs/技术/音频/音乐资产登记与来源.md` |
| 实现某个系统          | `docs/设计/系统/<系统名>.md`                        |
| 查核心实体/状态机       | `docs/技术/架构/核心实体与状态机.md`               |
| 查 EventBus 信号   | `docs/技术/架构/系统交互与EventBus.md`           |
| 查模块 API 规范      | `docs/技术/架构/模块API契约.md`                   |
| 查模块实现状态/断链点（GDD↔代码对照） | `docs/技术/架构/模块依赖关系.md` |
| 查 Autoload 依赖   | `docs/技术/架构/自动加载依赖.md`              |
| 查战略图（world_map）架构 | `docs/技术/架构/战略图架构.md`（模块重新设计基线） |
| 查程序化产物如何喂给战略图 | `docs/技术/架构/世界地图数据流.md`（生成端 ↔ 消费端契约） |
| **查仓库瘦身/附属库/历史去向（战略图 submodule、旧资产存档库、备份 bundle）** | `docs/技术/仓库瘦身与历史去向.md` |
| 查场景图（卷轴地图）架构 | `docs/技术/架构/场景与战斗架构.md`（导读，索引各子系统）<br>↳ 宿主: [`场景宿主架构.md`](docs/技术/架构/场景与战斗/场景宿主架构.md)<br>↳ 地图/室内/旅行: [`地图与场景图.md`](docs/技术/架构/场景与战斗/地图与场景图.md)<br>↳ 建筑/定居点: [`建筑与定居点.md`](docs/技术/架构/场景与战斗/建筑与定居点.md)<br>↳ 火柴人AI/战斗: [`战斗与AI.md`](docs/技术/架构/场景与战斗/战斗与AI.md)<br>↳ UI/环境: [`UI.md`](docs/技术/架构/场景与战斗/UI.md)<br>↳ 事件信号: [`EventBus信号契约.md`](docs/技术/架构/场景与战斗/EventBus信号契约.md) |
| 查数据流与存储方案      | `docs/技术/架构/数据流全景.md` |
| 查 UI 运行时三项优化（暂停原语化/HUD 槽位/按钮变体） | `docs/技术/架构/UI运行时架构优化方案.md`（设计基线，工作项在待办事项） |
| 查程序化世界生成       | `docs/设计/系统/08-程序化世界生成.md` |
| 游戏数据表           | `config/excel/` 目录 + `docs/技术/教程/Excel数据管线.md` |
| 查编辑器工具/插件    | `docs/技术/编辑器工具索引.md`（addons/ + tools/ 全部脚本） |
| 查 Godot 引擎 API（类参考，项目外） | `F:\VSCode\godot-docs\doc\classes\<类名>.xml`（`--doctool` 生成，版本精准；查属性/方法/信号用） |
| 查编辑器/运行时报错    | `stick-world/tools/check_godot_errors.sh`（扫描 `user://logs/`，日志机制见 `docs/技术/教程/Godot日志与报错检测.md`） |
| 开发规范            | `docs/CONTRIBUTING.md`                                  |
| 有可以参考的开源项目就放到这里 | external/                                               |

> **术语提示**：「战略图」（modules/world_map，鸟瞰多边形领土，玩家不在其中）与「场景图」（modules/world 等，卷轴地图，玩家在其中）是两类不同的地图概念，详见 `docs/技术/架构/世界地图数据流.md` §1。

***

## 核心行为指令

1. **主动沟通**：当任务描述不清晰或与架构原则冲突时，积极主动提问，不做危险假设。但可从系统一致性推导的实现细节（如某系统接入另一系统的方式、宏观涌现类机制的节奏）**不问创始人**——自行推导并落档；只把真正需要创始人定方向、定了会改做法的分歧拿出来问。
2. **设计先行**：实现任何模块前，须先用 Read 工具读取对应的设计文档（`docs/设计/系统/<模块名>.md` ）。如果 GDD 标记了 `[待补充]`，须向用户确认。
3. **报错自检**：任何代码修改后，运行 `bash stick-world/tools/check_godot_errors.sh`（退出码 1 = 日志有报错，须修复）；用户报告编辑器报错时先查日志再处置，详见 `docs/技术/教程/Godot日志与报错检测.md`。测试：`bash stick-world/tests/run_all.sh`（全量 / `-Changed` 增量 / `-Match` 过滤，详见 `docs/技术/教程/测试矩阵.md`）。
4. **文档同步**：每批代码修改完成后，记得同步更新受影响的文档（设计文档/架构文档/交接文档等），保持文档与代码一致；文档更新属于该批任务的收尾步骤，随本批代码一批提交，不要攒到最后统一补。
5. **GitHub 查询走 MCP**：查 GitHub（代码/issue/仓库/README）一律用 `github-search` MCP 工具（已配置 GITHUB_TOKEN 认证）；**禁止手动 curl 匿名调用 api.github.com**（匿名限额 60 次/时，会触发限流并污染诊断）。
6. **火柴人视觉唯一骨架方向（2026-09-15 定）**：HD-2D billboard 骨架是火柴人唯一视觉骨架，2D 时代的 RigHost 视觉链路按「旧代码清理」清单退役（2D 要彻底删除）；血条/进度条/武器等角色随身视觉一律**随骨架做进 billboard**——数据源与状态机留在实体 2D 侧，渲染走镜像（如血条：2D 实例切数据模式只产状态，billboard 内同脚本 driven 实例只画），不得再往 2D 画布链路加角色视觉。
7. **UI 布局单一真相源**：场景是布局唯一真相源，**禁止 `Control.new()` 当 UI 根**（会丢 anchor 致控件静默不可见）；代码建控件的合规出口（全屏 `full_rect()` / 角落部件 `widget()` + 槽位）见 `docs/技术/架构/场景与战斗/UI.md`。

***

### Godot 模块化架构原则

1. **文件夹结构**：模块一级目录按功能划分（`/modules/`、`/core/`），新功能 = 新模块，互不干扰，保证高可扩展性；模块内二级目录按类型划分（scenes/、scripts/、assets/ 等），找场景去 scenes/、找脚本去 scripts/，保证高速定位。功能定边界、类型定导航，两级结合。
2. **耦合原则**：模块间通信优先使用 `core/autoload/event_bus.gd` 的全局事件总线，或通过模块的 `api.gd` 定义信号。不要跨模块 `get_node` 或引用非 API 内部方法。
3. **接口契约**：模块对外交互须通过其根目录下的 `api.gd` 文件。
4. **依赖分层**：只允许高层依赖低层——L0 `core/` → L1 基础设施（ui_global/fx/texture_gen/building_gen/environment）→ L2 玩法（combat/units/construction/organization/resources/inventory/player_control/world_map/debug_gui）→ L3 组装（world 唯一 composition root）。改动跨模块结构后跑 `python tools/audit_deps.py` 自检（零依赖环；跨模块 preload 仅限 api.gd 或行内 `audit-exempt` 标记+理由）。架构收敛工作项（AR 系列）见 `docs/项目/待办事项.md`。

**解耦核心策略**：

- 优先使用事件总线，而非直接方法调用
- 每个模块只暴露一小组精心设计的公共方法和信号
- 高层模块不直接依赖低层模块，两者依赖抽象接口
- 同一模块所有文件物理上放在同一文件夹

***

### 顶层目录结构

> **实际 Godot 工程在 `stick-world/` 子目录**（res:// 根 = `stick-world/`）；以下结构是 `stick-world/` 内的布局，根目录仅保留 docs/、tools/、external/ 等仓库级内容。

```
/ (res://)
├── core/                  # 核心系统与基础设施
├── modules/               # 游戏功能模块（开发最频繁的区域）
├── assets/                # 全局共享资源
├── addons/                # 编辑器插件（项目自带 + 第三方），详见 docs/技术/编辑器工具索引.md
├── tools/                 # 自定义编辑器工具与 CLI 脚本（@tool），详见 docs/技术/编辑器工具索引.md
├── tests/                 # 自动化测试（unit/integration/smoke/dev 分层，详见 tests/README.md）
└── docs/                  # 项目文档（指向仓库根 docs/ 的符号链接）
```

### 战略图数据 submodule（stickworld-mapdata）

- `stick-world/config/strategic_map` 是独立 git 仓库的 submodule（`git@github.com:fanboran/stickworld-mapdata.git`），主仓只记录指针 commit。战略图 png/json/bin 及其 `.import` 的改动**属于 submodule 仓库**：在 submodule 内开分支提交，主仓收线时同步 bump 指针——两仓都要提交，只动一边会丢改动。
- 新 clone / 新 worktree 里该目录默认是空的，先初始化：`git submodule update --init -- stick-world/config/strategic_map`。本地想免 SSH/网络拉取（约 541M），先把 url 指到主工作区已有检出，再单次放行 file 协议初始化（新版 git 默认禁止本地路径 clone，不要全局放开）：
  ```
  git config submodule.stick-world/config/strategic_map.url "F:/VSCode/game-2/stick-world/config/strategic_map"
  git -c protocol.file.allow=always submodule update --init -- stick-world/config/strategic_map
  ```
- 背景（瘦身动机/历史去向）见 `docs/技术/仓库瘦身与历史去向.md`。

### 核心模块 (`core/`) 结构

```
core/
├── autoload/              # 全局单例
│   ├── event_bus.gd       # 全局事件总线（发布-订阅模式）
│   ├── world_state.gd     # 全局状态容器
│   ├── save_manager.gd    # 存档/读档服务
│   ├── config_manager.gd  # 游戏配置管理
│   ├── time_manager.gd    # 时间/速度管理
│   └── balance_config.gd  # 平衡变量加载（热重载预留）
├── entities/              # 核心实体状态快照（RefCounted）
├── ui_framework/          # UI 基础设施
│   ├── base_screen.gd     # UI 界面基类
│   ├── components/        # 通用 UI 组件
│   └── theme/             # 全局 UI 主题
└── services/              # 抽象服务
    ├── audio_manager.gd   # 音频管理器（预留，未接线）
    ├── analytics/         # 数据分析（预留）
    └── iap/               # 内购（预留）
```

### 游戏功能模块 (`modules/`) 标准结构

每个模块是一个垂直切片，自包含。以 `player_control` 为例：

```
modules/player_control/
├── scripts/               # 模块脚本（可再按子域分组，如 ai/、map/）
├── ui/                    # 模块专属 UI（按需）
├── data/                  # 纯数据定义类（按需）
└── api.gd                 # 公共接口契约（关键）

# 二级类型目录可拓展：除常用类型外，可按需引入新类型，已有先例：
#   animations/ —— 动画资源
#   buildings/  —— 建筑类资源：建筑实例 = 场景 + 专属脚本的组合体，
#                  抽象为一个整体存放（如 building_gen/buildings/）
```

命名规范：配置尽量放 `.tres`/`.json` 而非全堆在 `project.godot`。
