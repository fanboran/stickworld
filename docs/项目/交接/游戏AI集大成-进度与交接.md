# 游戏AI集大成：进度与交接

> **用途**：跨会话交接的单一入口。新会话恢复本任务时**从本文件开始读**，不重新摸底。
> **真相源**：[`docs/设计/系统/12-游戏AI系统.md`](../../设计/系统/12-游戏AI系统.md)（设计基线：分层范式 + 复刻登记表 + 批次表）；逆向笔记 [`docs/审计/英雄连AI逆向_2026-09-11.md`](../../审计/英雄连AI逆向_2026-09-11.md)（CoH，L4/L2）与 [`docs/审计/小兵步枪AI逆向_2026-09-11.md`](../../审计/小兵步枪AI逆向_2026-09-11.md)（RWR，L1）；[`docs/技术/架构/组织系统架构.md`](../../技术/架构/组织系统架构.md)（L3 层基建）。

---

## 快速恢复（新会话从这里开始）

- **分支**：`agent/game-ai`（本任务独立 worktree/分支；A1 无依赖故自组织分支尖端切出提前执行，A2 起依赖组织批次 3-F2，待组织收线合 main 后按设计文档 12 号 §五 继任段推进）；跨任务总 DAG 与推进序唯一真相源 = 设计文档 12 号 §五「跨任务总 DAG」（本档不复制）
- **工作区**：`.temp/game-ai`（CoH/RWR 逆向原件在组织 worktree `.temp/organization-deepening/temp/coh/` 等，gitignored）
- **自检**：`bash stick-world/tools/check_godot_errors.sh`；测试 `bash stick-world/tests/run_all.sh`
- **当前阶段**：**A1 完成**（节拍+难度参数化），下一开工批 **A9**（仅依赖 A1，可立即做）或 **A2**（待组织 3-F2 合并）。
- **开场白**：「继续 AI集大成 批次 N」——先读本档 + 设计文档 12-游戏AI系统.md，再动手。
- **任务分级**：Pro = 需设计判断/跨模块契约；Flash = 规格明确单模块实现。
- **通用验收**：check 干净 + run_all 与基线零回归 + 回填本档 + 中文提交。

## 任务边界

- **范围**：把业界验证的 AI 机制复刻进本项目（复刻机制不复刻代码，红线见设计文档 §二），按层集成；其他游戏的引入逐个逆向→笔记→批次化。
- **边界外**：个体行为机重构（现状基线不动，L1 只增不改）；信使实体（组织任务边界外）；A7 依赖的经济域自动产出（挂 town-life/economy 任务）。

## 批次拆分（详设计文档 §六）

| 批次 | 级别 | 任务 | 依赖 | 新会话必读 |
|---|---|---|---|---|
| A1 | Flash | 节拍+难度参数化（team_ai 分帧 + personality 进 BalanceConfig category=ai） | 无 | 设计文档 §三C1/C2/§四 + `team_ai.gd`/`team_ai_profiles.gd` 现状 |
| A2 | Flash | 任务槽+目标评分+攻击百分比（task_board.gd） | A1 + 3-F2 | 设计文档 §三C3~C5 + `strategy_military.ai` 逆向笔记 |
| A3 | Flash | 自主撤退/后撤（概率调制） | A2 | 设计文档 §三C6 + `personality.ai` 撤退参数段 |
| A4 | Flash | default_behavior v2 效用打分 | A2 | 设计文档 §三C7 + `tactics.ai` |
| A5 | Flash | 小队相位计划 v1（角色+跃进+接敌反应） | A2 | 设计文档 §三C8 + `infantry-plan.squadai` |
| A6 | Flash | 压制=定时锁死 | A3 | 设计文档 §三C9 + `pinned-reaction-plan.squadai` |
| A7 | Pro | 战略域预算切分 | 经济域 | 设计文档 §三C10 |
| A8+ | Pro | 其他游戏逐个引入（候选见设计文档 §2.4） | 创始人裁决 | 设计文档 §2.4 |
| A9 | Flash | 个体 AI 参数面板（R1~R5：决策间隔族/带方差开火/兵种覆盖档/权威值择班/互助阈值，与 SWL 直译合流） | A1 | 设计文档 §2.2/2.3 + `小兵步枪AI逆向_2026-09-11.md` + `target_finder.gd`/`team_ai.gd` 直译先例 |

**依赖图**：A1→A2→{A3,A4,A5}→A6；A9 依赖 A1（与 A3~A5 并行可行）；A7/A8 独立线；A2 起依赖组织批次 3-F2。

## 进度记录

| 批次 | 状态 | 提交 | 备注 |
|---|---|---|---|
| 立项+设计 | ✅ 完成 | （见 git log） | CoH 逆向笔记 + 设计文档 12 号 + 本档；批次表定稿 |
| L1 逆向补全 | ✅ 完成 | （见 git log） | 小兵步枪(RWR) AI 逆向笔记（个体 AI 全参数 schema/兵种人格继承档/commander_ai/支援军衔经济/权威值择班）；设计文档补 R1~R7 登记 + A9 批次 |
| A1 | ✅ 完成 | （本批提交见 git log） | **节拍+难度参数化**：①C1——`team_ai.tick` 改固定节拍分帧（`beat_interval`=0.5s CoH 真值，DECIDE/BUILD 双相位轮转一跳一类事，有效决策周期 2×beat=1.0s 与旧默认等价零回归；旧 `stance_decision_interval` 退役）；②C2——难度档 `config/ai/personality.tres`（BalanceResource，类型路径 `ai.personality`，global 行=L4 基础节拍 + easy/standard/hard/hardest 四档行：开局攻击时间/方差/demand_variance 单旋钮），merge 序=代码默认<难度档案<setup overrides；开局攻击门禁=基准±`start_attack_variance` 掷骰（CoH 9min±4min 同构），默认固定种子（`DEFAULT_RANDOM_SEED`）确定性可测可复现；③新套件 `test_team_ai_personality` 7 用例锁装载/难度覆盖/掷骰界内/门禁消费/节拍分帧/下限钳制/未知难度回退；④验收：check 干净；unit 批量 40/41；battle_sim 10 场景与基线同包络（姿态机切换数/三态可达一致）；run_all 31/34 失败集合与基线一致（road_walk / fx_damage_text / melee_combat——后者经基线 worktree 复验同为既有，疑似动画时序敏感） |
| A2~A8+ | ⬜ 未开工 | — | A9 可立即开工（依赖 A1）；A2 待组织 3-F2 |

## 关键决策速查

| 决策 | 结论 |
|---|---|
| 集成原则 | 每层一个范式骨架，层间只走 EventBus/组织数据；玩家干预永远只落一层 |
| 分支策略 | 暂随 organization-deepening 分支（依赖未合并的批次 3）；组织收线后可拆独立分支 |
| 来源登记 | 三游戏各自成节：CoH（§2.1，L4/L2，C1~C10）+ RWR（§2.2，L1，R1~R7）+ SWL（§2.3，L1，S1~S5）；实现直译机制、原创代码 |
| 撤退/技能概率 | 概率是执行机制（消除阈值机械感），因果仍是真实战况（铁律派生） |
| AI 数值落点 | 全进 BalanceConfig（category=ai / command），热重载可调 |
| A1 分支拓扑 | A1 无依赖，自组织分支尖端切独立分支 `agent/game-ai` 提前执行（创始人在组织批次收线前指示继续本任务）；A2 起仍待组织归档后基点 main |
| A1 personality 落点 | 独立手写资源 `config/ai/personality.tres`（BalanceResource，BalanceConfig 统一装载+热重载）而非 variables.tres 加行——后者系 Excel 导出管线背书（手改会被再导出覆盖），且难度档是多字段行非标量 |
| A1 确定性 | 默认随机种子固定（`DEFAULT_RANDOM_SEED`）：单测可锁掷骰、battle_sim 可复现；需要逐局差异时显式传 `overrides.random_seed` |
| A1 难度选择 | setup overrides["difficulty"]（默认 standard）；全局难度选择 UI 挂开放问题#3（调试菜单先行），A1 不做 |
