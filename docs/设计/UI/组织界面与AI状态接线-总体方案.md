# 组织界面与AI状态接线 · 总体方案

> **定位**：「游戏 AI 集大成」任务的 UI 消费端设计——把 [`../系统/12-游戏AI系统.md`](../系统/12-游戏AI系统.md)
> 各层 AI 机制的状态接出可观测面（调试向），并把组织编制界面从「CRUD 工具」升维成「乐趣核心」（体验向）。
> 上游契约：[`../../技术/架构/组织系统架构.md`](../../技术/架构/组织系统架构.md)（指挥链/传输层/补位/上报）、
> [`../../技术/架构/场景与战斗/UI.md`](../../技术/架构/场景与战斗/UI.md)（UI 体系规范）、
> [`01-设计语言.md`](01-设计语言.md)（视觉 token）。
>
> **本文全文为【提案/待定】**：所有设计（含各节内单独标注项）均为 AI 起草的提案，经创始人过目裁决后方可实施。
> 进度背景见 [`../../项目/交接/游戏AI集大成-进度与交接.md`](../../项目/交接/游戏AI集大成-进度与交接.md)（A1~A5/A9 已落地）。

---

## 一、定位与裁决前提

**裁决①（创始人）：难度维度整体不做。** 不只是不做难度选择 UI/难度分级产品化——难度参数层本身也不保留：AI 行为参数收敛为**单一默认档案**，机制参数（决策节拍/攻击门禁/概率调制/方差扰动等）保留，不再有难度差异化维度。相关查询接口（`get_difficulty` 等）将随参数层返工退役，**本文全部可观测面设计不依赖任何难度字段**。

**裁决②（创始人）：组织编制界面的美观与好用是后续游玩的乐趣核心。** 各层级（班/排/连/营…）的组织界面按「值得驻足观赏与把玩」的标准设计，不是"能看就行"——这是本文体验向主线的验收基调。

**两大主线**：

| 主线 | 性质 | 一句话 |
|------|------|--------|
| §二 AI 状态可观测面接线 | 调试向 | A1~A5/A9 落地的 AI 机制目前几乎不可见，先把状态接出来（F3 族调试 UI），支撑调参与回归观察 |
| §三 组织编制界面体系 | 体验向 | OrgPanel 现状是数据结构 CRUD；把组织的「活」（指挥链/补位/权威值/相位计划）变成看得见摸得着的乐趣 |

两条主线共用一批接口缺口补齐（§2.6），但批次上可独立推进（§四）。

---

## 二、AI 状态可观测面接线（调试向）

### 2.0 总原则

1. **调试 UI 全走 DebugApi drawer 开关族**（F3 统一控制，[debug_info_panel.gd](../../../stick-world/modules/debug_gui/scripts/debug_info_panel.gd) 既有惯例），不进玩家默认视野；
2. **数据来源一律 duck 查询**：`has_method`/`"field" in` 探测，查询不可用即跳过该行——调试面板不倒逼战斗侧改结构；
3. **优先消费既有 getter/信号**，缺口单列 §2.6 清单，不隐性扩散。

### 2.1 逐单位：DebugInfoPanel 悬停增强

现状悬停字段（[debug_info_panel.gd:87-98](../../../stick-world/modules/debug_gui/scripts/debug_info_panel.gd)）：名称/坐标/主控AI/动画/朝向/HP。追加以下 AI 字段（同构 duck 风格）：

| 字段 | 数据来源 | 现状 |
|------|---------|------|
| 行为名 | `_state_machine.get_current_behavior_name()`（ai_controller 内部既有消费，[ai_controller.gd:259](../../../stick-world/modules/units/scripts/ai/ai_controller.gd)） | 既有 |
| AI 参数摘要 | BehaviorProfiles 兵种覆盖档关键字段（`decision_interval`/`burst_shots` 等**机制参数**；无难度档——维度已裁决移除） | 既有（A9） |
| 相位/角色 | `squad_phase_plan.get_role_of(unit)` / `get_phase_name()`（[squad_phase_plan.gd:147/155](../../../stick-world/modules/combat/scripts/command/squad_phase_plan.gd)） | 既有（A5） |
| 撤退调制状态 | `ai_controller` 私有字段 `_retreat_mod_rng`/`_retreat_mod_next_roll_at`（[ai_controller.gd:96-99](../../../stick-world/modules/units/scripts/ai/ai_controller.gd)）——**需补只读 getter** `get_retreat_mod_state()`（候选因子命中项/最近掷骰结果/节流窗口余量） | 接口缺口 |

- **落点文件**：`modules/debug_gui/scripts/debug_info_panel.gd`（追加段）
- **档位**：小

### 2.2 阵营级：TeamAi 状态 HUD

按 [UI.md](../../技术/架构/场景与战斗/UI.md) §10.7.2 角落 HUD 部件规则落位：

- **落点文件**：`modules/combat/ui/team_ai_hud.gd` + `team_ai_hud.tscn`（新，模块专属 UI 归 combat/ui，§10.3）；挂 `UIRoot.add_to_slot("HudOverlay", ...)`；显隐走 DebugApi drawer（`"team_ai_hud"`），F3 族统一。
- **数据来源（全部既有）**：
  - 信号：`EventBus.team_ai_stance_changed(battle_id, faction, from_stance, to_stance, reason)`（[event_bus.gd:51](../../../stick-world/core/autoload/event_bus.gd)——姿态/reason 全齐，信号驱动不轮询）；
  - 查询：`bi.get_team_ai(faction)`（[battle_instance.gd:374](../../../stick-world/modules/combat/scripts/battle/battle_instance.gd)）→ `get_stance()`/`get_stance_reason()`（[team_ai.gd:212/224](../../../stick-world/modules/combat/scripts/battle/team_ai.gd)）、`get_task_board()`（team_ai.gd:491）→ `slot_count()`/`get_slots()`（[task_board.gd:153/158](../../../stick-world/modules/combat/scripts/battle/task_board.gd)）、`get_attack_deadline()`（team_ai.gd:234，开局攻击倒计时）；
  - attack%：建议补只读 getter `get_attack_percentage()`——`recalculate_attack_percentage`（team_ai.gd:510）是内部计算，UI 轮询不宜重跑。
- **显示内容**（左右阵营各一条，角落堆叠）：姿态徽标（驻守/防守/进攻/溃退）+ reason 一行 + attack% + 攻/防任务槽占用（攻 n·防 m）+ 开战攻击倒计时。
- **档位**：小

### 2.3 L2 相位计划显示

- **现状可查**：`get_phase()`/`get_phase_name()`/`get_roles()`/`get_role_of()`（[squad_phase_plan.gd:143-155](../../../stick-world/modules/combat/scripts/command/squad_phase_plan.gd)），经宿主 formation_system 可达。
- **接口缺口**：相位/角色变更**无信号**（squad_phase_plan.gd 零 signal 声明），UI 只能逐帧轮询。提案补两信号：
  - `phase_changed(squad_id, from_phase, to_phase)`——`_enter()`（:259）发射；
  - `roles_reassigned(squad_id)`——`_reassign_roles()`（:361）发射。
- **显示**：相位徽标「跃进中·核心组先行 / 两翼跟进」（`get_phase_name` 直译）+ 成员角色角标（Core/Scout/双翼），落班组卡（§3.2.A）与调试 HUD。
- **落点文件**：squad_phase_plan.gd（补信号）+ formation_system（透传）+ 消费端 UI。
- **档位**：中

### 2.4 观察场调试 HUD（9h 计划资产）

9h（[`../../项目/AI复刻执行计划.md`](../../项目/AI复刻执行计划.md) §二 P1）已规划观察场调试 HUD：逐单位 行为/号令/眩晕/溃逃/锚定，热键开关——用于卡死复验定位。**本方案不重复立项，只做字段增补**：

- 增补 AI 列：AI 档键实测值（`decision_interval`/`decision_variance`）、相位/角色（§2.3）、撤退调制最近掷骰结果（§2.1 getter）、当前目标 id；
- 热键开关沿用 DebugApi `drawer_enabled` 逐项开关惯例（调试字段多列时逐列开关，防信息淹没）；
- **落点文件**：`modules/debug_gui/scripts/`（与 debug_info_panel 同族扩展或独立多列面板，实施时按 9h 既有计划归口）；
- **档位**：中

### 2.5 TeamAi 生产启用链路核实与接线方案

**核实结论**：`enable_team_ai`（[battle_instance.gd:363](../../../stick-world/modules/combat/scripts/battle/battle_instance.gd)）是注册制开关（默认不启用 = 零回归闸门）。但生产链上——
[battle_director.gd:65](../../../stick-world/modules/combat/scripts/battle/battle_director.gd) 只透传 `set_order_refs`，**从不调 `enable_team_ai`**：经 BattleDirector 开出的战斗（观察场/普通遭遇战）TeamAi 全程未启用；[conquest_manager.gd:157](../../../stick-world/modules/expansion/scripts/conquest_manager.gd) 仅据点战守军（faction 2）启用。即 §2.2 HUD 在多数生产战斗中**无数据可看**——接线须先修启用链。

**接线方案【提案/待定】**：

- `battle_director.start_battle_at` 在 `bi.setup(map)` / `set_order_refs` 之后，按战斗配置项 `team_ai_enabled` 对攻守双方 `enable_team_ai(faction, overrides)`；
- 默认值取舍（观察场对照调参 vs 生产可观测）见开放问题 §五.1；配置项落场景/战斗配置（BalanceConfig 惯例）；
- conquest_manager 既有守军调用保留——同一 API，重复注册有告警幂等保护（battle_instance.gd:367），无冲突。

**档位**：小

### 2.6 接口缺口清单（本线新增接口全部登记于此）

| 缺口 | 现状 | 提案接口 | 落点 | 消费方 |
|------|------|---------|------|--------|
| 相位/角色变更信号 | squad_phase_plan 零信号 | `phase_changed` / `roles_reassigned` | squad_phase_plan.gd | §2.3 / §3.3③ |
| attack% 只读查询 | recalculate 为内部计算 | `team_ai.get_attack_percentage()` | team_ai.gd | §2.2 |
| 撤退调制状态查询 | 字段私有 | `ai_controller.get_retreat_mod_state()` | ai_controller.gd | §2.1 / §2.4 |
| 在途命令注册表 | CommandChain 接力无登记（[command_chain.gd:52](../../../stick-world/modules/combat/scripts/command/command_chain.gd) `deliver_via_orgs` 无在途记录） | 在途清单查询 + `relay_started` / `relay_arrived` 信号（载 hop 序位/from/to org/ETA） | command_chain.gd | §3.2.B 指挥链动画 |

---

## 三、组织编制界面体系（体验向——乐趣核心）

### 3.1 现状盘点

**OrgPanel 现状**（[org_panel.gd](../../../stick-world/modules/organization/ui/org_panel.gd)）：820×520 StickWindow FLOATING（org_panel.gd:90-92），标签过滤树 + 左树右详情；详情区十项操作（新建子编制/插入上下层/删除层级/解散/换指挥官/移除成员/自主权限/改名/预设创建/导出蓝图，[org_panel.gd:298-440](../../../stick-world/modules/organization/ui/org_panel.gd) 详情区）。树节点一行式文案 `[L1] 名称 · 军事 4人 ▲#id`（org_panel.gd:257-259）。**能力底座扎实（十项操作全通），但呈现是纯数据结构视角。**

**缺口五条**：

1. **无逐层视图**——L1 班与 L3 师共用同一套 CRUD 详情字段；组织的「活」语义（士气/职责/状态/号令）不在场；
2. **无指挥链可视化**——树只是数据结构；命令沿层物理传播（传输层 v1，[`组织系统架构.md` §4.2](../../技术/架构/组织系统架构.md)）与在途状态零表达；
3. **无补位与上报显示**——`report_filed` 信号（[organization/api.gd:23](../../../stick-world/modules/organization/api.gd)）零 UI 消费方；补位候选序 `get_succession_candidates`（api.gd:326）有接口无界面；「群龙无首」持续空缺态（组织架构 §4.3 ③）无标记；
4. **权威值经济无表达**——`get_squad_authority`/`should_switch_squad`（[formation_system.gd:431/451](../../../stick-world/modules/combat/scripts/command/formation_system.gd)，A9 已落地）——「谁想加入谁的班」不可见；
5. **在途命令不可见**——CommandChain 接力执行无在途登记，UI 无从查询每跳 ETA（依赖 §2.6 末行接口）。

### 3.2 逐层级界面设计

**设计总纲**：信息密度服从管理层级（[01-设计语言.md](01-设计语言.md) §1.3）——L1 稀疏大字、L2+ 中密度、战略报表式；一套 StickTokens / 手绘 SKETCH 皮肤全层级共用。每个层级视图回答一个问题：**这一层的指挥官此刻关心什么？**

#### A. L1 班排级——班组卡（SquadCard）

- **落位**：ContextPanel 的 SquadInspector 槽位（[UI.md](../../技术/架构/场景与战斗/UI.md) §10.1）；框选小队或选中 L1 组织时显示。
- **信息密度取舍**：只答三问——这班人**现在怎么样**（士气/状态）、**在干什么**（号令/相位）、**听谁的**（班长/权威值）。不做字段堆砌。
- **内容**：
  - 头部：班名 + 状态徽标（组建中 FORMING / 活跃 / 接战 / 撤退中——org state + 成员行为聚合）；
  - 成员行：火柴人图标位 + 职责角色角标（Core/Scout/双翼，消费 §2.3 相位查询）+ 士气微型条 + 单兵状态（溃逃/被压制/治疗中）；
  - 班长栏：指挥官 + 权威值（`get_squad_authority` 呈现为「威望」数值/星级）；
  - 号令栏：当前号令（消费 `EventBus.order_issued`，[event_bus.gd:67](../../../stick-world/core/autoload/event_bus.gd)）+ 相位徽标（跃进中·核心组先行）；
  - FORMING 态：招兵进度（兵营招兵接线后填入）。
- **核心操作**：任命指挥官（既有 `assign_commander`）、移除成员（既有）、放大到指挥链视图（跳 §B）。
- **视觉方向**：SketchPanel LIGHT 横条 + 琥珀强调选中；图标母题取图标库定稿枚（旗帜=班组/短剑=接战/爱心=治疗，[`图标清单与缺口.md`](图标清单与缺口.md)），缺口母题按其立项流程补。

#### B. L2 连营级——指挥链视图（CommandChainView）★ 本项目独有特色

**为什么是特色**：逐层指挥链 + 物理传播是本项目组织层独有语义（12 号文档 §一「CoH 没有」）；业界先例（CoH 任务槽 / M&B 部队层级）均无「命令沿层级逐跳跑秒」的可视化。命令不是瞬发魔法而是**物理旅程**——把旅程画出来，这是本项目 UI 的差异化招牌。

- **形态**：独立 StickWindow（与 OrgPanel 并存，入口形态取舍见开放问题 §五.2）。
- **内容**：
  - **层级树 = 兵棋沙盘**：节点是「木质兵牌」（内容色板 CONTENT_PALETTE 纹章化，按 tag 染色），连线是指挥关系；中间层节点牌 = 指挥官 + 统辖规模 + 补位候选前三（`get_succession_candidates`）+ 持续空缺「群龙无首」墨渍标记；
  - **命令传播动画层**：下令后命令沿 hop 序列逐跳点亮（玩家跳 → 根组织 → … → L1 叶），每跳连线标注 `delivery_time` 实时秒数（[transport_layer.gd:62](../../../stick-world/modules/organization/scripts/command/transport_layer.gd) 既有计算）；命令到达 L1 时对应班组卡脉冲一下。事件驱动（消费 §2.6 `relay_started`/`relay_arrived`），不逐帧轮询；
  - **空缺停驻表达**：指挥官空缺的组织节点显示「命令停驻」态（停驻丢弃语义，组织架构 §4.3.1）——玩家直观看到「这条线断了」。
- **信息密度取舍**：中密度——树 + 动画层是主视觉，字段收进节点牌的选中态/tooltip；动画是「戏剧」不是装饰，动效纪律照设计语言 §五（透明度/位移 + 沸腾重掷）。
- **核心操作**：对任意层节点下令（`issue_to_org` 既有入口，选层即对该层子树下令）、任命统辖（既有插入流程语义）、查看在途命令清单。
- **视觉方向**：黑玻璃窗上的手绘作战沙盘——窗户不是海报（§1.1），战场从面板底下透出来；兵牌沸腾、命令流光沿连线跳动。

#### C. 战略视图——多组织总览

- **形态**：ModalOverlay 大面板（UI.md §10.1「组织架构总览」既有槽位语义），报表式排布（宏观层级 = 密集，§1.3）。
- **内容**：全组织森林树 + 每组织摘要行（人数/士气均值/状态/驻地/最近上报）+ **上报流时间线**（`report_filed` 消费：commander_lost / casualty_threshold / contact 三型 payload schema 现成，组织架构 §4.4；展示的是 autonomy 门控后的真实可见集）。
- **核心操作**：跨组织调人（拖拽成员行 → 目标组织；API 形态见开放问题 §五.6）、标签过滤（复用 OrgPanel 既有过滤语义）。
- **视觉方向**：账本/印章/罗盘母题（均定稿枚），报表不等于冷漠——行内士气条/状态徽标仍走手绘语言。

### 3.3 与 AI 联动的界面表达（「组织活起来」的乐趣点）

1. **权威值择班可视化**：班组卡显示权威值与相邻班对比、「N 人有意转投 X 班」提示条。R4 评分内核已落地（A9：`get_squad_authority`/`should_switch_squad`），但自主跳槽行为本身不做（A9 决策：玩家预期风险）——界面先行表达倾向。是否剧透见开放问题 §五.4。
2. **补位事件叙事**：连长阵亡 → toast「▲#id 阵亡——排长 ▲#xx 自动接任」。双信号消费：`EventBus.commander_assigned`（[event_bus.gd:69](../../../stick-world/core/autoload/event_bus.gd)，补位成功也发）+ `report_filed(commander_lost)`（payload `prev_commander_id`/`filled`/`successor_id` 现成）。补位瞬间是指挥链戏剧性的高光时刻，值得一个仪式感呈现（战果横幅级，FONT_BANNER 待定）。
3. **相位计划徽标**：班组卡常驻「跃进中/核心组先行/两翼跟进」——AI 内部计划（A5）的第一处玩家可见表达；配合成员角色角标，玩家能看懂「谁先冲谁后跟」。
4. **命令旅程演播**：§3.2.B 动画层——传播延迟不是隐藏成本而是**看得见的戏剧**；玩家学会「下令要打提前量」本身就是玩法教学。

### 3.4 设计原则

1. **美观好用是乐趣核心**（裁决②）：逐层视图的验收标准含观感走查，不是「功能在就行」；
2. **场景是布局唯一真相源**（AGENTS 核心行为指令 #5、UI.md §10.7）：新界面一律 `.tscn` 骨架 + StickKit/StickStyle 装配，禁止 `Control.new()` 当 UI 根；
3. **槽位路由**：班组卡 → ContextPanel（SquadInspector）、指挥链/总览 → ModalOverlay、TeamAi HUD → HudOverlay；
4. **控件复用变体系统**：SketchButton 四态 + PRIMARY/DANGER 语义、StickTokens 单 token 源、`StickIcons.tex(&"母题名")` 直查；
5. **数据驱动**：新层级视图 = 数据行扩展，不写死 UI（UI 体系 README 设计目标 3）;
6. **模块归属垂直切片**（UI.md §10.3）：班组卡归 `combat/ui`（消费战斗域数据）、指挥链视图/总览归 `organization/ui`（消费组织域数据）——不建跨模块大杂烩面板。

---

## 四、批次拆分建议

| 批次 | 内容 | 档位 | 验收门 |
|------|------|------|--------|
| **W1 观测接线批**（调试向） | §2.5 TeamAi 生产启用接线 + §2.2 TeamAi HUD + §2.1 悬停增强 + §2.6 前三行接口补齐（相位信号/attack% getter/撤退调制 getter） | 小 | check_godot_errors 干净；run_all 零回归；F3 开关族逐项可控显隐 |
| **W2 组织界面 MVP** | §3.2.A L1 班组卡（ContextPanel 槽位）+ OrgPanel 树增强（节点状态徽标/「群龙无首」标记）+ 上报流消费（toast 级） | 中 | 同上 + ui_shots 截图自检（[09-布局规则与AI自检](09-布局规则与AI自检.md) 惯例）+ 创始人观感初验 |
| **W3 指挥链可视化** | §2.6 末行在途命令注册表 + §3.2.B 命令传播动画层 + 每跳 ETA 标注 + 停驻表达 | 大 | 同上 + 传播动画与 transport 实测延迟一致性抽检 |
| **W4 逐层深化** | §3.2.B 中间层节点牌完善（补位候选序/统辖规模）+ §3.2.C 战略总览面板 + §3.3① 权威值择班表达 + 图标缺口母题立项 | 中~大 | 同上 + 全层级视图观感走查（裁决②基调） |

**依赖关系**：W1 独立可先行（纯接线）；W2 独立；W3 依赖 W1 的启用接线（有真实命令流才有动画可演）+ 在途注册表；W4 依赖 W2/W3 骨架。各批均为【提案/待定】，创始人裁决范围与排序后按 12 号文档 §五 DAG 并行约束排期。

---

## 五、开放问题（留创始人裁决）

1. **TeamAi 生产默认开还是关**：观察场需要「开/关对照」调参（默认关利调试）vs 生产战斗可观测即开。提案：战场默认开、观察场以配置项显式关。
2. **指挥链视图的窗口形态**：OrgPanel 内标签切页（单窗口心智）vs 独立 StickWindow（FormationPanel 先例 = 各开各的面板、不做跨面板状态同步）。提案：独立窗口——动画层需要常驻不被 CRUD 操作打断。
3. **命令传播动画的渲染层**：UI 层示意动画（指挥链窗口内连线流光，低成本）vs 世界层真实光点沿战场跑（沉浸感强，成本高一个量级）。提案：先 UI 层，世界层挂 P2 观感验证后再议。
4. **权威值择班「只显示不模拟」的玩家预期**：显示「N 人想转投」但人不真的动，是否算 UI 说谎。备选：MVP 只显示权威值数值、不给意向文案，等跳槽行为实装再上叙事。
5. **相位/在途信号落点**：EventBus 全局（`team_ai_stance_changed` 先例）vs combat/organization api 自建信号（`report_filed` 先例）。提案：战斗域内消费的走 api 自建，跨模块调试观测的进 EventBus。
6. **跨组织调人的 API 形态**：既有 `remove_stickman` + 挂载拼装（UI 层两次调用）vs organization api 增 `transfer_stickman` 原子接口（合法性校验一体）。提案：原子接口——拖拽交互中途失败回滚比预检简单。
7. **组织界面图标缺口**：指挥链/补位/在途命令/权威值缺对应母题（图标库 86 枚无一精确命中），需按 [`图标清单与缺口.md`](图标清单与缺口.md) 流程立项制作。
