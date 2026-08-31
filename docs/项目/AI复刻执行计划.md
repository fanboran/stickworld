# 兵种 AI 复刻执行计划（2/5/6/7 高优先级批次）

> 2026-08-31 定稿。本批次工作的**唯一计划文档**，新对话从这里接续。
> 配套状态记录：[`待办事项.md`](待办事项.md)（1~8 轮已完成项，按轮次倒序）。
> 工作方式：**全程 Vibe Coding**，估算口径 = 会话轮次（非人天），见 §5。

---

## 一、范围与优先级（用户已拍板）

| 序 | 项 | 优先级 | 估算（轮次） | 状态 |
|---|---|---|---|---|
| 6 | 编队动态跟队 | 高 | 2 | **已完成待复验**（2026-09-01：锚定跟队 + 前队接敌后队推进支援） |
| 5 | 盾姿态分层动画 | 高 | 1.5 | **已完成待复验**（2026-09-01：端盾行军/待命/三连刺 + 持盾减速 0.8×） |
| 9 | 观察场首轮反馈缺陷清单（§二.9：弹道落地/法师爆炸/射速/卡死复验等） | 高 | 2~3 | 大半已修（9a/b/c/g/i/l/m/n ✅），余 9d/9e/9f/9h/9j/9k |
| 10 | 物品栏系统（BG3/MC 式：格子 UI/装备槽/拾取；主控随时换武器——热键核心已落地） | 中高 | 2~3 | 核心热键 ✅，UI 待开工 |
| 2 | 数值校准（对表解包/wiki；并入 9d 射速） | 高 | 2 | 待开工 |
| 7c | TeamAi 姿态机 | 高 | 1.5~2 | 待开工 |
| 7b | 祭司 Meric 兵种+治疗（扩 9e 爆炸特效） | 高 | 1.5 | 待开工 |
| 7a | 巨人兵种+抓掷 | 高（风险项） | 2.5~3 | 待开工 |
| — | 矛兵一次性掷矛（`EnableASingleSpearThrow`，复用箭矢投射物） | 中 | 0.5 | 待开工 |
| 4 | 法术——**只要一部分**（建议 ArrowVolley 箭雨 + HealSpell 群疗，各 0.5~1 轮） | 中 | 1~2 | 用户确认范围后做 |
| 3 | 阵营皮肤——**不复制素材**，学原版组织方式自绘；代码侧皮肤槽系统 1~2 轮，美术工时另计 | 中 | — | 排后 |
| 1 | 音效接线（事件真值已导出，纯接线 0.5~1 轮） | 用户放延后 | — | 可随时插队 |

**合计约 12.5~15.5 轮**（不含 3/4）。执行顺序 **9（缺陷清单）→ 11a → 11b → 2 → 7c(11c) → 7b → 7a**。

> **🔻 下一上下文开工指引（2026-09-01 收尾）**：从 **11a 基类补全簇** 开工（方案见 §六，含首个消费者 9p 弓手 y 对齐出手）；随后 9q（小鬼脚对齐，~0.3 轮）→ 11b → 2 → 7c(11c) → 7b → 7a。开工前先读本文件 §二.9 缺陷清单与 §六 审计表，每轮改完更新 §六 覆盖数。

---

## 二、逐项实施拆解

### 6. 编队动态跟队（2 轮）——✅ 2026-09-01 已实现
- **目标**：前队移动时后队自动锚定跟随（`MoveInFormationBehindAnotherFormation` + `GapBetweenFormationGroups` 直译）。
- **改动点**：
  - [formation_system.gd](../stick-world/modules/combat/scripts/command/formation_system.gd)：加 `follow_squad_id`/`gap` 锚定字段；`_decide_squad_targets`（0.5s tick）里后队落点 = 前队质心 − 行进方向 × gap；前队全灭 → 解除锚定转自主决策；**前队接敌 → 后队越过 gap 推进支援（不带 hold）**（首轮验收 9b 补丁：否则后队钉在 gap 处永不接战，观感"全员卡死"）
  - [battle_arena.gd](../stick-world/tests/dev/battle_arena.gd) 三班接线：矛班=先锋（ADVANCE_ALL 到中线），剑班锚矛班 gap≈150，火力班锚剑班
  - 配套：behavior_move `hold_on_arrive` 到位驻留（压制无令擅自冲锋）；号令带 `follow_order` 来源标记（不覆盖玩家号令）
- **验收**：观察场三班保持纵深推进；前队接敌后后队推进支援不钉死；formation 相关测试套件回归（`tests/run_all.sh -Match formation`）。

### 5. 盾姿态分层动画（1.5 轮）——✅ 2026-09-01 已实现
- **已落地**：spine_import ANIM_MAP 增 `block_walk/block_crouch/block_attack_1~3`（Spearton-Block-Walk/Crouch/Attack1/2/3，增量导入 5/5）；behavior_profiles SPEAR 增持盾动画组+`block_move_mult 0.8`（持盾减速）；visual_controller 盾姿态分层（`set_block_stance` + `play_attack(blocking)` 随机抽三连刺；set_state_animation 换状态节点动画不增节点，事件/完成信号按 state 名派发，命中帧订阅不受影响）；WeaponMount.set_blocking 变化时回调实体转发。持盾矛兵=端盾行军/待命蹲姿/三连刺，行军减速 0.85×0.8。
- **验收**：矛兵行军端盾走盾步、攻击播三连刺、举盾被击走 Block-Hit 池（已就位）。

### 9. 观察场首轮反馈缺陷清单（2026-09-01 用户验收提出）

| 项 | 根因 | 修法 | 状态 |
|---|---|---|---|
| 9a 暂停只停位移、肢体还动 | TimeManager 是自研标志位，只门禁了实体 _physics_process；AnimationPlayer 在 idle 帧继续推进；箭矢/武器挂载（冷却+放箭计时）也没门禁 | 实体暂停分支首次进暂停 → rig `set_anim_paused(true)`（speed_scale=0）恢复还原；arrow_projectile / weapon_mount._physics_process 顶部 TimeManager 门禁；batch_runner 每套件前重置 TimeManager（battle_started 自动暂停残留污染） | ✅ 已修 |
| 9b 打一半后队全员卡死 | 编队跟队初版缺口：前队接敌缠斗时，后队锚定在 gap 处 + hold_on_arrive 驻留永不接战（剑班距战线 150 > 剑程 80） | `_update_squad_follow` 前队接敌（任一成员射程内有敌）→ 后队锚点改为前队质心、不带 hold 推进支援，到位/接敌即交还战斗决策 | ✅ 已修 |
| 9c 弓箭贴地小半圆、落在斜前方很近的地面 | `arrow_projectile.GROUND_DROP=500`：插地判定 = 低于**出射点屏幕 y** 500px——纵深战场里"下 500px"是画面纵深而非地平线，观感=弧线绕 1/4 就插进前线附近地面 | ✅ 已修：`_fire_arrow` 传解算飞行时间 t + 瞄准点地面线（Collider 中心下 65px）——箭越过目标后落在目标脚下地面，miss 沿弹道自然插进敌阵（旧调用退回 GROUND_DROP 路径兼容） | ✅ 已修 |
| 9d 弓手射速不科学 | cooldown 1.35s（剑对齐值）+ aim_hold 0.25~0.9s + 攻击动画时长无约束关系，未对 SWL ArcherAi 攻击间隔真值 | 并入 **2 数值校准**：对表 wiki/dump 弓手攻速；加检查项"冷却 ≥ 攻击动画时长"（对齐 Swordwrath 冷却注释同款约束） | 待开工（并入 2） |
| 9e 法师没有爆炸效果 | `_cast_magic` 延迟直结：无爆炸特效、无 AOE——**dump 真值**：Magikill 类有 `CastStun/StunOpponents/unitsToDamage/STUN_RANGE/stunDamage` 字段，原版法术=施法前摇+命中点**范围击晕+伤害**（无弹道投射物，立项时的"魔法弹"设想不保真，已修正） | ✅ 已修：命中点 `spell_aoe_radius`（STAFF 90）内敌人受 50% SPLASH 伤害+同步击晕 0.5s（放倒一片）；MAGIC_BLAST 紫白星芒爆炸粒子（FxPool 池化）；半径挂档案 | ✅ 已修 |
| 9f 矛兵攻击不是戳刺 | 无盾矛攻只有 `Spearton-Attack1`（横扫观感）；持盾三连刺已随 5 落地 | 观察场复验 Block-AttackN 观感；无盾矛攻候选 `Spearton-Attack2/3`（解包 21 动画内挑选），增量导入对比 | 待开工（并入 5 复验） |
| 9g 反向拉弓 | 弓手风筝撤退时实体朝向随移动方向翻转 → 拉弓动画背对目标；行为层开火前无面向修正 | 实体新增 `face_towards(pos)`；behavior_attack 风筝还击/射程内开火前 `_face_target()` | ✅ 已修 |
| 9h 卡死复验 | 9b 修掉"后队钉死"主嫌疑后若观察场仍现全员卡死 | 复现优先：观察场加调试 HUD（逐单位 行为/号令/眩晕/溃逃/锚定 状态，热键开关）定位后立专项 | 复验后定 |
| 9i 怯战者后排站死（第二轮反馈） | ①士气恢复只在"非战斗"走 → 战斗不结束怯战者永不恢复；②溃逃方向把单位推到可走带边缘 → 朝带外逃=贴墙站死 | ①战斗中但 ≥3s 未受击 → 士气半速恢复（`_apply_rest_morale_recovery` 扩展）；②retreat 方向夹紧可走带，贴边无路可退即 finish 交还决策 | ✅ 本轮已修（后续增强见 9i+） |
| 9i+ 溃逃行为保真度增强 | 原版怯战者：逃跑一定距离后回头再战/保持招架/沿敌人垂直位游走；前排怯战试探性接敌；少量人时包抄迂回 | 并入 7c TeamAi 姿态机批次一起做（姿态机天然覆盖"何时再战"） | 待开工（并入 7c） |
| 9j 脱战回血（MOBA 延迟血条） | 原版低血脱战会缓慢回血；本项目无 HP 恢复机制，血条也无"渐补"表现 | 脱战 5s 后开始回、上限 25% max_hp；血条加绿色"延迟残影"段先变绿再补色（对齐格斗/MOBA 惯例，复用 trail 机制）；血条常量+HealthComponent.regen 各加档案开关 | 待开工 |
| 9k 群体避让 + 空挥保真度 | ①无 RTS 式让路：满血士兵被避战队友堵死；②对空气/队友做攻击动作：近战无友军遮挡判定，隔着队友也出刀（攻击名额 3 人上限保真需复验）；③避战者扎堆挡路 | ①移动时对"同向低速友军"加绕行分量（boids avoid 前置位）；②近战出手前做友军遮挡射线（首位友军挡刀则绕位/等位不空挥）；③攻击名额对表 dump `NumberOfUnitsThatCanHit` 语义 | 待开工 |
| 9l 法师召唤无上限 → 人口爆炸 | `_update_summon` 每 12s 无条件召 2 只（只要敌在 600 内），无存活数封顶——长仗人口爆炸；且护卫满血只见小圆点（血条受过伤才展开）→"没血条的人"挡路 | ✅ 召唤封顶：按施法者跟踪存活护卫数 ≤ summon_count（对齐 dump `Magikill.minions: List<Unit>` + `IsAtMaxMinions()` + `MAX_SPAWNED_MINIONS`），阵亡才补召；血条圆点 4.5→6.0 | ✅ 已修 |
| 9m 尸体永存堆满战场 | 尸体只禁碰撞（0.9s），节点永存——加召唤怪死得快，战场越打越挤 | ✅ 尸体淡出：碰撞禁用后停留 4s → 1.2s 淡入地里 → 移除（SWL fadeOutOver 语义）；battle_sim 采样数组同步剔除 freed 引用（类型化迭代遇 freed 会中断统计） | ✅ 已修 |
| 9n 召唤护卫语义对账（第三轮反馈） | ①出生位置错做在法师两侧——dump `SpawnMinion()` 协程 + `SummonGroundScorch` 焦痕语义=**施法方向前方地面冒出**；②体型：原版 `Minion : Unit` 是**独立单位类**（类体仅 UpdateDrag override，体型/血量全在 prefab 数据配置，代码层无 scale 逻辑）——本项目无 Minion 独立 prefab 管线，以 `body_scale` 数据字段等价实现（0.65 为近似值，真值在 prefab 序列化数据中、签名 dump 不可见，待实测校准）；血量 40 已有（`summon_hp` 档案） | ✅ 出生位置=面朝方向（facing ±x）正前方 72px + 纵深 y 排开（第四轮修正：此前用指向目标的二维向量，目标 y 漂移时出生点跑纵深处="正上方"观感——横版语义"前"= facing）；body_scale 挂档案 `summon_body_scale`；[复刻缺口总账](../审计/总账/翻译缺口总账.md) 挂"Minion prefab 数值真值对账" | ✅ 已修（数值待校准） |
| 9o 主控走 A（第四轮反馈） | 玩家主控攻击时移动被锁死（`_handle_player_input` 攻击动画期间 dir=0）——原版主控可边撤退边走 A；且 run/walk 每帧覆盖攻击动画 → 拉弓被打断、命中帧退化宽限兜底 | ✅ 攻击锁死仅限近战（弓/杖不锁）；acceleration/deceleration 加攻击动画保护（attacking 时不切移动动画，播完由 rig finished 回切）；主控攻速 ×1.3（dump Unit 真值 `USER_CONTROLLED_ATTACK_SPEED=1.3`，顺带发现 `healthRegenPerSecondWhenUserControlled`——主控自然回血为原版机制，并入 9j）；AI kite 走 A 同步受益动画保护 | ✅ 已修 |
| 9p 弓手朝纵深正上目标照射（第六轮反馈） | 目标 y 偏移大（观感"垂直向上射箭"）时弓手照出手——横轴观感等于故意射空。原版语义：出手前应 y 走位，保证目标接近**水平持平**才射；保持距离时以**水平距离**为主导 | `CanAttack/ShouldAim` 加 \|Δy\| 阈值判定（超阈值先 y 走位不出手）——是 11a y 对齐簇的第一个消费者，合并实施 | 待开工（并入 11a） |
| 9q 小鬼垂直坐标偏上（第六轮反馈） | `body_scale` 缩小 rig 但 **foot_offset/脚部对齐未随缩放**——小人脚悬在基准线上方（0.65 缩放时悬空 ≈0.35×脚距）+ 纵深排开 ±22 叠加 = "比法师靠上"观感 | `_apply_scale`/foot_offset 计算乘 body_scale（body_scale 变化时重算脚对齐）；出生 y 以法师**脚部 y** 为基准 | 待开工（并入 9n，~0.3 轮） |
| 9r 矛士姿势仍不对（第六轮反馈） | 持矛站姿 Spearton-Stand1 观感与原版不符 | 增量导入候选 `Spearton-Stand2 / Spearton-Into-Stand1/2` 对比（解包 21 动画内），与 9f 戳刺一起验收 | 待开工（并入 9f） |
| 9s 剑士接近战对空气挥刀（第六轮反馈，细化 9k） | 双方正在靠近时剑士就播攻击动作——候选根因：①接近中目标移速超过二次确认窗口（动画命中帧时目标已出 1.25× 射程 → 挥空）；②can_attack 可打断尾段提前出手 | 并入 9k 统一修：出手时机门槛（目标速度×命中帧时长预判）+ 友军遮挡射线 + 挥空率进 battle_sim 统计 | 待开工（并入 9k） |

### 10. 物品栏系统（BG3/MC 式，用户第四轮明确方向）

- **目标**：主控单位随时换武器/装备（"各种武器都可以用"），后续扩格子背包 + 拾取 + 装备槽。
- **已落地（最小可用核心）**：主控热键 1~5 换武器（1剑 2矛 3弓 4镐 5杖，对齐 WeaponMount.WeaponType）——
  `weapon_type` setter 已驱动 重挂武器模型/持械站姿/攻击动画与射程/命中帧重解析/block_move_mult 刷新。
- **待开工**：
  - 物品数据结构（ItemDef：类型/武器参数覆盖/堆叠/图标）——武器参数走数据驱动而非 WeaponMount @export 硬编码（并入 2 数值校准的数据化）
  - 背包 UI（格子布局/拖拽/装备槽：主手+副手盾+消耗品），StickKit 组件复用
  - 拾取/掉落（战场尸体掉武器 → 拾取入库）
  - 换武器动作（原版换武器有小动作+冷却；当前瞬时切换，平衡期再加）
- **验收**：主控按 1~5 即时换武器（持械站姿/攻击方式/射程全变）；背包 UI 开合/拖拽装备生效；battle_sim 无回归。

### 2. 数值校准（2 轮）
- **数据源**：①SWL wiki（全单位 HP/伤害/价格/冷却公开值）②dump 字段语义核对（`F:\VSCode\game-2-aux\external\decompiled\legacy\dump\`、`legend\dump\`）③存疑项录屏实测抽查。
- **改动点**：数值表进 `config/units/stickmen.tres`（或扩展 BalanceConfig）；仿真平衡回归——**镜像局应接近五五开、10v10 时长量级合理**。
- **风险**：wiki 与实测可能有出入 → 以仿真表现仲裁，宁可贴近原版观感不迷信单一来源。

### 7c. TeamAi 姿态机（1.5~2 轮）
- **目标**：双方 TeamAi 自动切换 attack/defend 姿态（legacy `TeamAi.StanceUpdate` 直译）：兵力比 + 侵略参数决定压上/回防。
- **改动点**：新 TeamAi 决策层（挂 BattleInstance 或 battle_ai_director 旁）；滞回防抖；**与 TacticalOrders 优先级调和：玩家手动号令 > 姿态自动切换**（自动姿态只在无号令时生效）。
- **验收**：仿真里双方出现"压上→胶着→回防"节奏，不出现全线站桩。

### 7b. 祭司 Meric（1.5 轮）
- **资产**：`[meric].txt` 骨架 5 动画全齐（Heal1/Heal2/Stand/Walk/Death）。
- **改动点**：导入映射 + 兵种数据（后排站位、无近战）+ 治疗 AI（选血量最低友军、Heal1/2 随机、持续回复走 StatusEffects 的 HealOverTime 扩展或直接 heal）。
- **验收**：观察场加 1-2 祭司，前排存活时长显著延长。

### 7a. 巨人+抓掷（2.5~3 轮，风险项）
- **资产**：`[giant].txt` 18 动画全齐（含 `Giant-Grabbng-Spearton` 抓掷专用动画）。
- **改动点**：大比例渲染（骨架缩放或 scale）+ 单位数据（超高 HP/慢速/AOE 挥击已有字段）+ **抓掷状态机**（近身抓取判定→举起→抛物投掷→被掷单位物理弹射+落地 AOE）。
- **风险**：三处易出运行时 bug（抓取目标选择、被掷单位物理接管、落地结算）——每处先 grep 现有 API 再调用。

---

## 六、复刻覆盖率审计（2026-09-01，对账 `legacy_AI_classes.cs`）

> 方法：以 dump 原版 AI 层全部类签名为基准（`Ai` 基类 55 行为函数 + 11 兵种 Ai 类 61 函数 + `TeamAi` 19 + `Formation` 7 ≈ **133 个行为函数**），逐函数映射本项目实现（`modules/units/scripts/ai/` 99 函数 + `command/` 53 函数，跨类结构不同按**语义**对账）。状态：✅ 语义对齐 / ◐ 机制在但偏差 / ❌ 未复刻。

### 覆盖率总览

| 层 | 原版函数 | ✅ | ◐ | ❌ | 严格覆盖 | 含近似 |
|---|---|---|---|---|---|---|
| `Ai` 基类 | 55 | 24 | 15 | 16 | 44% | 71% |
| ArcherAi | 15 | 8 | 2 | 5 | 53% | 67% |
| SpeartonAi | 5 | 4 | 0 | 1 | 80% | 80% |
| MagikillAi | 5 | 5 | 0 | 0 | 100% | 100% |
| SwordwrathAi | 1 | 1 | 0 | 0 | 100% | 100% |
| MinerAi | 6 | 3 | 1 | 2 | 50% | 67% |
| MericAi（7b） | 3 | 0 | 0 | 3 | 0% | 0% |
| GiantAi（7a） | 2 | 0 | 0 | 2 | 0% | 0% |
| TeamAi（7c） | 19 | 0 | 0 | 19 | 0% | 0% |
| ZombieAi | 13 | 0 | 0 | 13 | 0% | 0% |
| StatueAi/BarricadeAi | 2 | 0 | 0 | 2 | 0% | 0% |
| Formation | 7 | 0 | 2 | 5 | 0% | 29% |
| **合计** | **133** | **45** | **20** | **68** | **34%** | **49%** |

### 逐簇对账（Ai 基类 55 函数）

| 簇 | 原版函数 | 本项目对应 | 状态 |
|---|---|---|---|
| 主循环 | Update | ai_controller._make_decision + behavior_*.update（结构不同：状态机 vs 多分支） | ◐ |
| 编队跟队 | MoveInFormationBehindAnotherFormation / MoveInFormationBehindFollowUnit / RunToFormationPosition / DetermineFormationTargetPosition / GapBetweenFormationGroups | formation_system._update_squad_follow / get_squad_dest / follow_gap | ✅ |
| 编队稳定 | FormationPositionIsStable / UpdateCatchingUpToFormation / IsInTheFormation | （无：追赶状态/落点稳定检测缺失） | ❌ |
| 编队结构 | Formation 类 7 函数（UNITS_PER_COLUMN/ROW_GAP/formationOrder/FilterDownARandomRow/ShouldSwitchUnitsInFormation/Add/Remove） | （小队制替代，无 row/col 阵列） | ❌ |
| 举盾 | UpdateBlock / UpdateBlockWhenInFormation | behavior_move._update_formation_block + attack._update_arrow_threat_block | ✅ |
| 接近/走 A | RunToTarget / ShouldRunToTarget / IsTargetReallyClose / RunTowardsEnemyPosition / MoveToMiddleOfTheMap / MoveToWaypoint / SetWaypoint / AtWaypoint | behavior_attack 接近段 + 号令 move + engage_in_range（IsTargetReallyClose 无独立阈值） | ◐ |
| y 走位 | personalityControlledY / AdjustGoalYToMoveTowardsTarget / DetermineYComponentWhenRunningToTarget / CanAdjustYPositionOnly / ShouldAdjustYPositionTowardsTarget / CanWalkTowardsTarget / IsCloseEnoughToAdjustYTowardsTarget | behavior_attack._apply_y_drift（个性漂移在；"朝目标 y 对齐"的 6 函数语义只有近似） | ◐ |
| 绕障 | RestrictTargetSpotWhenBehindWall / AdjustXSoWeDontRunToBehindWall / AdjustPositionOffStatue / IsMovingPastStatue / DetermineGoalYToAvoidStatue | （无城墙/雕像玩法；掩体仅 seek_cover） | ❌（玩法依赖） |
| 预判 | PredictedPosition | 箭矢 ARROW_LEAD_FACTOR 移动预判 | ◐ |
| 目标 | UpdateTarget / IsValidForForwardOnlyTarget / OnlyTargetsUnitsForward / InAgroRange / CanAttack / AiDistance | TargetFinder.find_target + 射程/集火（前向限制/威胁分级部分缺失） | ◐ |
| 攻击 | Attack / AttackFromRange / GetTargetAttackSpot | behavior_attack 攻击段 + 远程延迟发射 + 攻击槽位外圈 | ✅ |
| 溃逃 | NeedsToRunAway / IsUnderThreat | ai_controller 士气分支 + behavior_retreat（IsUnderThreat 无独立真值） | ◐ |
| 面向 | FaceDirection / SetNaturalFacingDirection / Face | _apply_movement 朝向 + face_towards（AI 统一 Face 调用缺失） | ◐ |
| 主控 | IsBeingUserControlledByPro | possessed + USER_CONTROLLED_ATTACK_SPEED 1.3 | ✅ |
| 杂项 | DetermineXRunPower / IsPositionBacktracking / AlwaysAttacks / ShouldStand* 3 虚函数 | （散布在档案/未做） | ❌ |

### 兵种 Ai 类缺口（新增批次方案）

| 类 | 缺失函数 | 复刻方案 | 批次 |
|---|---|---|---|
| ArcherAi | MissingArrowsTolerance / CastleArcherWallPositionX / GetCastleArcherXAttackPosition / RunToTargetCastleArcher / NextGaussian(min,max) 三参版 | 前者并入 2 数值校准（脱靶容忍度=弹药浪费阈值）；CastleArcher 簇依赖城堡玩法挂总账缓 | 11d |
| SpeartonAi | EnableASingleSpearThrow | 掷矛一次性开关（原计划"矛兵掷矛"0.5 轮不变） | 既有 |
| SwordwrathAi | —（Update=冲脸档案已对齐） | — | ✅ |
| MinerAi | IsBarricadeBlocking / IsBeingAttackedByAnotherMiner | 路障/矿工互殴依赖对应玩法，挂总账缓 | 11e |
| **TeamAi 全类** | StanceUpdate / BalanceOfPowers / BalanceOfPowersRatio / ShouldAttack / ShouldDefend / ShouldGarrison / Garrison 系 5 函数 / BuildUnitsUpdate / BarricadeExists 等 19 函数 | **逐函数直译**（不是姿态机概念近似）：BalanceOfPowers 真值公式、Garrison 驻防状态机、BuildUnitsUpdate 造兵（依赖经济系统联动） | 11c（扩 7c → 2.5 轮） |
| ZombieAi | Pounce 扑击系 4 函数 / DefendModeForZombies / UpdateKaiSummon 等 13 函数 | 玩法依赖（感染/Kai 召唤），挂总账缓 | 11e |
| MericAi / GiantAi | 全类 | 原有 7b/7a 批次不变 | 7b/7a |

### 结论与立项

- **AI 行为层真实覆盖率 ≈ 34%（严格）/ 49%（含近似）**——"打补丁"观感的根源：缺失集中在**整类**（TeamAi/Meric/Giant/Zombie）与**簇**（Formation 列队形、y 对齐、绕障），而不是零散函数。
- 新批次：**11a** 基类补全簇（y 对齐 6 函数语义化 + 统一 Face + IsUnderThreat 真值 + IsTargetReallyClose + DetermineXRunPower，~1.5 轮）；**11b** Formation 列队形（row/col 阵列 + 落点稳定 + 追赶状态，~1.5 轮）；**11c** TeamAi 逐函数直译（7c 扩容至 2.5 轮）；**11d** 并入 2；**11e** 玩法依赖簇挂总账缓。
- 执行顺序更新：**9 余项 → 11a → 11b → 2 → 7c(11c) → 7b → 7a**；11e/总账同步单独排。

---

## 七、SWL 全模块对账（2026-09-01，python 统计 `dump.cs` 命名空间）

> 方法：流式统计 legacy `dump.cs` 全部类型（2966 个 / 187 命名空间），其中 `StickWar.*` 游戏代码 **363 类型 / 35 命名空间**（其余为 Unity 引擎/Spine/插件）。剔除平台服务（IAP/广告/云同步/成就/AB 测试/RemoteTuning ≈ 40 类型，不复刻），游戏性模块 14 个，对账如下。

| SWL 模块（类型数） | 内容 | 本项目对应 | 状态 / 参考价值 |
|---|---|---|---|
| **Game 核心**（15） | GameController / LevelLoader / GameCamera / ObjectPool / RenderLayer / Barricades / Mines / InGameShop / AssetCache | game_root / scene_loader / camera_rig / FxPool / 资源建筑 | ◐ 骨架在；**InGameShop（战场商店）→ 并入 §10 物品栏**；Mines 挖金经济=不同路线（村民经济），参考平衡 |
| **Entities**（20） | Unit 基类 + 16 兵种/建筑（含 CastleArchers / King / GiantBoss / MainStatue / Statue / Minion / Zombie）+ Team + HealthBar + ConversionChannel | units 模块（stickman_entity + WeaponMount 单类多兵种）+ battle_instance 阵营 | ◐ 兵种数据化分型在；**缺：CastleArchers 城堡弓手、Statue/MainStatue（雕像=SWL 胜利目标）、King/GiantBoss（BOSS）、ConversionChannel（单位转化）**——雕像/BOSS 与本作大世界定位不同，按玩法批次决策 |
| **Entities.Ai**（14） | 133 行为函数 | ai/ + command/ | **严格 34% / 含近似 49%**，逐函数对账见 §六 |
| **Spells**（15） | Spell 基类 + ArrowVolley 箭雨 / HealSpell 群疗 / LightningStorm / LazerBeam / MinerGoldRush / RaiseGold / SpawnUnit / SpeartonMadness / SwordwrathRage / SummonElite / SummonGiant / SummonGoldenSpearton / TrainingHaste / TurretPower | ❌ 全缺（用户已拍板只要一部分：ArrowVolley + HealSpell） | **高参考**：Spell 基类统一"冷却/耗金/施放动画/效果"结构——计划 4 实施时先立 Spell 基类再挂具体法术 |
| **Effects**（16） | Blood / DirectionalBlood（方向血溅）/ ExplosionScorch（爆炸焦痕）/ GroundSlam（震地）/ LightningOnUnit / EarthquakeEffect / Rain / Cloud / StatueDeath / ArrowEffect / FollowUnit / StoneParticleSystem | fx 模块（4 效果：尘土/飘屑/火花/法爆） | **高参考**：血溅（DirectionalBlood）与爆炸焦痕（ExplosionScorch）是战斗观感大头，fx 扩容清单：血溅/焦痕/震地/雨云天气；焦痕同时是召唤/爆炸的地面标记（SpawnGroundScorch 同族） |
| **Projectiles**（2） | Arrow（已深度参考）/ GutSpinner（巨人甩摆武器投射物） | arrow_projectile ✓ | Arrow 已对齐；GutSpinner 并入 7a 巨人批次 |
| **Levels**（14） | Level 基类 + Tutorial / ArchidonTutorial / Ambush / GiantBossLevel / Sandbox / Tournament / SuperDeathMatch / EndlessDeads / 关卡排序 | 战场图 + 观察场（Sandbox 等价物） | ◐ 本作走战略图大世界，关卡制不照搬；**Tutorial 系结构**（分兵种教学关）Alpha 后参考；SandboxLevel=观察场已等价 |
| **Modes**（13） | Campaign / Tournament / Missions（5）/ EndlessDeads（2）/ 存档数据 | ❌（战略图路线） | 模式**清单**可复用为玩法变体：无尽尸潮（EndlessDeads）/超级乱斗（SuperDeathMatch）适合做观察场/演练变体，成本极低 |
| **Game.UI**（9） | **HudInventory（战场物品条）** / HudUnitButton / Joystick / TutorialArrow / UnitUnlocked | ❌ | HudInventory = §10 物品栏的原版形态参考；HudUnitButton（造兵按钮）/TutorialArrow（教学箭头）Alpha 参考 |
| **Sound**（4） | SoundManager / SoundEffects / MenuMusic / SoundSettingsData | AudioManager + SFX_EVENTS 框架 ✓（音效资产未接线） | **计划 1**（用户放延后）：框架已等价，纯接线 |
| **Personalities**（1） | Personality（兵种个性数据：y 走位偏好/激进度等） | behavior_profiles.gd（RWR 档案制） | ✅ 等价实现（档案字段即 Personality 数据） |
| **UserInterface**（159+12） | 菜单/面板/商店/设置全量 | ui_global（远少于 159） | 低优先：多数为商店/设置面板；**UX 流程参考**（主菜单→模式选择→解锁进度），Alpha UI 批次时按需 |
| **Animation**（3） | AnimationTimeOffset / Interpolate / SunSetAnimator（日落环境动画） | stickman_anims + environment 夜间压暗 | ◐ SunSetAnimator 对应已做的时间光照 |
| **Texture**（3）/ MiniLegends / GameLoopTesting | 文本注记工具 / 小游戏原型 / 循环测试 | — | 低参考；GameLoopTesting 思路=本项目 battle_sim/tests 已超集 |

### 结论

- SWL 除 AI 外的**可复刻游戏层**主要是五块：**Spells 法术（15 类）**、**Effects 特效（16 类）**、**战场经济/商店（InGameShop+Mines）**、**模式变体（EndlessDeads/SuperDeathMatch 等）**、**剩余兵种实体（CastleArchers/Statue/King/GiantBoss/Zombie）**。
- 本项目已有等价或超集：Game 核心骨架、Unit/HealthBar/Team、Projectiles.Arrow、Personality（档案制）、Sound 框架、Sandbox（观察场）。
- 与本作大世界定位冲突、按需参考的：Levels 关卡制、Modes 战役/锦标赛、Statue 胜利目标（可抽象为"战争目标建筑"）。
- 立项建议（并入既有批次）：Spells 基类+ArrowVolley/HealSpell → 计划 4；Effects 扩容（血溅/焦痕/震地）→ 新批次 12（与 9e 爆炸同管线）；InGameShop/HudInventory → §10 物品栏；模式变体 → Alpha 后低成本低挂；CastleArchers → 城堡玩法批次。

---

## 三、关键路径与数据源

| 资源 | 路径 |
|---|---|
| universal 主骨架（剑矛弓镐杖全动画） | `F:\VSCode\game-2-aux\external\decompiled\legacy\spine_raw\核心单位骨架\[skeleton].txt`（100 动画全量清单用 python 读 `animations` 键） |
| 巨人/祭司/僵尸等骨架 | 同目录 `[giant].txt` `[meric].txt` `[zombie].txt` 等 |
| legacy dump（14 个 Ai 类签名） | `F:\VSCode\game-2-aux\external\decompiled\legacy\dump\legacy_AI_classes.cs` |
| legend dump（组件/系统清单） | `F:\VSCode\game-2-aux\external\decompiled\legend\dump\` |
| 动画导入输出 | `res://modules/units/animations/`（spine_import 缺省目录） |
| 两代对比分析（机制清单） | `F:\VSCode\game-2-aux\external\decompiled\两款解包游戏完整代码分析与移植决策.md` |
| 行为参数档案（兵种个性唯一入口） | `res://modules/units/scripts/ai/behavior_profiles.gd`（RWR 式基线+覆盖） |

## 四、验收工具与命令

```bash
# 战斗仿真统计器（每轮改完必跑；输出行为占比/发呆检测/远程交战距离/收敛）
godot --headless --path . res://tests/dev/battle_sim.tscn
# 场景矩阵在 battle_sim.gd SCENARIOS 常量，可增删

# 观察场（人工验收）：主菜单 → 战斗演练 → 大乱斗观察场（R 重开 · 空格暂停 · 滚轮缩放）
# 当前观察场参数：镜头 0.55 · 两军间距 800 · 行距 90/110 · 战场 6144×(432~1674)

# 动画增量导入（--only 后跟逗号分隔的映射键名）
godot --headless --path . res://tools/baking/spine_import.tscn -- --only=dead_v2,hit_block_1

# 单脚本语法检查（报错白名单=autoload 误报：EventBus/TimeManager/BalanceConfig/WorldState/ConfigManager/depended）
godot --headless --path . --check-only --script res://<脚本路径>
```

## 五、工作方式约定（新对话必读）

1. **轮次口径**：直译/接线类一轮 3~5 子项；新机制 1 轮 1 主体 + ~30% 返工率。用户验收节奏决定日历时间。
2. **新调 API 先 grep 方法签名**（教训：`register_unit` 不存在，真名 `add_unit(unit, faction)`）。
3. **跨类引用一律显式 preload**（防 headless `class_name` 未注册误报；先例见 weapon_mount 的 ScriptBehaviorProfiles/ScriptStatusEffects）。
4. **类型化数组常量不经三元表达式**（退化为 untyped Array 运行时报错，先例 stickman_anims.pick_hit_anim）。
5. **用户已定决策（勿反转）**：盾牌只绑矛兵；staff 不风筝（召唤护卫方案）；法术只要一部分；皮肤不复制素材。
6. **每轮改完**：语法检查全部 touched 文件 → battle_sim 回归 → 用户游戏内验收。
7. 行为改动尽量进 **behavior_profiles 参数**而非硬编码（RWR 制度）；新机制做成能力开关（档案字段）。
8. 批量测试进程内 autoload 全局状态会跨套件残留（教训 2026-09-01：battle_started 自动暂停把
   TimeManager 置 PAUSED → 后续武器/投射物套件的 TimeManager 门禁全部空转）——
   batch_runner 每套件前重置 TimeManager；新增依赖全局状态的门禁时必查批量污染。
