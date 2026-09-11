# 游戏AI集大成：进度与交接

> **用途**：跨会话交接的单一入口。新会话恢复本任务时**从本文件开始读**，不重新摸底。
> **真相源**：[`docs/设计/系统/12-游戏AI系统.md`](../../设计/系统/12-游戏AI系统.md)（设计基线：分层范式 + 复刻登记表 + 批次表）；逆向笔记 [`docs/审计/英雄连AI逆向_2026-09-11.md`](../../审计/英雄连AI逆向_2026-09-11.md)（CoH，L4/L2）与 [`docs/审计/小兵步枪AI逆向_2026-09-11.md`](../../审计/小兵步枪AI逆向_2026-09-11.md)（RWR，L1）；[`docs/技术/架构/组织系统架构.md`](../../技术/架构/组织系统架构.md)（L3 层基建）。

---

## 快速恢复（新会话从这里开始）

- **分支**：`agent/game-ai`（本任务独立 worktree/分支；A1 无依赖故自组织分支尖端切出提前执行，A2 起依赖组织批次 3-F2，待组织收线合 main 后按设计文档 12 号 §五 继任段推进）；跨任务总 DAG 与推进序唯一真相源 = 设计文档 12 号 §五「跨任务总 DAG」（本档不复制）
- **工作区**：`.temp/game-ai`（CoH/RWR 逆向原件在组织 worktree `.temp/organization-deepening/temp/coh/` 等，gitignored）
- **自检**：`bash stick-world/tools/check_godot_errors.sh`；测试 `bash stick-world/tests/run_all.sh`
- **当前阶段**：**A1、A9、A2 完成**（节拍+难度参数化；个体 AI 参数面板 R1~R5；任务槽+目标评分+攻击百分比），下一开工批 **A3/A4/A5**（均依赖 A2，可并行）或 A8+（待创始人裁决）。
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
| A9 | ✅ 完成 | （本批提交见 git log） | **个体 AI 参数面板 R1~R5**：①R1 决策间隔族——`ai_controller` 统一 `DECISION_INTERVAL` 常量档案化（BASELINE `decision_interval`=0.3 镜像零回归 + `decision_variance` 逐拍重掷去同步，RWR choose_enemy_time±wait_time_variance 同构；硬下限 MIN_DECISION_INTERVAL=0.05 防决策风暴；域级间隔已有档案键 acquire_interval/heal_scan_interval，间隔族全景=基线注释）；②R2 兵种人格覆盖档进 BalanceConfig——新档 `config/ai/behavior_profiles.tres`（类型路径 `ai.behavior_profiles`，baseline 行镜像 A9 新键组；行只写差异项=RWR 职业文件语义，兵种行按需补），`BehaviorProfiles.get_profile` 合并序=代码基线←SWL 直译 CLASS_PROFILES←.tres 行（同 id 后行覆盖前行），缓存以行数组**引用比对**失效（reload 重建 data 即热失效，免 EventBus static 连接）；③R3 点射节奏+昼夜反应——档案 `burst_shots`（连发点数，0=关零回归）/`burst_wait`（停顿区间 1.2~1.8s，RWR wait 1.2±0.6 直译），behavior_attack 两出手点（风筝还击/射程内放箭）过 `_burst_gate`+`_register_burst_shot`（停顿期间走位/持瞄照常只禁出手）；夜间犹豫倍率 `night_hesitate_mult`（RWR 昼 0.3~0.6/夜 0.8~1.1 同构），`_is_night()` 防御式查询 EnvironmentSystem 光照亮度<0.55（与 fx 视觉层 fireflies/SkyStars 同源同分界，查询不可用=白天保守零回归）；④R5 防扎堆治疗——实体新增 `being_healed_until` 登记字段（behavior_heal 施放 HOT 时写入目标，时长+0.5s 缓冲），`TargetFinder.find_weakest_ally` 新 opts `skip_being_healed`（heal_buzz_distance>0 启用；单祭司零差异、多祭司不再扎堆同一伤员）；⑤R4 权威值择班——formation_system 新增 `get_squad_authority`（班长在场 1.0+指挥官在册 0.5+玩家光环 0.2，RWR favor_joining_player_squad 直译）与 `should_switch_squad`（margin 0.07 滞回防来回跳），**消费点挂 A2 任务槽匹配**（"谁在班里由权威值经济定"，咬合②），本批次不引入自主跳槽行为；⑥新套件 `test_ai_param_panel` 14 用例锁全部五项（覆盖链装载/合并序/引用热失效/缺载回退/SWL 直译保留/间隔恒定/方差界内/下限钳制/门禁关-计数-停顿循环/昼夜分界/防扎堆过滤-过期恢复/登记窗/权威值组合/margin 滞回）；⑦验收：check 干净；unit 批量 41/42（唯一失败=基线既有 road_walk）；run_all 31/34 失败集合与 A1 基线一致（unit(batch)/melee_combat/fx_damage_text 均既有） |
| A2 | ✅ 完成 | （本批提交见 git log） | **任务槽+目标评分+攻击百分比**：①前置——merge `agent/organization-deepening` 拿批次 3 基建（3-F2 issue_to_org 下令域），冲突 3 处按「双保/取新」处置（AGENTS.md 登记行取 game-ai 侧新行 + 组织侧新增行；team_ai_profiles 参数注释双保）；合并后首跑曾现 28 项假失败，根因 = 合并引入新脚本后 `.godot` 全局类缓存未重建（非代码回归），`--import` 重建后锁定 pre-baseline = 31/13（失败集：unit=batch 仅 road_walk + integration 8 项 + smoke 2 项，均为组织并行会话在修的合并域回归）。②C3 任务槽——新档 `task_board.gd`（TaskBoard，RefCounted）：攻/防槽（KIND_ATTACK/DEFEND），战略侧只增删空槽（`sync_slots`，期望进攻槽数 = ceil(attack% × 原子单元数)，超额杀最新保最旧），执行侧匹配（`match_groups`：组织化编制作一组/散兵各一组，序位在前攻击槽数的组绑攻击槽、余量绑防守）；槽带目标/集结点/创建时刻，集结超时（攻 180s=CoH 3min，到点杀槽由 sync 重建）/目标超时（攻 30s=CoH 30s 重评分重定向+记脏重发号令；防 120s=CoH 2min 只刷数据不重发，维持 DEFEND 不重发口径零回归）。③C4 目标评分四因子——`score_target`/`pick_target`：threat（候选点半径内敌力/本方力，CoH 5.0）− avoid_clumps（无威胁时敌群聚集惩罚，CoH 10.0）− distance（距小队/距基地双计，CoH 5.0+5.0）+ inertia（与上次目标一致满分奖励，CoH 1.4，防振荡）；取数半径/归一尺度/容差全档案化；攻击槽目标 = 敌方军事单位位+敌质心 argmax，重评分以槽现目标为惯性参照（重定向只发生在 30s 超时，不逐拍振荡）。④C5 攻击百分比四规则——`recalculate_attack_percentage`：胜利目标危急（`vp_rule_enabled` **缺省关闭【提案/待定】**，开放问题#1 无 VP 等价物，钩子 `_apply_victory_objective_rule` 留位）→ 基地威胁封顶（threat_at_base = 锚点半径内敌力/初始基线×100，超 5 → pct ≤ max(100−threat, 5)/100）→ 难度基调（门禁未开 0；开门禁后 0.6+每分钟 0.01，封顶 0.70）→ 军力优势递增（归一化优势 (我−敌)/(我+敌) > 0.4 按增益抬升同受封顶；easy 增益 0、hardest 封顶 0.95——难度差异全在参数）。⑤咬合③内核替换——team_ai 姿势决策改由槽驱动（有攻击槽→ATTACK、槽清空→DEFEND，`slot_kernel_enabled` 默认开）；SWL 比例条件**转写为槽创建/维持门禁**（enter=ratio≥attack_enter、维持=ATTACK 态 ratio>attack_exit 滞回带——带内不塌槽姿态不抖，零回归关键）；SWL 决策函数（should_attack/should_defend 签名与节流接口）原样保留为退化路径（`slot_kernel_enabled=false` 时接手，既有单测语义兼容面）。⑥下令路径收敛（设计文档 §四）——组织化编制经 `issue_to_org`（同根一号令一轮内去重，整编=原子；TacticalOrders 新增 `get_org_root_for_squad` 代理查询，combat 不直引 organization；**独立 L1（无父级）按散兵口径走 issue**——单跳计划无传播语义且事件会误标玩家跳），散兵经 issue 现场直令；`issue_to_org` 增量 `extra_params` 默认参（ROUT evacuate 经组织链透传，向后兼容）；手动号令保护期：散兵逐队避让、编制任一成员保护期内整组避让。⑦新套件 `test_task_board` 15 用例锁全部六项（配置装载/槽同步与生命周期/四因子/pick_target 确定性/匹配/攻击百分比规则与封顶/槽驱动姿态与滞回带/退化路径/路径分流/整组避让/多小队槽号令）。⑧验收：check 干净；unit 批量 50/51（唯一失败 = 基线既有 road_walk）；run_all 失败集合与 pre-baseline 完全一致（31/13，无新增）。 |
| A3~A8+ | ⬜ 未开工 | — | A3/A4/A5 依赖 A2（已就绪，可并行开工）；A6 依赖 A3；A7 依赖经济域；A8+ 待创始人裁决 |

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
| A9 R4 边界 | 权威值评分内核+margin 滞回先行，自主跳槽行为不做（玩家预期风险）——A2 任务槽匹配小队时消费 `get_squad_authority`/`should_switch_squad` |
| A9 R5 简化 | 防扎堆=登记时间戳（being_healed_until 过期即失效），RWR 的 10m 距离维度省略（治疗本有 heal_range 约束）；求援/增援族（force_comparison_multiplier 等）挂 A5/A8 |
| A9 R3 昼夜 | 夜间判定=EnvironmentSystem 光照亮度<0.55（与 fx 视觉层同源同分界）；查询不可用（测试桩/未装配）=白天，保守零回归 |
| A9 覆盖链 | BehaviorProfiles 缓存以 .tres 行数组引用比对失效（reload 重建 data 触发重合并）——static 上下文免连 EventBus，测试同式注入 |
| A2 内核开关 | `slot_kernel_enabled` 默认 true（CoH 槽内核为主，咬合③）；false=SWL 退化路径——既有单测/battle_sim 的语义兼容面，也是槽内核异常时的回退闸门 |
| A2 零回归关键 | SWL 比例条件不删除而是转写为槽创建/维持门禁（enter=attack_enter、维持=ATTACK 态 ratio>attack_exit 滞回带）——standard 档下槽内核与旧 SWL 姿态行为逐位一致 |
| A2 原子单元 | 槽匹配与下令以「原子单元」为单位：组织化编制（同组织根）=一处（整编一号令），散兵=一处；编队系统缺失/无注册小队退化 1（与 SWL「无小队仍切姿态」一致，号令侧自然空转） |
| A2 独立 L1 | 无父级的 L1 组织按散兵口径走 issue 直令——其 issue_to_org 计划只有玩家跳一跳（无传播语义）且事件误标 source_tier=0，不路由 |
| A2 issue_to_org 签名 | 增量 `extra_params: Dictionary = {}`（默认不变向后兼容）——ROUT evacuate 经组织链透传至 L1，与 issue 直令同语义 |
| A2 编制保护期 | 手动号令保护期：散兵逐队避让；编制任一成员保护期内整组避让（玩家意图压过编制号令，下轮姿态切换/槽重定向重发恢复，有界滞后 ≤ 目标超时 30s） |
| A2 VP 规则 | C5 规则一「胜利目标危急」缺省关闭（`vp_rule_enabled`=false，**开放问题#1 无 VP 等价物【提案/待定】**）；实现钩子 `_apply_victory_objective_rule` 留位，旗/区域控制接入后回填「危急抬升/我方占优翻防守」 |
| A2 合并基线 | 合并后首跑大面积失败属 `.godot` 全局类缓存未重建的假失败（新脚本入库后需 `--import`），非代码回归——后续会话遇合并后大面积「Identifier not declared」先 import 再定性 |
