# 游戏AI集大成：进度与交接

> **用途**：跨会话交接的单一入口。新会话恢复本任务时**从本文件开始读**，不重新摸底。
> **真相源**：[`docs/设计/系统/12-游戏AI系统.md`](../../设计/系统/12-游戏AI系统.md)（设计基线：分层范式 + 复刻登记表 + 批次表）；逆向笔记 [`docs/审计/英雄连AI逆向_2026-09-11.md`](../../审计/英雄连AI逆向_2026-09-11.md)（CoH，L4/L2）与 [`docs/审计/小兵步枪AI逆向_2026-09-11.md`](../../审计/小兵步枪AI逆向_2026-09-11.md)（RWR，L1）；[`docs/技术/架构/组织系统架构.md`](../../技术/架构/组织系统架构.md)（L3 层基建）。

---

## 快速恢复（新会话从这里开始）

- **分支**：`agent/game-ai`（本任务独立 worktree/分支；A1 无依赖故自组织分支尖端切出提前执行，A2 起依赖组织批次 3-F2，待组织收线合 main 后按设计文档 12 号 §五 继任段推进）；跨任务总 DAG 与推进序唯一真相源 = 设计文档 12 号 §五「跨任务总 DAG」（本档不复制）
- **工作区**：`.temp/game-ai`（CoH/RWR 逆向原件在组织 worktree `.temp/organization-deepening/temp/coh/` 等，gitignored）
- **自检**：`bash stick-world/tools/check_godot_errors.sh`；测试 `bash stick-world/tests/run_all.sh`
- **开闸/校准入口**：设计文档 §七「机制开关总表」——全部机制开关（层/默认/开闸后可观测差异/观察入口）+ 开闸纪律，校准轮按表逐项开、逐项看
- **当前阶段**：**A 系列 + 观测接线批 + WorldBox WB1/WB2/WB6 三批全部收官合入 main**。创始人裁决**不再实机验收**，机制开闸改由 AI 线按设计文档 §七 清单**逐层开闸并留档**（每开一批跑零回归 + 把可观测指标写成报告，创始人抽空看报告）。在办四批：**AI-GAPS**（A6 箭矢近失压制接入 + WB2 AI 时钟族读档序列化）、**AUTHORITY-SWITCH**（自主跳槽行为实装）、**UI-W2-A**（L1 班组卡）、**UI-W2-B**（OrgPanel 树增强 + 上报流/补位叙事）。WB3~WB5/WB7~WB10 按 §2.4 批次归属表分流至 30fps·组织·出征·town-life 各线随线立项。
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
| WB1~WB10 | 见设计文档 §2.4 | WorldBox W1~W10 批次化：WB1（softmax 选优）/WB2（冷却错峰）/WB6（评分留痕）归 AI 线；WB4（行为机重构）留 AI 线待立项；WB3/WB9 分流 30fps 线、WB5 组织线、WB7/WB8 出征线、WB10 town-life/inventory 线 | 见设计文档 §2.4 | 设计文档 §2.4 批次归属表 + `docs/审计/worldbox-reverse/`（0-代码地图/1-个体AI内核/2-任务编排/3-外交组织军事/4-调度与物品） |

**依赖图**：A1→A2→{A3,A4,A5}→A6；A9 依赖 A1（与 A3~A5 并行可行）；A7/A8 独立线；A2 起依赖组织批次 3-F2。

### 开闸批次计划（GK 系列 —— 创始人 2026-09-13 授权按 §七 清单逐层开闸并留档）

开关清单与语义见设计文档 §七。开闸按「同层 + 同风险面」分组，一组一批、开一批留一档：

| 批 | 内容 | 前置 | 证据口径 |
|---|---|---|---|
| GK-1 | L1 个体动作细节：`heal_enabled`、`arrow_threat_block`、`missing_arrows_tolerance`、`burst_shots`、`night_hesitate_mult`、`flank_enabled`、`rout_strafe_enabled`、`rout_reengage_enabled`、`test_engage_enabled` | AI-GAPS 落地 | 行为差异可辨（点射停顿/夜战变慢/绕侧接近/溃兵不走直线）；unit 全绿 + run_all 失败集不扩大 |
| GK-2 | L1 状态类：`suppression_enabled`（含近失触发）、`retreat_mod_enabled` | AI-GAPS 落地 | 触发次数与分布（既有查询面：压制状态/`get_retreat_mod_state`）；溃逃节奏与战损不失控 |
| GK-3 | L1 调度类：`spawn_jitter_enabled`、`probe_fail_cooldown_enabled` | — | 首拍决策离散度上升（`get_decision_timing_state`）、齐套尖峰下降 |
| GK-4 | L2：`phase_plan_enabled` | — | 相位序列符合计划（`phase_changed` 信号留痕：核心先行→两翼跟进→接敌转掩体） |
| GK-5 | L4：`default_behavior_v2_enabled`（效用打分宿主）+ 权威值择班开关 | 组织侧 `default_behavior` 配置**写入方**（当前无写入方，开了也没有候选）+ AUTHORITY-SWITCH 落地 | 行为选择分布、换班次数与滞回表现 |
| 不开 | `vp_rule_enabled`（本游戏无 VP 等价物，留位）；`slot_kernel_enabled`/`team_ai_enabled`/softmax 三键已在默认开，不需开闸 |

**证据诚实口径**：能给量化指标的就给（触发次数/分布/离散度/信号序列）；当前确实没有测量手段的（如帧率在 headless 与实机不可比）就明确写"本批仅机制触发 + 零回归，无量化指标"，**不假装有数据**。若某批需要新增测量口，那本身作为该批的一项交付登记在报告里。

## 进度记录

| 批次 | 状态 | 提交 | 备注 |
|---|---|---|---|
| 立项+设计 | ✅ 完成 | （见 git log） | CoH 逆向笔记 + 设计文档 12 号 + 本档；批次表定稿 |
| L1 逆向补全 | ✅ 完成 | （见 git log） | 小兵步枪(RWR) AI 逆向笔记（个体 AI 全参数 schema/兵种人格继承档/commander_ai/支援军衔经济/权威值择班）；设计文档补 R1~R7 登记 + A9 批次 |
| A1 | ✅ 完成 | （本批提交见 git log） | **节拍+难度参数化**：①C1——`team_ai.tick` 改固定节拍分帧（`beat_interval`=0.5s CoH 真值，DECIDE/BUILD 双相位轮转一跳一类事，有效决策周期 2×beat=1.0s 与旧默认等价零回归；旧 `stance_decision_interval` 退役）；②C2——难度档 `config/ai/personality.tres`（BalanceResource，类型路径 `ai.personality`，global 行=L4 基础节拍 + easy/standard/hard/hardest 四档行：开局攻击时间/方差/demand_variance 单旋钮），merge 序=代码默认<难度档案<setup overrides；开局攻击门禁=基准±`start_attack_variance` 掷骰（CoH 9min±4min 同构），默认固定种子（`DEFAULT_RANDOM_SEED`）确定性可测可复现；③新套件 `test_team_ai_personality` 7 用例锁装载/难度覆盖/掷骰界内/门禁消费/节拍分帧/下限钳制/未知难度回退；④验收：check 干净；unit 批量 40/41；battle_sim 10 场景与基线同包络（姿态机切换数/三态可达一致）；run_all 31/34 失败集合与基线一致（road_walk / fx_damage_text / melee_combat——后者经基线 worktree 复验同为既有，疑似动画时序敏感） |
| A9 | ✅ 完成 | （本批提交见 git log） | **个体 AI 参数面板 R1~R5**：①R1 决策间隔族——`ai_controller` 统一 `DECISION_INTERVAL` 常量档案化（BASELINE `decision_interval`=0.3 镜像零回归 + `decision_variance` 逐拍重掷去同步，RWR choose_enemy_time±wait_time_variance 同构；硬下限 MIN_DECISION_INTERVAL=0.05 防决策风暴；域级间隔已有档案键 acquire_interval/heal_scan_interval，间隔族全景=基线注释）；②R2 兵种人格覆盖档进 BalanceConfig——新档 `config/ai/behavior_profiles.tres`（类型路径 `ai.behavior_profiles`，baseline 行镜像 A9 新键组；行只写差异项=RWR 职业文件语义，兵种行按需补），`BehaviorProfiles.get_profile` 合并序=代码基线←SWL 直译 CLASS_PROFILES←.tres 行（同 id 后行覆盖前行），缓存以行数组**引用比对**失效（reload 重建 data 即热失效，免 EventBus static 连接）；③R3 点射节奏+昼夜反应——档案 `burst_shots`（连发点数，0=关零回归）/`burst_wait`（停顿区间 1.2~1.8s，RWR wait 1.2±0.6 直译），behavior_attack 两出手点（风筝还击/射程内放箭）过 `_burst_gate`+`_register_burst_shot`（停顿期间走位/持瞄照常只禁出手）；夜间犹豫倍率 `night_hesitate_mult`（RWR 昼 0.3~0.6/夜 0.8~1.1 同构），`_is_night()` 防御式查询 EnvironmentSystem 光照亮度<0.55（与 fx 视觉层 fireflies/SkyStars 同源同分界，查询不可用=白天保守零回归）；④R5 防扎堆治疗——实体新增 `being_healed_until` 登记字段（behavior_heal 施放 HOT 时写入目标，时长+0.5s 缓冲），`TargetFinder.find_weakest_ally` 新 opts `skip_being_healed`（heal_buzz_distance>0 启用；单祭司零差异、多祭司不再扎堆同一伤员）；⑤R4 权威值择班——formation_system 新增 `get_squad_authority`（班长在场 1.0+指挥官在册 0.5+玩家光环 0.2，RWR favor_joining_player_squad 直译）与 `should_switch_squad`（margin 0.07 滞回防来回跳），**消费点挂 A2 任务槽匹配**（"谁在班里由权威值经济定"，咬合②），本批次不引入自主跳槽行为；⑥新套件 `test_ai_param_panel` 14 用例锁全部五项（覆盖链装载/合并序/引用热失效/缺载回退/SWL 直译保留/间隔恒定/方差界内/下限钳制/门禁关-计数-停顿循环/昼夜分界/防扎堆过滤-过期恢复/登记窗/权威值组合/margin 滞回）；⑦验收：check 干净；unit 批量 41/42（唯一失败=基线既有 road_walk）；run_all 31/34 失败集合与 A1 基线一致（unit(batch)/melee_combat/fx_damage_text 均既有） |
| A2 | ✅ 完成 | （本批提交见 git log） | **任务槽+目标评分+攻击百分比**：①前置——merge `agent/organization-deepening` 拿批次 3 基建（3-F2 issue_to_org 下令域），冲突 3 处按「双保/取新」处置（AGENTS.md 登记行取 game-ai 侧新行 + 组织侧新增行；team_ai_profiles 参数注释双保）；合并后首跑曾现 28 项假失败，根因 = 合并引入新脚本后 `.godot` 全局类缓存未重建（非代码回归），`--import` 重建后锁定 pre-baseline = 31/13（失败集：unit=batch 仅 road_walk + integration 8 项 + smoke 2 项，均为组织并行会话在修的合并域回归）。②C3 任务槽——新档 `task_board.gd`（TaskBoard，RefCounted）：攻/防槽（KIND_ATTACK/DEFEND），战略侧只增删空槽（`sync_slots`，期望进攻槽数 = ceil(attack% × 原子单元数)，超额杀最新保最旧），执行侧匹配（`match_groups`：组织化编制作一组/散兵各一组，序位在前攻击槽数的组绑攻击槽、余量绑防守）；槽带目标/集结点/创建时刻，集结超时（攻 180s=CoH 3min，到点杀槽由 sync 重建）/目标超时（攻 30s=CoH 30s 重评分重定向+记脏重发号令；防 120s=CoH 2min 只刷数据不重发，维持 DEFEND 不重发口径零回归）。③C4 目标评分四因子——`score_target`/`pick_target`：threat（候选点半径内敌力/本方力，CoH 5.0）− avoid_clumps（无威胁时敌群聚集惩罚，CoH 10.0）− distance（距小队/距基地双计，CoH 5.0+5.0）+ inertia（与上次目标一致满分奖励，CoH 1.4，防振荡）；取数半径/归一尺度/容差全档案化；攻击槽目标 = 敌方军事单位位+敌质心 argmax，重评分以槽现目标为惯性参照（重定向只发生在 30s 超时，不逐拍振荡）。④C5 攻击百分比四规则——`recalculate_attack_percentage`：胜利目标危急（`vp_rule_enabled` **缺省关闭【提案/待定】**，开放问题#1 无 VP 等价物，钩子 `_apply_victory_objective_rule` 留位）→ 基地威胁封顶（threat_at_base = 锚点半径内敌力/初始基线×100，超 5 → pct ≤ max(100−threat, 5)/100）→ 难度基调（门禁未开 0；开门禁后 0.6+每分钟 0.01，封顶 0.70）→ 军力优势递增（归一化优势 (我−敌)/(我+敌) > 0.4 按增益抬升同受封顶；easy 增益 0、hardest 封顶 0.95——难度差异全在参数）。⑤咬合③内核替换——team_ai 姿势决策改由槽驱动（有攻击槽→ATTACK、槽清空→DEFEND，`slot_kernel_enabled` 默认开）；SWL 比例条件**转写为槽创建/维持门禁**（enter=ratio≥attack_enter、维持=ATTACK 态 ratio>attack_exit 滞回带——带内不塌槽姿态不抖，零回归关键）；SWL 决策函数（should_attack/should_defend 签名与节流接口）原样保留为退化路径（`slot_kernel_enabled=false` 时接手，既有单测语义兼容面）。⑥下令路径收敛（设计文档 §四）——组织化编制经 `issue_to_org`（同根一号令一轮内去重，整编=原子；TacticalOrders 新增 `get_org_root_for_squad` 代理查询，combat 不直引 organization；**独立 L1（无父级）按散兵口径走 issue**——单跳计划无传播语义且事件会误标玩家跳），散兵经 issue 现场直令；`issue_to_org` 增量 `extra_params` 默认参（ROUT evacuate 经组织链透传，向后兼容）；手动号令保护期：散兵逐队避让、编制任一成员保护期内整组避让。⑦新套件 `test_task_board` 15 用例锁全部六项（配置装载/槽同步与生命周期/四因子/pick_target 确定性/匹配/攻击百分比规则与封顶/槽驱动姿态与滞回带/退化路径/路径分流/整组避让/多小队槽号令）。⑧验收：check 干净；unit 批量 50/51（唯一失败 = 基线既有 road_walk）；run_all 失败集合与 pre-baseline 完全一致（31/13，无新增）。 |
| A3 | ✅ 完成 | 2d177826 / 9626a955 | **自主撤退/后撤（概率调制）**：①C6 中间带掷骰——`ai_controller._try_combat` 在既有强制溃逃链（is_routed/低士气+近身威胁）之后、狂暴判定之前挂 `_try_retreat_modulation`：血量(0.49)/士气(0.35)/周边友军溃逃阵亡比例(0.51) 三因子任一成立为候选，按难度档案 `retreat_chance` 概率掷骰触发 RETREAT——补「未到强制阈值但战况恶化」中间带；强制链优先且绕过节流；开关默认关=零回归。②双档语义——`behavior_retreat` 新增 `retreat_mode`：`withdraw` 撤退（回己方锚点/集结点，抵达带或超时收束，锚点查询不可用降级 fallback 不登记 departed）/缺省 `fallback` 后撤（既有远离敌语义原样）；evacuate 优先级不变。③参数档案化——behavior_profiles 追加 `retreat_mod_*` 9 键；personality.tres 四难度行追加 `retreat_chance`（CoH 真值 0.30/0.30/0.45/0.35，缺失/未知难度回落基线）；难度档名经 `bi.get_team_ai(faction).get_difficulty()` duck 查询降级 standard。④确定性——专用 RNG（默认种子 20260911 与 A1 同惯例），掷骰节流 2.5s（CoH 20 tick 同构）。⑤新套件 `test_ai_retreat_modulation` 11 用例 57 断言全绿（登记 batch_runner）；⑥验收：check 干净；unit 51/52（唯一失败基线既有 road_walk）；run_all 失败集合较基线零新增。 |
| A5 | ✅ 完成 | b77109b9 | **小队相位计划 v1**：①C8 相位机——新档 `squad_phase_plan.gd`（RefCounted 纯逻辑，宿主节拍驱动）：角色分派（Core=前列槽位优先/Scout=素质最高/双翼按锚朝向横向分侧，位置×素质双维【提案/待定】）+ 交替跃进（核心+侦察先行→随机等 2~4s→两翼跟进→等 2~3.5s→循环，CoH infantry-plan 真值等待窗，复用 11b 槽位落点，零掩护几何）+ 接敌反应（背敌反半平面/arrow_threat_time 被瞄准代理→既有 seek_cover，不新造掩体机制）+ 成员守卫（溃逃/找掩体/接战/玩家号令不打断，phase_order 标记防覆盖防重入）。②formation_system 追加宿主段（参数装载/号令通知/节拍驱动/槽位·锚点·素质查询出口/组织根解析）；tactical_orders 追加号令回查挂点（issue+issue_to_org 双路，ADVANCE/SPRINT 激活其余撤销）。③计划=数据 `config/ai/squad_phase_plan.tres`（category=ai，15 参数全档案化）；缺省关闭（phase_plan_enabled=false）零回归。④被压制代理用 arrow_threat_time，A6 落地后替换真实压制查询【提案/待定】。⑤新套件 `test_squad_phase_plan` 11 用例全绿（登记 batch_runner）；⑥验收：check 干净；unit 51/52（road_walk 既有）；失败集合较基线零新增。 |
| A4 | ✅ 完成 | 4910e4f5 | **default_behavior v2 效用打分**：①C7 三件套——新档 `utility_scorer.gd`：filter 资格过滤（六谓词 AND，未知谓词 fail-closed）/ demand ±分（CoH s_demand_increment=50 真值）/ target 五模式（未知兜底防守语义）；demand_variance 单旋钮方差扰动（收敛红线·咬合④），RNG 种子=hash(base_seed+squad_id) 按小队错峰防齐套且确定性可复现。②消费组织 default_behavior——team_ai 仅追加字段/装配/钩子（`_issue_stance_orders` 尾接管无显式号令防守兜底小队；GARRISON/ROUT/攻击槽绑定/散兵全豁免）；组织数据只读 duck 消费禁改存储格式。③参数——personality.tres global 行追加 default_behavior_v2_enabled=false（零回归门）+demand_increment=50。④新套件 `test_utility_scorer` 12 用例 186 断言全绿（登记 batch_runner）。⑤验收：check 干净；全量失败集合 23→15 post⊆pre 无新增；unit 52/53（road_walk 既有）。⑥schema 属提案【提案/待定】；生产未接线（无组织写入方，激活需后续批次）；已上报既有怪癖：TeamAi.setup overrides merge overwrite=false 与文档承诺不符（本批仅 A4 两键兑现，既有键待统一修） |
| A6 | ✅ 完成 | defb3fe8 | **压制=定时锁死**：①StatusEffects 新增 SUPPRESSED——触发源=受击门槛（弓手命中≥4 / 近战重击≥12 对齐 HIT_BIG_DAMAGE_THRESHOLD，格挡残余 0.45~3 不压制="挡住的箭不压制"）；豁免=溃逃/死亡/玩家附身/兵种级 suppression_immune。②决策链优先级=强制溃逃链>压制禁令>命令覆盖>自主决策（禁令是"不敢动"不是"不能逃"；pinned isInterruptablePlan=false 直译，玩家号令**挂起不清除**压制结束自动续行）；压制期强制短行为=原地停滞（受击反馈/推挤走物理层不受禁令）。③behavior_attack 兜底两拍在途行为；squad_phase_plan 真实压制替换 A5 arrow_threat_time 代理（未压制成员保留轻量窗口）。④士气联动=压制期 0.5s tick lose_morale 2.0（只损士气可推向溃逃，待校准）。⑤参数 behavior_profiles suppression_* 六键（时长 4.5s=CoH 7.5s×节拍比 0.6 校准），总开关默认关=零回归。⑥新套件 test_suppression 13 用例 57 断言全绿（登记 batch_runner）。⑦验收：check 干净；unit 54/55（road_walk 既有）；melee_combat 波动经 9 次采样证实为负载敏感既有抖动非新增。遗留：数值全为推断待校准；箭矢近失触发未接入（arrow_projectile 文件面外，通用入口已预留） |
| UI-W1 观测接线（界面方案§二） | ✅ 完成 | 63e6dee1 / 4108bdb3 / 82296b5c | **TeamAi 战场默认开落地+观测面接通**：①启用链接线——battle_director.start_battle_at 帧末对攻守双方 enable_team_ai（get_team_ai 幂等守卫不吞据点战 overrides），`team_ai_enabled` 默认 true 进 personality.tres global 行（观察场可显式配 false 对照）；②TeamAi 姿态 HUD（modules/combat/ui/ 场景骨架，HudOverlay 槽）——姿态徽标四色+reason+attack%+槽占用+开战倒计时，信号驱动+0.25s 查询兜底，F3 drawer "team_ai_hud" 显隐持久化；③DebugInfoPanel 悬停增强（行为名/机制参数摘要/相位角色/撤退调制快照，全 duck 探测缺查跳行）；④接口补齐三项——squad_phase_plan 相位/角色两信号、team_ai.get_attack_percentage() 缓存版、ai_controller.get_retreat_mod_state()，各配单测。⑤验收：check 干净；run_all post 44 全过/0 失败；unit 55/55。⑥顺手修复两测试基建 bug——test_ai_param_panel 此前因类型解析错误被批量运行器静默吞掉（14 断言首次真实入账）、_restore_rows 污染 reload 幂等。遗留：HUD 无 zone 表位（自设右上锚，冲突时改 hud_zone_layout.gd）；批量运行器"加载失败静默吞"盲区待单列核查 |
| WB1（W1 softmax 选优） | ✅ 完成 | 8d24db15 | **效用选优改 softmax 轮盘**：①`utility_scorer.pick_behavior` 由 argmax 升级为 softmax 轮盘赌（WorldBox UBDS.cs:242-263 真值：`chance=e^w`、`pick=rand×Σ` 累加命中，无 argmax——高权重不再垄断，低权重仍有胜出概率）；②量纲归一 + 数值稳定——CoH demand 的 ±50 分域与 WorldBox 的 0.05~5 权重域量纲不同，新增 `softmax_weight_scale`（=1/demand_increment=0.02）归一、`softmax_temperature` 调锐度，份额用 `exp(w−max)` 计算（`demand_increment` 抬到 5000 亦无 INF/NaN）；③`weight_calculate` 委托（W1 M7）——候选 `weight`/`weight_rules` 做状态调制，"饿时工作权重下降"写成数据而非 if 链；④launch 失败入冷却（W1 M6）——`is_on_cooldown`/`note_launched`/`note_launch_failure` + `pick_behavior_and_commit`（target 解析非有限=发射失败即记冷却，防对昂贵条件反复探测）；⑤档案 5 键进 personality.tres global 行，`softmax_enabled=false` 保留 argmax 退化路径（与升级前逐位一致，用独立重实现对照锁）；⑥消费接线——team_ai 补挂 5 键进 `_p`（否则档案调参静默失效）+ 号令路径改走提交版入口（候选无 cooldown 声明时零行为变化）；⑦`test_utility_scorer` 12→23 用例 368 断言（份额和=1 / 采样胜率与份额一致 / 温度分布 / 权重规则 / 冷却窗 / 失败冷却 / 退化对照）。遗留：效用打分机制的生产门 `default_behavior_v2_enabled` 仍缺省关，激活属校准轮 |
| WB2（W2 冷却错峰） | ✅ 完成 | 3a1ddfc3 | **决策冷却错峰假偏移**：①决策时钟改绝对世界时刻（`_next_decision_at` 取代 `_decision_timer` 累加器，读档零成本）；时钟可注入（`clock_override`），默认用 delta 累加的内部世界时钟——保暂停/hitstop 下与旧累加器等价（改用引擎实时钟会在暂停期照走）；②出生/成批生成假偏移（W2 主机制，M4 真值 `rand(0,0.5cd)`）——装配时预置"上次触发发生在随机过去时刻"，兵营爆兵不再全员同步决策；档案 `spawn_jitter_enabled`（默认关）/`spawn_jitter_ratio`(0.5)；③域级探测失败入短冷却（M6）——`probe_fail_cooldown_enabled`（默认关）+ `job_scan_interval`（选敌域复用既有 `acquire_interval`）；④`get_decision_timing_state` 只读出口；⑤新套件 `test_ai_spawn_jitter` 9 用例 87 断言（关=旧累加器 600 帧触发帧号对照零偏差 / 开=偏移界内且 20 单位离散 / 同种子确定异种子错峰 / 时钟跳变只触发一拍不连爆 / 域级独立错峰 / DUE_EPSILON 刀锋条件）；⑥验收：check 干净；unit 批量 56/56；run_all 44/44。遗留：读档还原（`apply_spawn_jitter` 幂等入口已备，AI 时钟族无序列化）；`behavior_attack`/`behavior_heal` 的域内倒计时未统一为绝对时刻（文件面外，另开批次） |
| WB6（W6 评分留痕） | ✅ 完成 | 4028d246 | **决策依据留痕（目标评分可解释）**：①`task_board.score_target_detail` 四因子逐项明细（threat/avoid_clumps/distance/inertia + total + 距离双来源分解），`score_target` 改为消费同一明细的 `total`（单点真相，物理上不可能漂移）——WorldBox KingdomOpinion 的 results 字典同构；②`pick_target` 顺带写最近一次留痕快照，只读 `get_last_score_trace()`（chosen/candidates/fallback/at，深拷贝防污染）+ 纯函数 `format_score_detail`；③debug_info_panel 悬停追加一行「目标评分: 威胁 +3.0 · 聚集 +0.0 · 距离 -4.2 · 惯性 +1.4 = +0.2」（全链 duck 探测，缺查跳行）；④纯留痕零行为变化（回归锁用例断言固定 fixture 的选择与 total 逐位不变）；⑤`test_task_board` 15→21 用例 136 断言，既有断言一字未改 |
| 测试基建加固（开闸前置） | ✅ 完成 | （本批提交见 git log） | **批量运行器两处静默漏测盲区修复 + 机制开关总表**：①零用例盲区——`TestRunner.all_passed()` 对空 `_results` 恒返 true，"一个用例都没跑"的套件会被记成绿灯；改为零用例判失败，并让 TestRunner 在 run/run_async 收尾经 Engine meta 发布用例数/断言数（`META_LAST_CASES`/`META_LAST_ASSERTS`），批量运行器逐套件打印并据此判零用例；②清单漏登记盲区——套件文件躺在 `tests/unit/` 却没登记进 `UNIT_SCRIPTS` 则永不运行且无红灯，新增盘上清单自检（目录枚举不可用时只提示不误判）；③守卫经一次性探针实测：零用例=false / 单用例=true 且计数 1/1 / 零断言=false（既有守卫）；④加固后 unit 批量 56/56，清单自检「盘上 56 / 清单 56 / 未登记 0」；⑤设计文档新增 §七「机制开关总表」——18 个机制开关的层/默认/开闸后可观测差异/观察入口 + 四条开闸纪律，校准轮按表推进 |
| A7 | ⬜ 挂起 | — | 待经济域立项 |
| A8+ | ⬜ 挂起 | — | 待创始人裁决 |

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
| W 系列批次归属 | 批次号对齐机制号（WB<n> = W<n>）；WB1/WB2/WB6 归 AI 线已实施，WB4（行为机重构）留 AI 线待立项，WB3/WB9 分流 30fps 线、WB5 组织线、WB7/WB8 出征线、WB10 town-life/inventory 线——各随所在线立项，不在 AI 线内实施（唯一真相源 = 设计文档 §2.4） |
| WB1 选择规则开关 | `softmax_enabled` 默认 true（沿用 A2 `slot_kernel_enabled` 先例：新内核默认开、旧路径留开关做退化面与回退闸）；CoH 分域→WorldBox 权重域靠 `softmax_weight_scale` 归一 + `exp(w−max)` 稳态份额实现，不靠调小 demand_increment |
| WB2 时钟口径 | 世界时刻 = delta 累加的**内部世界时钟**（非引擎实时钟）——暂停/hitstop 下冻结，保"关开关时与旧累加器逐位等价"；实时钟会在暂停期照走，恢复瞬间多触发一拍 |
| WB6 留痕口径 | 留痕常开、不设开关（避免开关前后两套路径成漂移温床）；纯留痕不改评分数值与选择（`score_target` 与 `score_target_detail` 单点真相 + 回归锁用例坐实），trace 返回深拷贝防消费端污染内核 |
| 验收方式（裁决 2026-09-13） | 创始人**不再实机验收**；机制开闸由 AI 线按设计文档 §七 清单**逐层开闸并留档**——每开一层/一组跑一轮零回归，把可观测指标（触发次数/分布/帧率）写成报告，创始人抽空看报告，不再要求实机试玩 |
| 界面批次编号（约定） | 本任务界面批次一律 `UI-W<n>` 前缀（`UI-W1` 观测接线 / `UI-W2` 组织界面 MVP / `UI-W3` 指挥链可视化 / `UI-W4` 逐层深化）；WorldBox 机制批次用 `W1~W10`（别称 `WB<n>`）——裸用 `W1` 会两边撞号 |
| 权威值择班（裁决 2026-09-13） | A9 R4 原只做「评分内核 + margin 滞回」、自主跳槽行为不做（怕玩家预期风险）；现裁决**把自主跳槽行为一并实装**——限位与冷却必须齐备（班长不被抽走/溃逃与接战与玩家保护期内不换班/换班后有冷却窗），并出玩家预期风险评估 |
| 开闸前置 | 「往档案加键但不生效」曾真实发生过（personality 新键未补挂进 TeamAi `_p`）——新增档案键必须同时登记：设计文档 §七 开关总表 + 消费侧装载路径（`get_profile` 白名单补挂或 `BehaviorProfiles` 行合并） |
