### 注意事项

- Git写中文提交信息，格式：`类型(模块): 描述`，示例：`feat(combat): 实现基础自动战斗单位AI`
创始人指出执行错误纠正后先停下对齐再执行：复述理解 + 拟执行动作给创始人过目，确认后才动手；过目内容对应他所纠正/询问的事，不夹带无关项。
- Godot路径：`F:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`
- **打正式包前先核导入缓存**：`.import` 参数（如压缩模式）变更后，`--headless --import` 不一定触发重导入，会把 `.godot/imported/` 里的陈旧 ctex 原样打进 pck（实测虚胖到 511M）——改动过压缩参数后须删 `.godot/imported/`（可连带 `.godot/exported/`）再 `--import` 重建，打出的包才真实。
- 主动沟通：当任务描述不清晰或与架构原则冲突时，积极主动提问，不做危险假设。但可从系统一致性推导的实现细节（如某系统接入另一系统的方式、宏观涌现类机制的节奏）**不问创始人**——自行推导并落档；只把真正需要创始人定方向、定了会改做法的分歧拿出来问。
- 设计先行：实现任何模块前，须先用 Read 工具读取对应的设计文档（`docs/设计/系统/<模块名>.md` ）。如果 GDD 标记了 `[待补充]`，须向用户确认。
- 文档同步：每批代码修改完成后，记得同步更新受影响的架构文档和交接文档，随本批代码一批提交。
- UI 布局单一真相源：场景是布局唯一真相源，禁止 `Control.new()` 当 UI 根（会丢 anchor 致控件静默不可见）；代码建控件的合规出口（全屏 `full_rect()` / 角落部件 `widget()` + 槽位）见 `docs/技术/架构/场景与战斗/UI.md`。

### 文档写作规范

- 普通文档只写"是什么 / 怎么设计 / 为什么这么设计"，不写"什么时候改的 / 为什么改的 / 之前是什么"这类变更记录（如"已于 2026-08 移出 P0""原为 X，现已改为 Y""经创始人确认"等）。
- `docs/设计/` 只写"是什么 / 做什么"（机制定义、规则、数值、目标体验）——不写实现方案（怎么做，归 `docs/技术/`），尤其不要出现具体代码段引用，不写项目进度与状态对账（✅/⬜、已落码、排期，归 `docs/进展/`；单系统内部现状对账可留实现设计文）。
- AI 提案以文章为单位显式标注：世界观/剧情/命名类内容凡属 AI 生成的提案而非创始人确认的设定，须在所在文档标注「提案/待定」。
- Git 本身就是文档的历史版本，变更过程一律交给提交历史，不需要在正文里复述。
- 专门记录变更的文档可以写变更过程。
- 交接档/登记档等给 AI 看的文档只记事实、状态与路径，不放人类向的阅读入口（图解/讲解/演示页之类）；人类验收读物的入口放在人类会到达的位置（[待创始人验收档](docs/项目/交接/待创始人验收.md)对应行、验收产物目录内的 README）。
- 机器事实不进散文：测试数量、包版本、分支名、文件清单等可从仓库推导的事实，文档只写"以 X 为准"（Test Runner 实跑 / `Packages/manifest.json` / git），不写具体数值——防漂移
- 积极写代码注释
- 文件夹是进化出来的：单一主题先做单文档（无内容时用空文档占位，不建空文件夹），同主题攒到数篇或单篇过大再升格为文件夹；`docs/images` 等纯资产目录除外；同一主题的系列内容（某些参考原文逐篇、某系统的多份设计稿）各自建子目录归档，不要在类目根平铺堆文件；汇总性文档放类目根，原文/单篇放子目录。
- 契约与实现分层：跨模块契约（模块边界、固定步顺序、对外接口语义）归 `docs/技术/代码框架.md`，单系统实现归 `docs/技术/` 各实现文件——实现文引用框架，框架不复制实现明细，避免双份漂移；短期待办唯一落点为 `docs/项目/待办事项.md`。
- 技术类文档过期无需归档，过时直接根除，应该保证文档内容与代码同步。
- `README.md` 只有文件夹内文件较多且不同质化时才写，否则文件夹名就够用了，不需要额外说明。有时文件夹内有总结性的文件了也不用。
- 感到文档混乱时就要重构文档，不要打补丁式修正，以逐条为单位，假设整个文件夹内所有条目都在一个大文档里，你会怎么进行拆分。也就是不受原有的若干个文件和文件名束缚，要系统性重构，按内容本身重新划界。
- 任何修订的内容都要直接根据内容直接修正原文，不要在原文旁边另起一行。

### 会话交接（长任务跨对话）

- 长任务（多阶段实施类）跨多个对话会话推进。当上下文过长、判断质量可能下降时，主动建议用户开新对话，不要硬撑。
- 交接前更新该任务的交接文档（进度 / 下一步任务分解 / 关键决策 / 新会话恢复指引）并 git 提交。
- 用户说「继续 <任务名>」时，先读[活跃任务登记](docs/项目/交接/活跃任务登记.md)找到对应交接档并恢复上下文，再开始干活，不重新摸底。
- 任务分支可以用独立 worktree：`git worktree add .temp/<任务名> -b agent/<后缀>`，任务会话在对应 worktree 内干活；主工作区（仓库根）留给 `main`，禁止在主工作区checkout 任务分支（多会话并行共用仓库，占主工作区会把其他会话的提交混进自己的分支）。注意各 worktree 的 `temp/`（gitignored）互相独立，渲染产物/验收档案不共享。收线后 `git worktree remove` + 合并/删分支。
- 交接档统一放 `docs/项目/交接/`（索引＝[活跃任务登记](docs/项目/交接/活跃任务登记.md)，目录不设 README）；任务收官无待验收项的移入 `docs/项目/交接/归档/`；代码审计/快照类文档用完直接删除，不进归档（审计快照放 `docs/项目/审计/`）。
- 待创始人人工验收的产物必须给完整绝对路径：凡"需要创始人看/听/点开才能验收"的东西（渲染图、试听样带、报告、存档、可执行产物），在对话与交接文档里都要写出**完整 Windows 绝对路径并带盘符**，让他能直接粘贴进文件资源管理器跳过去。
- 活跃任务登记独立成档：在跑任务分支、在役审计快照与正在推进的任务统一登记在 [docs/项目/交接/活跃任务登记.md](docs/项目/交接/活跃任务登记.md)；
- 已收线待验收的移[待创始人验收](docs/项目/交接/待创始人验收.md)
- 有尾巴不推进的移[缓期与悬置任务](docs/项目/交接/缓期与悬置任务.md)。

### 项目文档导航

本项目（stick-world）是一个火柴人大战略+组织自动化缝合怪。游戏设计文档和技术架构位于 `docs/` 目录。任何长期的信息都应该记到文档和注释里。

**按需自行读取以下文档（不要预加载，只在实现对应模块时读取）**：

| 要做什么            | 读哪个                                                     |
| --------------- | ------------------------------------------------------- |
| **查技术架构（模块依赖/实体/EventBus/API 契约/存储/战略图/场景图…）** | `docs/技术/架构/README.md`（架构文档地图，按场景索引全部架构文档） |
| **查建筑管线（流程/资产/规则/HD-2D 街景）** | `docs/技术/架构/建筑管线/README.md`（管线文档导读：主规范→资产清单→分级/地面/烘焙/内景/品控→运行时） |
| 了解游戏整体          | `docs/设计/游戏设计文档.md`                                 |
| **起名/改数值前必读（命名风格 + 资产数值档）** | `docs/设计/命名与数值口径.md`（游戏内名词一律通用描述性称谓、禁武侠雅名；资产数值取整十不膨胀） |
| **查 UI 设计（设计语言/界面框架/各屏规划）** | `docs/设计/UI/README.md`（索引各篇） |
| **查 UI 实现（组件库/主题/模态栈/设置/布局铁律/图标管线）** | `docs/技术/UI/README.md`（模板在 `modules/ui_global/scenes/templates/`；场景图 UI 分层另见 `docs/技术/架构/场景与战斗/UI.md`） |
| **查背包/物品/装备系统** | 设计定稿 `docs/设计/系统/背包与装备系统.md`（items 域/列表制/翻包/建筑交互/滚轮语义）；分期蓝图 `docs/技术/架构/武器装备与个人库存.md`；L1 物品域代码 `modules/items/`（README 索引）；待办余项在 `docs/项目/待办事项.md` P9 节 |
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

### Godot 模块化架构原则

1. **文件夹结构**：模块一级目录按功能划分（`/modules/`、`/core/`），新功能 = 新模块，互不干扰，保证高可扩展性；模块内二级目录按类型划分（scenes/、scripts/、assets/ 等），找场景去 scenes/、找脚本去 scripts/，保证高速定位。功能定边界、类型定导航，两级结合。
2. **耦合原则**：模块间通信优先使用 `core/autoload/event_bus.gd` 的全局事件总线，或通过模块的 `api.gd` 定义信号。不要跨模块 `get_node` 或引用非 API 内部方法。
3. **接口契约**：模块对外交互须通过其根目录下的 `api.gd` 文件。
4. **依赖分层**：只允许高层依赖低层——L0 `core/` → L1 基础设施（items/ui_global/fx/texture_gen/building_gen/environment/hd2d/stick_rig）→ L2 玩法（combat/formation/tactics/units/construction/organization/resources/inventory/player_control/world_map/debug_gui/expansion/town_life）→ L3 组装（world 唯一 composition root）。stick_rig = 火柴人唯一视觉骨架（L1），tactics = 目标选择/战术号令共享词汇（L2，零出向）；items 为物品域 L1（ItemDef/ItemContainer 列表制/ItemTransfer，零出向），inventory 为其玩家侧消费者。改动跨模块结构后跑 `python tools/audit_deps.py` 自检（零依赖环；跨模块 preload 仅限 api.gd 或行内 `audit-exempt` 标记+理由）。架构收敛工作项（AR 系列）见 `docs/项目/待办事项.md`。

**解耦核心策略**：

- 优先使用事件总线，而非直接方法调用
- 每个模块只暴露一小组精心设计的公共方法和信号
- 高层模块不直接依赖低层模块，两者依赖抽象接口
- 同一模块所有文件物理上放在同一文件夹

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
│   ├── balance_config.gd  # 平衡变量加载（热重载预留）
│   └── input_bindings.gd  # 输入绑定单一真相源（assets/config/input_actions.json → InputMap 动作注册）
├── entities/              # 核心实体状态快照（RefCounted）
├── ui_framework/          # L0 UI 公共层（纯布局原语与无依赖组件，零资产零模块依赖，分层契约见 core/ui_framework/README.md）
│   ├── ui_kit.gd          # UIKit：full_rect() 全屏根 / widget() 角落部件的代码建 UI 合规出口
│   └── components/        # progress_painter.gd 世界空间进度条 _draw 公共基类
│                          # （视觉/主题/屏幕基类属 L1，在 modules/ui_global：sketch 手绘控件族、StickTheme/StickStyle、StickScreen/StickWindow）
└── services/              # 抽象服务
    ├── audio_manager.gd   # 音频管理器（预留，未接线）
    └── analytics/         # 数据分析（预留）
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
